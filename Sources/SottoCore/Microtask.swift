import Foundation

/// A persisted background task processed one-at-a-time when Sotto is idle. Lives in
/// SottoCore (Foundation-only, unchanged JSON keys) so the `MicrotaskExecutor` seam and its
/// tests can reference it without pulling in AppKit / FoundationModels.
public struct Microtask: Codable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, running, done, failed }

    public let id: String
    public var name: String
    public var goal: String
    public var priority: Int          // higher = processed first; 0 = lowest
    public var status: Status
    public var retryCount: Int
    public var maxRetries: Int
    public var scheduledAfter: Date?  // nil = immediately eligible
    public var createdAt: Date
    public var completedAt: Date?
    public var result: String?
    public var failureReason: String?

    public init(name: String, goal: String, priority: Int = 0, maxRetries: Int = 2, scheduledAfter: Date? = nil) {
        self.id = UUID().uuidString
        self.name = name
        self.goal = goal
        self.priority = priority
        self.status = .pending
        self.retryCount = 0
        self.maxRetries = maxRetries
        self.scheduledAfter = scheduledAfter
        self.createdAt = Date()
    }
}

/// Runs a single microtask's goal and returns its output.
/// Swap implementations via `MicrotaskQueue.executor` — useful for testing
/// or plugging in a different AI backend without touching queue logic.
public protocol MicrotaskExecutor: Sendable {
    func execute(_ task: Microtask) async -> (output: String?, error: String?)
}
