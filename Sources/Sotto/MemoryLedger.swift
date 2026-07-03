import Foundation

struct MemoryLedgerState: Sendable {
    let polishWarm: Bool
    let coordinatorWarm: Bool
    let osControlWarm: Bool
    let webResearcherWarm: Bool
    let scriptingWarm: Bool
    let evictions: Int
}

@MainActor
final class MemoryLedger {
    static let shared = MemoryLedger()
    private(set) var evictions = 0
    
    private init() {}
    
    func recordEviction() {
        evictions += 1
    }
    
    func fetchState() async -> MemoryLedgerState {
        let polishWarm = await AppController.shared?.intelligence?.isWarm ?? false
        let coordinatorWarm = await AppController.shared?.coordinator?.isWarm ?? false
        let osControlWarm = await OSControlAgent.shared.isWarm
        let webResearcherWarm = await WebResearcherAgent.shared.isWarm
        let scriptingWarm = await ScriptingExecutorAgent.shared.isWarm
        
        return MemoryLedgerState(
            polishWarm: polishWarm,
            coordinatorWarm: coordinatorWarm,
            osControlWarm: osControlWarm,
            webResearcherWarm: webResearcherWarm,
            scriptingWarm: scriptingWarm,
            evictions: evictions
        )
    }
}
