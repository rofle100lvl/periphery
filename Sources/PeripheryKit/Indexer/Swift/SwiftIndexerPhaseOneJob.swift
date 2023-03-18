import Foundation
import SwiftIndexStore
import Shared

/// Phase one reads the index store and establishes the declaration hierarchy and the majority of references.
/// Some references may depend upon declarations in other files, and thus their association is deferred until
/// phase two.
final class SwiftIndexerPhaseOneJob {
    private let file: SourceFile
    private let units: [(IndexStore, IndexStoreUnit)]
    private let graph: SourceGraph
    private let logger: ContextualLogger
    private let configuration: Configuration

    private var declarations: [Declaration] = []
    private var childDeclsByParentUsr: [String: Set<Declaration>] = [:]
    private var referencesByUsr: [String: Set<Reference>] = [:]
    private var danglingReferences: [Reference] = []
    private var varParameterUsrs: Set<String> = []

    init(
        file: SourceFile,
        units: [(IndexStore, IndexStoreUnit)],
        graph: SourceGraph,
        logger: ContextualLogger,
        configuration: Configuration
    ) {
        self.file = file
        self.units = units
        self.graph = graph
        self.logger = logger.contextualized(with: "phase:one")
        self.configuration = configuration
    }

    func perform() throws -> SwiftFileIndexingState {
        let (state, elapsed) = try Benchmark.measure { try performPrivate() }
        logger.debug("\(file.path) (\(elapsed)s)")
        return state
    }

    // MARK: - Private

    private struct RawRelation {
        struct Symbol {
            let name: String?
            let usr: String?
            let kind: IndexStoreSymbol.Kind
            let subKind: IndexStoreSymbol.SubKind
        }

        let symbol: Symbol
        let roles: IndexStoreOccurrence.Role
    }

    private struct RawDeclaration {
        struct Key: Hashable {
            let kind: Declaration.Kind
            let name: String?
            let isImplicit: Bool
            let isObjcAccessible: Bool
            let location: SourceLocation
        }

        let usr: String
        let kind: Declaration.Kind
        let name: String?
        let isImplicit: Bool
        let isObjcAccessible: Bool
        let location: SourceLocation

        var key: Key {
            Key(kind: kind, name: name, isImplicit: isImplicit, isObjcAccessible: isObjcAccessible, location: location)
        }
    }

    private func performPrivate() throws -> SwiftFileIndexingState {
        var rawDeclsByKey: [RawDeclaration.Key: [(RawDeclaration, [RawRelation])]] = [:]

        for (indexStore, unit) in units {
            try indexStore.forEachRecordDependencies(for: unit) { dependency in
                guard case let .record(record) = dependency else { return true }

                try indexStore.forEachOccurrences(for: record) { occurrence in
                    guard occurrence.symbol.language == .swift,
                          let usr = occurrence.symbol.usr,
                          let location = transformLocation(occurrence.location)
                          else { return true }

                    if occurrence.roles.contains(.definition) {
                        if let (decl, relations) = try parseRawDeclaration(occurrence, usr, location, indexStore) {
                            rawDeclsByKey[decl.key, default: []].append((decl, relations))
                        }
                    }

                    if occurrence.roles.contains(.reference) {
                        try parseReference(occurrence, usr, location, indexStore)
                    }

                    if occurrence.roles.contains(.implicit) {
                        try parseImplicit(occurrence, usr, location, indexStore)
                    }

                    return true
                }

                return true
            }
        }

        for (key, values) in rawDeclsByKey {
            let usrs = Set(values.map { $0.0.usr })
            let decl = Declaration(kind: key.kind, usrs: usrs, location: key.location)

            decl.name = key.name
            decl.isImplicit = key.isImplicit
            decl.isObjcAccessible = key.isObjcAccessible

            if decl.isImplicit {
                graph.markRetained(decl)
            }

            if decl.isObjcAccessible && configuration.retainObjcAccessible {
                graph.markRetained(decl)
            }

            let relations = values.flatMap { $0.1 }
            try parseDeclaration(decl, relations)

            graph.add(decl)
            declarations.append(decl)
        }

        establishDeclarationHierarchy()

        return .init(
            file: file,
            declarations: declarations,
            childDeclsByParentUsr: childDeclsByParentUsr,
            referencesByUsr: referencesByUsr,
            danglingReferences: danglingReferences,
            varParameterUsrs: varParameterUsrs)
    }

    private func establishDeclarationHierarchy() {
        graph.withLock {
            for (parent, decls) in childDeclsByParentUsr {
                guard let parentDecl = graph.explicitDeclaration(withUsr: parent) else {
                    if varParameterUsrs.contains(parent) {
                        // These declarations are children of a parameter and are redundant.
                        decls.forEach { graph.removeUnsafe($0) }
                    }

                    continue
                }

                for decl in decls {
                    decl.parent = parentDecl
                }

                parentDecl.declarations.formUnion(decls)
            }
        }
    }

    private func parseRawDeclaration(
        _ occurrence: IndexStoreOccurrence,
        _ usr: String,
        _ location: SourceLocation,
        _ indexStore: IndexStore
    ) throws -> (RawDeclaration, [RawRelation])? {
        guard let kind = transformDeclarationKind(occurrence.symbol.kind, occurrence.symbol.subKind)
        else { return nil }

        guard kind != .varParameter else {
            // Ignore indexed parameters as unused parameter identification is performed separately using SwiftSyntax.
            // Record the USR so that we can also ignore implicit accessor declarations.
            varParameterUsrs.insert(usr)
            return nil
        }

        let decl = RawDeclaration(
            usr: usr,
            kind: kind,
            name: occurrence.symbol.name,
            isImplicit: occurrence.roles.contains(.implicit),
            isObjcAccessible: usr.hasPrefix("c:"),
            location: location)

        var relations: [RawRelation] = []

        indexStore.forEachRelations(for: occurrence) { rel -> Bool in
            relations.append(
                .init(
                    symbol: .init(
                        name: rel.symbol.name,
                        usr: rel.symbol.usr,
                        kind: rel.symbol.kind,
                        subKind: rel.symbol.subKind
                    ),
                    roles: rel.roles
                )
            )

            return true
        }

        return (decl, relations)
    }

    private func parseDeclaration(
        _ decl: Declaration,
        _ relations: [RawRelation]
    ) throws {
        for rel in relations {
            if !rel.roles.intersection([.childOf]).isEmpty {
                if let parentUsr = rel.symbol.usr {
                    childDeclsByParentUsr[parentUsr, default: []].insert(decl)
                }
            }

            if !rel.roles.intersection([.overrideOf]).isEmpty {
                let baseFunc = rel.symbol

                if let baseFuncUsr = baseFunc.usr, let baseFuncKind = transformReferenceKind(baseFunc.kind, baseFunc.subKind) {
                    let reference = Reference(kind: baseFuncKind, usr: baseFuncUsr, location: decl.location)
                    reference.name = baseFunc.name
                    reference.isRelated = true

                    graph.withLock {
                        graph.addUnsafe(reference)
                        associateUnsafe(reference, with: decl)
                    }
                }
            }

            if !rel.roles.intersection([.baseOf, .calledBy, .extendedBy, .containedBy]).isEmpty {
                let referencer = rel.symbol

                if let referencerUsr = referencer.usr, let referencerKind = decl.kind.referenceEquivalent {
                    for usr in decl.usrs {
                        let reference = Reference(kind: referencerKind, usr: usr, location: decl.location)
                        reference.name = decl.name

                        if rel.roles.contains(.baseOf) {
                            reference.isRelated = true
                        }

                        graph.add(reference)
                        referencesByUsr[referencerUsr, default: []].insert(reference)
                    }
                }
            }
        }
    }

    private func parseReference(
        _ occurrence: IndexStoreOccurrence,
        _ occurrenceUsr: String,
        _ location: SourceLocation,
        _ indexStore: IndexStore
    ) throws {
        guard let kind = transformReferenceKind(occurrence.symbol.kind, occurrence.symbol.subKind)
              else { return }

        guard kind != .varParameter else {
            // Ignore indexed parameters as unused parameter identification is performed separately using SwiftSyntax.
            return
        }

        var refs = [Reference]()

        indexStore.forEachRelations(for: occurrence) { rel -> Bool in
            if !rel.roles.intersection([.baseOf, .calledBy, .containedBy, .extendedBy]).isEmpty {
                let referencer = rel.symbol

                if let referencerUsr = referencer.usr {
                    let ref = Reference(kind: kind, usr: occurrenceUsr, location: location)
                    ref.name = occurrence.symbol.name

                    if rel.roles.contains(.baseOf) {
                        ref.isRelated = true
                    }

                    refs.append(ref)
                    referencesByUsr[referencerUsr, default: []].insert(ref)
                }
            }

            return true
        }

        if refs.isEmpty {
            let ref = Reference(kind: kind, usr: occurrenceUsr, location: location)
            ref.name = occurrence.symbol.name
            refs.append(ref)

            // The index store doesn't contain any relations for this reference, save it so that we can attempt
            // to associate it with the correct declaration later based on location.
            if ref.kind != .module {
                danglingReferences.append(ref)
            }
        }

        graph.withLock {
            refs.forEach { graph.addUnsafe($0) }
        }
    }

    private func parseImplicit(
        _ occurrence: IndexStoreOccurrence,
        _ occurrenceUsr: String,
        _ location: SourceLocation,
        _ indexStore: IndexStore
    ) throws {
        var refs = [Reference]()

        indexStore.forEachRelations(for: occurrence) { rel -> Bool in
            if !rel.roles.intersection([.overrideOf]).isEmpty {
                let baseFunc = rel.symbol

                if let baseFuncUsr = baseFunc.usr, let baseFuncKind = transformReferenceKind(baseFunc.kind, baseFunc.subKind) {
                    let reference = Reference(kind: baseFuncKind, usr: baseFuncUsr, location: location)
                    reference.name = baseFunc.name
                    reference.isRelated = true

                    referencesByUsr[occurrenceUsr, default: []].insert(reference)
                    refs.append(reference)
                }
            }

            return true
        }

        graph.withLock {
            refs.forEach { graph.addUnsafe($0) }
        }
    }

    private func associateUnsafe(_ ref: Reference, with decl: Declaration) {
        ref.parent = decl

        if ref.isRelated {
            decl.related.insert(ref)
        } else {
            decl.references.insert(ref)
        }
    }

    private func transformLocation(_ input: IndexStoreOccurrence.Location) -> SourceLocation? {
        return SourceLocation(file: file, line: input.line, column: input.column)
    }

    private func transformDeclarationKind(_ kind: IndexStoreSymbol.Kind, _ subKind: IndexStoreSymbol.SubKind) -> Declaration.Kind? {
        switch subKind {
        case .accessorGetter: return .functionAccessorGetter
        case .accessorSetter: return .functionAccessorSetter
        case .swiftAccessorDidSet: return .functionAccessorDidset
        case .swiftAccessorWillSet: return .functionAccessorWillset
        case .swiftAccessorMutableAddressor: return .functionAccessorMutableaddress
        case .swiftAccessorAddressor: return .functionAccessorAddress
        case .swiftSubscript: return .functionSubscript
        case .swiftInfixOperator: return .functionOperatorInfix
        case .swiftPrefixOperator: return .functionOperatorPrefix
        case .swiftPostfixOperator: return .functionOperatorPostfix
        case .swiftGenericTypeParam: return .genericTypeParam
        case .swiftAssociatedtype: return .associatedtype
        case .swiftExtensionOfClass: return .extensionClass
        case .swiftExtensionOfStruct: return .extensionStruct
        case .swiftExtensionOfProtocol: return .extensionProtocol
        case .swiftExtensionOfEnum: return .extensionEnum
        default: break
        }

        switch kind {
        case .module: return .module
        case .enum: return .enum
        case .struct: return .struct
        case .class: return .class
        case .protocol: return .protocol
        case .extension: return .extension
        case .typealias: return .typealias
        case .function: return .functionFree
        case .variable: return .varGlobal
        case .enumConstant: return .enumelement
        case .instanceMethod: return .functionMethodInstance
        case .classMethod: return .functionMethodClass
        case .staticMethod: return .functionMethodStatic
        case .instanceProperty: return .varInstance
        case .classProperty: return .varClass
        case .staticProperty: return .varStatic
        case .constructor: return .functionConstructor
        case .destructor: return .functionDestructor
        case .parameter: return .varParameter
        default: return nil
        }
    }

    private func transformReferenceKind(_ kind: IndexStoreSymbol.Kind, _ subKind: IndexStoreSymbol.SubKind) -> Reference.Kind? {
        switch subKind {
        case .accessorGetter: return .functionAccessorGetter
        case .accessorSetter: return .functionAccessorSetter
        case .swiftAccessorDidSet: return .functionAccessorDidset
        case .swiftAccessorWillSet: return .functionAccessorWillset
        case .swiftAccessorMutableAddressor: return .functionAccessorMutableaddress
        case .swiftAccessorAddressor: return .functionAccessorAddress
        case .swiftSubscript: return .functionSubscript
        case .swiftInfixOperator: return .functionOperatorInfix
        case .swiftPrefixOperator: return .functionOperatorPrefix
        case .swiftPostfixOperator: return .functionOperatorPostfix
        case .swiftGenericTypeParam: return .genericTypeParam
        case .swiftAssociatedtype: return .associatedtype
        case .swiftExtensionOfClass: return .extensionClass
        case .swiftExtensionOfStruct: return .extensionStruct
        case .swiftExtensionOfProtocol: return .extensionProtocol
        case .swiftExtensionOfEnum: return .extensionEnum
        default: break
        }

        switch kind {
        case .module: return .module
        case .enum: return .enum
        case .struct: return .struct
        case .class: return .class
        case .protocol: return .protocol
        case .extension: return .extension
        case .typealias: return .typealias
        case .function: return .functionFree
        case .variable: return .varGlobal
        case .enumConstant: return .enumelement
        case .instanceMethod: return .functionMethodInstance
        case .classMethod: return .functionMethodClass
        case .staticMethod: return .functionMethodStatic
        case .instanceProperty: return .varInstance
        case .classProperty: return .varClass
        case .staticProperty: return .varStatic
        case .constructor: return .functionConstructor
        case .destructor: return .functionDestructor
        case .parameter: return .varParameter
        default: return nil
        }
    }
}
