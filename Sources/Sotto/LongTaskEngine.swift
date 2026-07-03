import Foundation
import FoundationModels

/// A durable, resumable bulk job. The point is to finish large work an 8 GB on-device
/// model could never fit in one context: the engine processes the source in small batches,
/// loading only the current batch + a compact running summary into each short session, and
/// persists progress after every batch so it survives a quit/crash.
public struct LongTask: Codable {
    public enum Status: String, Codable {
        case running, paused, done, failed
    }
    public var id: String
    public var goal: String
    public var batchCursor: Int      // count of already-processed-and-kept items at the front
    public var itemsActioned: Int    // e.g. emails trashed so far
    public var runningSummary: String
    public var status: Status
    public var createdAt: Date
}

/// Structured per-batch decision — guided generation guarantees a valid `[Int]`, so the
/// model can't hallucinate a malformed answer.
@Generable
struct PromoBatchDecision {
    @Guide(description: "Zero-based indexes of the emails in the numbered list that are promotional/marketing (newsletters, sales, deals, ads) and safe to move to Trash.")
    let promotionalIndexes: [Int]
}

/// Tool that kicks off a durable background bulk job (e.g. inbox clean-up) and returns
/// immediately with a status line. The job resumes across launches via LongTaskEngine.
struct StartLongTaskTool: Tool {
    @MainActor
    public static var wasCalled = false

    let name = "start_long_task"
    let description = "Start a durable background bulk job (e.g. 'clean all promotional emails'). Returns immediately; the job runs in the background and speaks a summary when done."

    @Generable
    struct Arguments {
        @Guide(description: "The bulk goal to accomplish in plain language, e.g. 'move all promotional emails to trash'.")
        let goal: String
    }

    func call(arguments: Arguments) async throws -> String {
        await MainActor.run { Self.wasCalled = true }
        return LongTaskEngine.start(goal: arguments.goal)
    }
}

public enum LongTaskEngine {
    private static let batchSize = 20

    private static var tasksDir: URL {
        SettingsController.sottoDataURL.appendingPathComponent("long_tasks")
    }

    // MARK: - Persistence

    private static func url(for id: String) -> URL {
        tasksDir.appendingPathComponent("\(id).json")
    }

    private static func save(_ task: LongTask) {
        try? FileManager.default.createDirectory(at: tasksDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(task) {
            try? data.write(to: url(for: task.id), options: .atomic)
        }
    }

    private static func load(_ fileURL: URL) -> LongTask? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LongTask.self, from: data)
    }

    // MARK: - Public API

    /// Start a bulk job in the background and return immediately with a short status line
    /// (so the agent's reply isn't blocked by a job that may take minutes).
    @discardableResult
    public static func start(goal: String) -> String {
        guard supports(goal: goal) else {
            return "I can't run that as a background job yet — I only handle bulk email cleanup for now."
        }
        let task = LongTask(id: UUID().uuidString, goal: goal, batchCursor: 0, itemsActioned: 0,
                            runningSummary: "", status: .running, createdAt: Date())
        save(task)
        TaskJournal.record(command: goal, reply: "Started background job \(task.id).")
        Task.detached(priority: .utility) {
            var t = task
            await run(&t)
        }
        return "On it — cleaning up your inbox in the background. I'll let you know when it's done."
    }

    /// Re-run any jobs left `running` from a previous launch (call on app start).
    public static func resumePending() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: tasksDir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let task = load(file), task.status == .running else { continue }
            print("[LONGTASK] Resuming \(task.id) at cursor \(task.batchCursor)")
            Task.detached(priority: .utility) {
                var t = task
                await run(&t)
            }
        }
    }

    // MARK: - Routing

    private static func supports(goal: String) -> Bool {
        let g = goal.lowercased()
        let isEmail = g.contains("email") || g.contains("mail") || g.contains("inbox")
        let isPromo = g.contains("promo") || g.contains("promotion") || g.contains("marketing")
            || g.contains("newsletter") || g.contains("junk") || g.contains("spam")
            || g.contains("advertis")
        return isEmail && isPromo
    }

    // MARK: - Runner

    private static func run(_ task: inout LongTask) async {
        await emptyPromotionalInbox(&task)
    }

    private static func emptyPromotionalInbox(_ task: inout LongTask) async {
        await progress("🧹 Cleaning inbox…")
        while true {
            let batch = MailConnector.fetchInboxBatch(offset: task.batchCursor, limit: batchSize)
            if batch.isEmpty { break }

            let promoIds = await classifyPromotional(batch)
            let trashed = MailConnector.moveToTrash(ids: promoIds)
            let kept = batch.count - trashed

            task.itemsActioned += trashed
            task.batchCursor += kept   // kept messages stay at the front; resume past them
            task.runningSummary += "Batch @\(task.batchCursor): trashed \(trashed)/\(batch.count).\n"
            save(task)
            print("[LONGTASK] \(task.id): batch trashed \(trashed)/\(batch.count), total \(task.itemsActioned).")
            await progress("🧹 Inbox: trashed \(task.itemsActioned) so far…")

            if batch.count < batchSize { break }  // reached the end of the inbox
        }

        task.status = .done
        save(task)
        let summary = "Done — moved \(task.itemsActioned) promotional email\(task.itemsActioned == 1 ? "" : "s") to the Trash."
        TaskJournal.record(command: task.goal, reply: summary)
        await finish(summary)
    }

    /// Decide which messages in a batch are promotional. Model-primary (Apple Intelligence,
    /// guided generation), with a high-precision keyword heuristic as the fallback.
    private static func classifyPromotional(_ batch: [MailMessage]) async -> [Int] {
        if SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: """
                You sort emails. Promotional = newsletters, sales, deals, ads, marketing blasts.
                NOT promotional = personal, work, financial, security, receipts, and transactional mail.
                """)
            var prompt = "Emails:\n"
            for (i, m) in batch.enumerated() {
                prompt += "\(i). From: \(m.sender) — Subject: \(m.subject)\n"
            }
            prompt += "\nReturn the indexes of the promotional ones."
            if let decision = try? await session.respond(to: prompt, generating: PromoBatchDecision.self,
                                                          options: GenerationOptions(temperature: 0)) {
                let valid = Set(decision.content.promotionalIndexes.filter { $0 >= 0 && $0 < batch.count })
                return valid.map { batch[$0].id }
            }
        }
        return batch.filter { MailConnector.looksPromotional($0) }.map { $0.id }
    }

    // MARK: - UI hops (back to the main actor)

    private static func progress(_ text: String) async {
        await MainActor.run { AppController.shared?.showHUD(text) }
    }

    private static func finish(_ summary: String) async {
        await MainActor.run {
            guard let app = AppController.shared else { return }
            app.showHUD("✓ " + summary)
            app.speak(summary)
        }
    }
}
