import Configuration
import SystemPackage

final class MarkdownFormatter: OutputFormatter {
    let configuration: Configuration
    lazy var currentFilePath: FilePath = .current

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func format(_ results: [ScanResult], colored: Bool) throws -> String? {
        guard !results.isEmpty else {
            return "No unused code detected."
        }

        let formattedResults = results.flatMap { result in
            describe(result, colored: colored).map { location, description in
                "| **\(description)**<br>\(locationDescription(location)) |"
            }
        }
        .joined(separator: "\n")
        let title = results.count == 1 ?"Result" : "Results"

        return """
        | \(results.count) \(title) |
        | :- |
        \(formattedResults)
        """
    }
}
