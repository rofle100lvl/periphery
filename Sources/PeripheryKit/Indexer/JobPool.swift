import Foundation

struct JobPool<T> {
    let jobs: [T]

    func map<R>(_ block: @escaping (T) throws -> R) throws -> [R] {
        var result: [R] = []
        try forEach { result.append(try block($0)) }
        return result
    }

    func forEach(_ block: @escaping (T) throws -> Void) throws {
        var error: Error?

        DispatchQueue.concurrentPerform(iterations: jobs.count) { idx in
            guard error == nil else { return }

            do {
                let job = jobs[idx]
                try block(job)
            } catch let e {
                error = e
            }
        }

        if let error = error {
            throw error
        }
    }
}
