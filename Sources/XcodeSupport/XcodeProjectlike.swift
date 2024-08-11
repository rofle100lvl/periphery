import Foundation
import SystemPackage
import Shared

public protocol XcodeProjectlike: AnyObject {
    var path: FilePath { get }
    var targets: Set<XcodeTarget> { get }
    var packageTargets: [SPM.Package: Set<SPM.Target>] { get }
    var type: String { get }
    var name: String { get }
    var sourceRoot: FilePath { get }

    func schemes(additionalArguments: [String]) throws -> Set<String>
}

extension XcodeProjectlike {
    public var name: String {
        return path.lastComponent?.stem ?? ""
    }
}
