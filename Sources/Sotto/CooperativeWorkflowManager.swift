import Foundation
import AppKit

/// Manages interactive, multi-turn cooperative workflows between Sotto and Siri.
/// Bypasses token costs for native system tasks while enabling proactive, contextual logic.
actor CooperativeWorkflowManager {
    static let shared = CooperativeWorkflowManager()

    enum PendingWorkflow: Sendable {
        case none
        case weatherGoOutside
    }

    private var pending: PendingWorkflow = .none

    func setPending(_ workflow: PendingWorkflow) {
        self.pending = workflow
        print("[WORKFLOW] Set pending workflow state: \(workflow)")
    }

    func getPendingState() -> PendingWorkflow {
        return pending
    }

    /// Intercepts user input if a cooperative workflow turn is pending.
    /// Returns true if the turn was consumed by the workflow.
    @MainActor
    func handleResponse(_ input: String) async -> Bool {
        let clean = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        let state = await getPendingState()
        
        switch state {
        case .none:
            return false
            
        case .weatherGoOutside:
            // Reset pending state immediately to prevent loops
            await setPending(.none)
            
            let words = clean.components(separatedBy: CharacterSet.alphanumerics.inverted).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let isYes = ["yes", "yeah", "yup", "sure", "y", "of course", "i am", "correct", "haan"].contains { phrase in
                if phrase.contains(" ") {
                    return clean.contains(phrase)
                } else {
                    return words.contains(phrase)
                }
            }
            let isNo = ["no", "nope", "nah", "not planning", "staying", "na", "nahi"].contains { phrase in
                if phrase.contains(" ") {
                    return clean.contains(phrase)
                } else {
                    return words.contains(phrase)
                }
            }
            
            if isYes {
                print("[WORKFLOW] User responded YES to weather outside. Triggering transit search.")
                AppController.shared?.hud.present(.progress("Checking transit schedule"))
                AppController.shared?.speak("Great! Let me check the transit schedule for you.")
                
                // Let siri handle the route lookup natively
                try? await Task.sleep(for: .seconds(1.2))
                await SiriBridge.send("Show bus timings to work")
                
                AppController.shared?.hud.present(.success("Opened transit route in Siri"), dismissAfter: 6)
                return true
            } else if isNo {
                print("[WORKFLOW] User responded NO to weather outside.")
                AppController.shared?.hud.present(.info("Staying inside"))
                AppController.shared?.speak("Alright, stay warm and enjoy your time indoors.")
                AppController.shared?.hud.present(.success("Stay safe inside!"), dismissAfter: 6)
                return true
            }
            
            // If they said something else, let it fall through to the normal Jarvis pipelines
            return false
        }
    }
}
