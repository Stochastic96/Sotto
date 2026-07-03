import Foundation

/// Runs an async throwing operation with a timeout.
/// Throws a timeout error if the operation exceeds the duration.
public func withTimeout<T: Sendable>(
    seconds: Double,
    errorDomain: String = "Sotto",
    errorDescription: String = "Operation timed out",
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw NSError(
                domain: errorDomain,
                code: -99,
                userInfo: [NSLocalizedDescriptionKey: errorDescription]
            )
        }
        guard let result = try await group.next() else {
            throw NSError(
                domain: errorDomain,
                code: -100,
                userInfo: [NSLocalizedDescriptionKey: "No result returned"]
            )
        }
        group.cancelAll()
        return result
    }
}
