import Foundation
import SwiftSyntax
import SwiftIndexStore
import SystemPackage
import Shared

public final class SwiftIndexer: Indexer {
    private let sourceFiles: [FilePath: Set<String>]
    private let graph: SourceGraph
    private let logger: ContextualLogger
    private let configuration: Configuration
    private let indexStorePaths: [FilePath]

    private lazy var letShorthandWorkaroundEnabled: Bool = {
        SwiftVersion.current.version.isVersion(lessThan: "5.8")
    }()

    public required init(
        sourceFiles: [FilePath: Set<String>],
        graph: SourceGraph,
        indexStorePaths: [FilePath],
        logger: Logger = .init(),
        configuration: Configuration = .shared
    ) {
        self.sourceFiles = sourceFiles
        self.graph = graph
        self.indexStorePaths = indexStorePaths
        self.logger = logger.contextualized(with: "index:swift")
        self.configuration = configuration
        super.init(configuration: configuration)
    }

    public func perform() throws {
        var unitsByFile: [FilePath: [(IndexStore, IndexStoreUnit)]] = [:]
        let allSourceFiles = Set(sourceFiles.keys)
        let (includedFiles, excludedFiles) = filterIndexExcluded(from: allSourceFiles)
        excludedFiles.forEach { self.logger.debug("Excluding \($0.string)") }

        for indexStorePath in indexStorePaths {
            logger.debug("Reading \(indexStorePath)")
            let indexStore = try IndexStore.open(store: URL(fileURLWithPath: indexStorePath.string), lib: .open())

            try indexStore.forEachUnits(includeSystem: false) { unit -> Bool in
                guard let filePath = try indexStore.mainFilePath(for: unit) else { return true }

                let file = FilePath(filePath)

                if includedFiles.contains(file) {
                    unitsByFile[file, default: []].append((indexStore, unit))
                }

                return true
            }
        }

        let indexedFiles = Set(unitsByFile.keys)
        let unindexedFiles = allSourceFiles.subtracting(excludedFiles).subtracting(indexedFiles)

        if !unindexedFiles.isEmpty {
            unindexedFiles.forEach { logger.debug("Source file not indexed: \($0)") }
            let targets: Set<String> = Set(unindexedFiles.flatMap { sourceFiles[$0] ?? [] })
            throw PeripheryError.unindexedTargetsError(targets: targets, indexStorePaths: indexStorePaths)
        }

        let phaseOneJobs = try unitsByFile.map { (file, units) -> SwiftIndexerPhaseOneJob in
            let modules = try units.reduce(into: Set<String>()) { (result, tuple) in
                let (indexStore, unit) = tuple
                if let name = try indexStore.moduleName(for: unit) {
                    let (didInsert, _) = result.insert(name)
                    if !didInsert {
                        let targets = try Set(units.compactMap { try indexStore.target(for: $0.1) })
                        throw PeripheryError.conflictingIndexUnitsError(file: file, module: name, unitTargets: targets)
                    }
                }
            }
            return SwiftIndexerPhaseOneJob(
                file: SourceFile(path: file, modules: modules),
                units: units,
                graph: graph,
                logger: logger,
                configuration: configuration)
        }

        let phaseOneInterval = logger.beginInterval("index:swift:phase:one")
        let states = try JobPool(jobs: phaseOneJobs).map { try $0.perform() }
        logger.endInterval(phaseOneInterval)

        let phaseTwoInterval = logger.beginInterval("index:swift:phase:two")
        try JobPool(jobs: states).forEach {
            let job = SwiftIndexerPhaseTwoJob(
                state: $0,
                graph: self.graph,
                logger: self.logger,
                configuration: self.configuration,
                letShorthandWorkaroundEnabled: self.letShorthandWorkaroundEnabled)
            try job.perform()
        }
        logger.endInterval(phaseTwoInterval)
    }
}
