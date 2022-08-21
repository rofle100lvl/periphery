import XCTest
import Shared
@testable import TestShared
@testable import XcodeSupport
@testable import PeripheryKit

class CocoaPodsProjectTest: SourceGraphTestCase {
    override static func setUp() {
        super.setUp()

        let workspace = try! XcodeWorkspace.make(path: CocoaPodsProjectPath)

        let driver = XcodeProjectDriver(
            logger: inject(),
            configuration: configuration,
            xcodebuild: inject(),
            project: workspace,
            schemes: [try! XcodeScheme.make(project: workspace, name: "CocoaPodsProject")],
            targets: workspace.targets
        )

        try! driver.build()
        try! driver.index(graph: graph)
        try! Analyzer.perform(graph: graph)
    }

    func testSomething() {
        assertReferenced(.class("TestDevelopmentPodUsed"))
        assertNotReferenced(.class("TestDevelopmentPodUnused"))
    }
}
