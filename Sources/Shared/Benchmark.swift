import Foundation

public final class Benchmark {
    public static func measure(block: () throws -> Void) rethrows -> String {
        let (_, elapsed) = try measure { try block() }
        return elapsed
    }

    public static func measure<T>(block: () throws -> T) rethrows -> (T, String) {
        let start = Date()
        let value = try block()
        let end = Date()
        let elapsed = end.timeIntervalSince(start)
        return (value, String(format: "%.03f", elapsed))
    }
}
