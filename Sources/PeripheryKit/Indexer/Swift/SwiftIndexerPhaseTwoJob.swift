import Foundation
import SwiftIndexStore
import Shared

/// Phase two associates latent references, and performs other actions that depend on the completed source graph.
final class SwiftIndexerPhaseTwoJob {
    private let state: SwiftFileIndexingState
    private let graph: SourceGraph
    private let logger: ContextualLogger
    private let configuration: Configuration
    private let letShorthandWorkaroundEnabled: Bool

    init(
        state: SwiftFileIndexingState,
        graph: SourceGraph,
        logger: ContextualLogger,
        configuration: Configuration,
        letShorthandWorkaroundEnabled: Bool
    ) {
        self.state = state
        self.graph = graph
        self.logger = logger.contextualized(with: "phase:two")
        self.configuration = configuration
        self.letShorthandWorkaroundEnabled = letShorthandWorkaroundEnabled
    }

    func perform() throws {
        let elapsed = try Benchmark.measure { try performPrivate() }
        logger.debug("\(state.file.path) (\(elapsed)s)")
    }

    // MARK: - Private

    private func performPrivate() throws {
        let multiplexingSyntaxVisitor = try MultiplexingSyntaxVisitor(file: state.file)
        let declarationSyntaxVisitor = multiplexingSyntaxVisitor.add(DeclarationSyntaxVisitor.self)
        declarationSyntaxVisitor.letShorthandWorkaroundEnabled = letShorthandWorkaroundEnabled
        let importSyntaxVisitor = multiplexingSyntaxVisitor.add(ImportSyntaxVisitor.self)

        multiplexingSyntaxVisitor.visit()

        state.file.importStatements = importSyntaxVisitor.importStatements

        associateLatentReferences()
        associateDanglingReferences()
        visitDeclarations(using: declarationSyntaxVisitor)
        identifyUnusedParameters(using: multiplexingSyntaxVisitor)
        applyCommentCommands(using: multiplexingSyntaxVisitor)
    }

    private func associateLatentReferences() {
        for (usr, refs) in state.referencesByUsr {
            graph.withLock {
                if let decl = graph.explicitDeclaration(withUsr: usr) {
                    for ref in refs {
                        associateUnsafe(ref, with: decl)
                    }
                } else {
                    // TODO
//                    state.danglingReferences.append(contentsOf: refs)
                }
            }
        }
    }

    // Swift does not associate some type references with the containing declaration, resulting in references
    // with no clear parent. Property references are one example: https://bugs.swift.org/browse/SR-13766.
    private func associateDanglingReferences() {
        guard !state.danglingReferences.isEmpty else { return }

        let explicitDeclarations = state.declarations.filter { !$0.isImplicit }
        let declsByLocation = explicitDeclarations
            .reduce(into: [SourceLocation: [Declaration]]()) { (result, decl) in
                result[decl.location, default: []].append(decl)
            }
        let declsByLine = explicitDeclarations
            .reduce(into: [Int64: [Declaration]]()) { (result, decl) in
                result[decl.location.line, default: []].append(decl)
            }

        for ref in state.danglingReferences {
            guard let candidateDecls =
                    declsByLocation[ref.location] ??
                    declsByLine[ref.location.line] else { continue }

            // The vast majority of the time there will only be a single declaration for this location,
            // however it is possible for there to be more than one. In that case, first attempt to associate with
            // a decl without a parent, as the reference may be a related type of a class/struct/etc.
            if let decl = candidateDecls.first(where: { $0.parent == nil }) {
                associate(ref, with: decl)
            } else if let decl = candidateDecls.sorted().first {
                // Fallback to using the first declaration.
                // Sorting the declarations helps in the situation where the candidate declarations includes a
                // property/subscript, and a getter on the same line. The property/subscript is more likely to be
                // the declaration that should hold the references.
                associate(ref, with: decl)
            }
        }
    }

    private func associate(_ ref: Reference, with decl: Declaration) {
        graph.withLock {
            associateUnsafe(ref, with: decl)
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

    private func applyCommentCommands(using syntaxVisitor: MultiplexingSyntaxVisitor) {
        let fileCommands = CommentCommand.parseCommands(in: syntaxVisitor.syntax.leadingTrivia)

        if fileCommands.contains(.ignoreAll) {
            retainHierarchy(state.declarations)
        } else {
            for decl in state.declarations {
                if decl.commentCommands.contains(.ignore) {
                    retainHierarchy([decl])
                }
            }
        }
    }

    private func visitDeclarations(using declarationVisitor: DeclarationSyntaxVisitor) {
        let declarationsByLocation = declarationVisitor.resultsByLocation

        for decl in state.declarations {
            guard let result = declarationsByLocation[decl.location] else { continue }

            applyDeclarationMetadata(to: decl, with: result)
            markLetShorthandContainerIfNeeded(declaration: decl)
        }
    }

    private func markLetShorthandContainerIfNeeded(declaration: Declaration) {
        guard !declaration.letShorthandIdentifiers.isEmpty else { return }
        graph.markLetShorthandContainer(declaration)
    }

    private func applyDeclarationMetadata(to decl: Declaration, with result: DeclarationSyntaxVisitor.Result) {
        graph.withLock {
            if let accessibility = result.accessibility {
                decl.accessibility = .init(value: accessibility, isExplicit: true)
            }

            decl.attributes = Set(result.attributes)
            decl.modifiers = Set(result.modifiers)
            decl.commentCommands = Set(result.commentCommands)
            decl.declaredType = result.variableType
            decl.letShorthandIdentifiers = result.letShorthandIdentifiers
            decl.hasCapitalSelfFunctionCall = result.hasCapitalSelfFunctionCall
            decl.hasGenericFunctionReturnedMetatypeParameters = result.hasGenericFunctionReturnedMetatypeParameters

            for ref in decl.references.union(decl.related) {
                if result.inheritedTypeLocations.contains(ref.location) {
                    if decl.kind == .class, ref.kind == .class {
                        ref.role = .inheritedClassType
                    } else if decl.kind == .protocol, ref.kind == .protocol {
                        ref.role = .refinedProtocolType
                    }
                } else if result.variableTypeLocations.contains(ref.location) {
                    ref.role = .varType
                } else if result.returnTypeLocations.contains(ref.location) {
                    ref.role = .returnType
                } else if result.parameterTypeLocations.contains(ref.location) {
                    ref.role = .parameterType
                } else if result.genericParameterLocations.contains(ref.location) {
                    ref.role = .genericParameterType
                } else if result.genericConformanceRequirementLocations.contains(ref.location) {
                    ref.role = .genericRequirementType
                } else if result.variableInitFunctionCallLocations.contains(ref.location) {
                    ref.role = .variableInitFunctionCall
                } else if result.functionCallMetatypeArgumentLocations.contains(ref.location) {
                    ref.role = .functionCallMetatypeArgument
                }
            }
        }
    }

    private func retainHierarchy(_ decls: [Declaration]) {
        decls.forEach {
            graph.markRetained($0)
            $0.unusedParameters.forEach { graph.markRetained($0) }
            retainHierarchy(Array($0.declarations))
        }
    }

    private func identifyUnusedParameters(using syntaxVisitor: MultiplexingSyntaxVisitor) {
        let functionDecls = state.declarations.filter { $0.kind.isFunctionKind }
        let functionDeclsByLocation = functionDecls.filter { $0.kind.isFunctionKind }.map { ($0.location, $0) }.reduce(into: [SourceLocation: Declaration]()) { $0[$1.0] = $1.1 }

        let analyzer = UnusedParameterAnalyzer()
        let paramsByFunction = analyzer.analyze(
            file: state.file,
            syntax: syntaxVisitor.syntax,
            locationConverter: syntaxVisitor.locationConverter,
            parseProtocols: true)

        for (function, params) in paramsByFunction {
            guard let functionDecl = functionDeclsByLocation[function.location] else {
                // The declaration may not exist if the code was not compiled due to build conditions, e.g #if.
                logger.debug("Failed to associate indexed function for parameter function '\(function.name)' at \(function.location).")
                continue
            }

            let ignoredParamNames = functionDecl.commentCommands.flatMap { command -> [String] in
                switch command {
                case let .ignoreParameters(params):
                    return params
                default:
                    return []
                }
            }

            graph.withLock {
                for param in params {
                    let paramDecl = param.declaration
                    paramDecl.parent = functionDecl
                    functionDecl.unusedParameters.insert(paramDecl)
                    graph.addUnsafe(paramDecl)

                    if (functionDecl.isObjcAccessible && configuration.retainObjcAccessible) || ignoredParamNames.contains(param.name) {
                        graph.markRetainedUnsafe(paramDecl)
                    }
                }
            }
        }
    }

}
