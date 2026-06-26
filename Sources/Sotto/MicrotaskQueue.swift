import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - MicrotaskQueue
//
// A persistent background task queue. Tasks are processed one-at-a-time whenever
// Sotto enters the .idle state (via EventBus .idleReady), so they never interfere
// with active dictation or Jarvis commands.
//
// Tasks survive app restarts — the queue is written to sotto-data/microtasks.json.
//
// Typical sources:
//   • Jarvis agent queues a follow-up ("remind me to fix the CI tonight")
//   • GitObserver detects an unpushed commit → queues "generate commit message"
//   • User says "when you're free, organize my downloads"
//
// Task lifecycle:
//   pending → running → done | failed → (retry if retryCount < maxRetries) → pending

// MARK: - Model

struct Microtask: Codable, Identifiable {
    enum Status: String, Codable { case pending, running, done, failed }

    let id: String
    var name: String
    var goal: String
    var priority: Int            // higher = processed first; 0 = lowest
    var status: Status
    var retryCount: Int
    var maxRetries: Int
    var scheduledAfter: Date?    // nil = immediately eligible
    var createdAt: Date
    var completedAt: Date?
    var result: String?
    var failureReason: String?

    init(name: String, goal: String, priority: Int = 0, maxRetries: Int = 2, scheduledAfter: Date? = nil) {
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

// MARK: - MicrotaskExecutor

/// Runs a single microtask's goal and returns its output.
/// Swap implementations via `MicrotaskQueue.executor` — useful for testing
/// or plugging in a different AI backend without touching queue logic.
protocol MicrotaskExecutor: Sendable {
    func execute(_ task: Microtask) async -> (output: String?, error: String?)
}

/// Default executor: routes each task's goal through CoordinatorAgent.
struct CoordinatorTaskExecutor: MicrotaskExecutor {
    func execute(_ task: Microtask) async -> (output: String?, error: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
            do {
                let agent = CoordinatorAgent()
                let result = try await agent.handleTurn(userInput: task.goal)
                return (result, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }
        #endif
        return (nil, "Apple Intelligence unavailable — task will retry when model is ready.")
    }
}

// MARK: - Queue

actor MicrotaskQueue {
    static let shared = MicrotaskQueue()

    /// Swap to a custom executor for testing or alternative AI backends.
    var executor: any MicrotaskExecutor = CoordinatorTaskExecutor()

    private var tasks: [Microtask] = []
    private var isProcessing = false

    private var fileURL: URL {
        SettingsController.sottoDataURL.appendingPathComponent("microtasks.json")
    }

    // MARK: - Lifecycle

    func start() async {
        load()
        // Re-pend any tasks that were stuck in .running when the app was killed.
        for i in tasks.indices where tasks[i].status == .running {
            tasks[i].status = .pending
        }
        save()

        let pendingCount = tasks.filter { $0.status == .pending }.count
        print("[MICROTASK] Queue started — \(tasks.count) tasks (\(pendingCount) pending).")

        for await event in await EventBus.shared.makeStream() {
            if case .idleReady = event {
                await drainNext()
            }
        }
    }

    // MARK: - Public API

    func enqueue(_ task: Microtask) async {
        tasks.append(task)
        save()
        print("[MICROTASK] Enqueued '\(task.name)' (priority \(task.priority))")
        await EventBus.shared.emit(.microtaskEnqueued(id: task.id, name: task.name))
    }

    func enqueue(name: String, goal: String, priority: Int = 0,
                 maxRetries: Int = 2, scheduledAfter: Date? = nil) async {
        await enqueue(Microtask(name: name, goal: goal, priority: priority,
                                maxRetries: maxRetries, scheduledAfter: scheduledAfter))
    }

    func allTasks() -> [Microtask] { tasks }

    func pendingTasks() -> [Microtask] {
        let now = Date()
        return tasks.filter { t in
            t.status == .pending &&
            (t.scheduledAfter == nil || t.scheduledAfter! <= now)
        }.sorted { $0.priority > $1.priority }
    }

    func clearDone() {
        tasks.removeAll { $0.status == .done }
        save()
    }

    // MARK: - Processing

    private func drainNext() async {
        guard !isProcessing else { return }
        guard let next = pendingTasks().first else { return }
        isProcessing = true
        await run(next)
        isProcessing = false
    }

    private func run(_ task: Microtask) async {
        guard let idx = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[idx].status = .running
        save()
        print("[MICROTASK] Starting '\(task.name)': \(task.goal)")
        await EventBus.shared.emit(.microtaskStarted(id: task.id, name: task.name))

        let (output, errorReason) = await execute(task)

        guard let idx2 = tasks.firstIndex(where: { $0.id == task.id }) else { return }

        if let output {
            tasks[idx2].status = .done
            tasks[idx2].result = output
            tasks[idx2].completedAt = Date()
            save()
            print("[MICROTASK] ✅ '\(task.name)' done.")
            TaskJournal.record(command: task.goal, reply: output)
            await EventBus.shared.emit(.microtaskCompleted(id: task.id, name: task.name, result: output))
        } else {
            let reason = errorReason ?? "unknown error"
            let willRetry = tasks[idx2].retryCount < tasks[idx2].maxRetries
            tasks[idx2].retryCount += 1
            if willRetry {
                tasks[idx2].status = .pending
                tasks[idx2].scheduledAfter = Date().addingTimeInterval(60)
                print("[MICROTASK] ⚠️ '\(task.name)' failed (attempt \(tasks[idx2].retryCount)/\(tasks[idx2].maxRetries)), retrying in 60s.")
            } else {
                tasks[idx2].status = .failed
                tasks[idx2].failureReason = reason
                tasks[idx2].completedAt = Date()
                print("[MICROTASK] ❌ '\(task.name)' permanently failed: \(reason)")
            }
            save()
            await EventBus.shared.emit(.microtaskFailed(id: task.id, name: task.name, reason: reason))
        }
    }

    private func execute(_ task: Microtask) async -> (output: String?, error: String?) {
        await executor.execute(task)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Microtask].self, from: data) else { return }
        tasks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

