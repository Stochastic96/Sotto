import Foundation

/// A specialized agent the CoordinatorAgent can hand a task off to. The three production
/// conformers — `OSControlAgent`, `WebResearcherAgent`, `ScriptingExecutorAgent` — are warm
/// `LanguageModelSession`-backed actors in the Sotto target. Delegation tools hold this
/// protocol instead of a concrete `.shared`, so coordinator routing can be tested with a
/// fake agent that returns canned output (no on-device model spin-up).
///
/// Note: warm-session lifecycle (`isWarm`/`unload()`, driven by AppController's
/// memory-pressure observer and MemoryLedger) stays on the concrete actors — it is not part
/// of this delegation contract, so eviction still targets the shared instances directly.
public protocol SubAgent: Sendable {
    func run(task: String) async -> String
}
