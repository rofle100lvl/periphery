import Foundation
import XcodeProj
import SystemPackage
import Shared

public final class XcodeProject: XcodeProjectlike {
    private static var cache: [FilePath: XcodeProject] = [:]

    static func build(path: FilePath, referencedBy refPath: FilePath) throws -> XcodeProject? {
        if !path.exists {
            let logger = Logger()
            logger.warn("No such project exists at '\(path.lexicallyNormalized())', referenced by '\(refPath)'.")
            return nil
        }

        return try build(path: path)
    }

    static func build(path: FilePath) throws -> XcodeProject {
        if let cached = cache[path] {
            return cached
        }

        return try self.init(path: path)
    }

    public let type: String = "project"
    public let path: FilePath
    public let sourceRoot: FilePath
    public let xcodeProject: XcodeProj
    public let name: String

    private let xcodebuild: Xcodebuild

    public private(set) var targets: Set<XcodeTarget> = []
    public private(set) var packageTargets: [SPM.Package: Set<SPM.Target>] = [:]

    public required init(path: FilePath, xcodebuild: Xcodebuild = .init(), logger: Logger = .init()) throws {
        logger.contextualized(with: "xcode:project").debug("Loading \(path)")

        self.path = path
        self.xcodebuild = xcodebuild
        self.name = self.path.lastComponent?.stem ?? ""
        self.sourceRoot = self.path.removingLastComponent()

        do {
            self.xcodeProject = try XcodeProj(pathString: self.path.lexicallyNormalized().string)
        } catch let error {
            throw PeripheryError.underlyingError(error)
        }

        // Cache before loading sub-projects to avoid infinite loop from cyclic project references.
        XcodeProject.cache[path] = self

        var subProjects: [XcodeProject] = []

        // Don't search for sub projects within CocoaPods.
        if !path.components.contains("Pods.xcodeproj") {
            subProjects = try xcodeProject.pbxproj.fileReferences
                .filter { $0.path?.hasSuffix(".xcodeproj") ?? false }
                .compactMap { try $0.fullPath(sourceRoot: sourceRoot.string) }
                .compactMap { try XcodeProject.build(path: FilePath($0), referencedBy: path) }
        }

        targets = xcodeProject.pbxproj.nativeTargets
            .mapSet { XcodeTarget(project: self, target: $0) }
            .union(subProjects.flatMapSet { $0.targets })

        let packageTargetNames = targets.flatMapSet { $0.packageDependencyNames }

        if !packageTargetNames.isEmpty {
            var packages: [SPM.Package] = []

            for localPackage in xcodeProject.pbxproj.rootObject?.localPackages ?? [] {
                let path = sourceRoot.appending(localPackage.relativePath)
                if path.appending("Package.swift").exists {
                    try path.chdir {
                        let package = try SPM.Package.load()
                        packages.append(package)
                    }
                }
            }

            packageTargets = packageTargetNames.reduce(into: .init(), { result, targetName in
                for package in packages {
                    if let target = package.targets.first(where: { $0.name == targetName }) {
                        result[package, default: []].insert(target)
                    }
                }
            })
        }
    }

  public func schemes(additionalArguments: [String]) throws -> Set<String> {
        try xcodebuild.schemes(project: self, additionalArguments: additionalArguments)
    }
}

extension XcodeProject: Hashable {
  public func hash(into hasher: inout Hasher) {
        hasher.combine(path.lexicallyNormalized().string)
    }
}

extension XcodeProject: Equatable {
  public static func == (lhs: XcodeProject, rhs: XcodeProject) -> Bool {
        return lhs.path == rhs.path
    }
}
