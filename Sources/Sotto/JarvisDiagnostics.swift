import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - JarvisDiagnostics
//
// Wraps the Apple Foundation Models `LanguageModelFeedback` API.
// Docs: https://developer.apple.com/documentation/foundationmodels/languagemodelfeedback
//
// Usage pattern:
//   1. Call `record(session:error:input:)` whenever a Foundation Models call fails or
//      produces an unexpected result.
//   2. The feedback is serialized to JSON in sotto-data/diagnostics/
//   3. User can attach those JSON files to Feedback Assistant reports to Apple, which
//      accelerates model improvements specific to Sotto's use cases.
//
// The macOS Feedback Assistant app reads these log files automatically when
// session.logFeedbackAttachment is used — it's the official channel for
// reporting Foundation Models issues to Apple engineers.

enum JarvisDiagnostics {

    // MARK: - Record feedback for unexpected model behaviour

    /// Call after any Foundation Models error or misbehavior.
    /// Writes a structured JSON attachment to sotto-data/diagnostics/
    /// that the user can attach to a Feedback Assistant report.
    @available(macOS 26.0, *)
    static func record(
        session: AnyObject?,
        error: Error? = nil,
        input: String,
        description: String,
        category: FeedbackCategory = .modelError
    ) {
        #if canImport(FoundationModels)
        guard let lmSession = session as? LanguageModelSession else { return }

        let issue = LanguageModelFeedback.Issue(
            category: category.toFoundationModels,
            explanation: "\(description) | Input: \(input.prefix(200)) | Error: \(error?.localizedDescription ?? "none")"
        )

        let data = lmSession.logFeedbackAttachment(
            sentiment: .negative,
            issues: [issue],
            desiredResponseText: nil
        )

        // Persist to disk so the user can attach it to Feedback Assistant.
        let dir = URL.sottoDataDirectory.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "feedback_\(Int(Date().timeIntervalSince1970)).json"
        try? data.write(to: dir.appendingPathComponent(filename))
        print("[DIAGNOSTICS] Feedback logged: \(filename) — attach to Feedback Assistant to report this model issue to Apple.")
        #endif
    }

    /// Call when a model response is good — helps Apple tune the model for Sotto's patterns.
    @available(macOS 26.0, *)
    static func recordPositive(session: AnyObject?, input: String) {
        #if canImport(FoundationModels)
        guard let lmSession = session as? LanguageModelSession else { return }
        let data = lmSession.logFeedbackAttachment(sentiment: .positive, issues: [])
        let dir = URL.sottoDataDirectory.appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "feedback_pos_\(Int(Date().timeIntervalSince1970)).json"
        try? data.write(to: dir.appendingPathComponent(filename))
        #endif
    }

    // MARK: - Capability check

    /// Returns true if the system model supports tool calling on this device.
    /// Call this at startup to surface clear diagnostic info instead of silent failures.
    @available(macOS 26.0, *)
    static func reportAvailability() {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            print("[DIAGNOSTICS] Apple Intelligence: ✅ available")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                print("[DIAGNOSTICS] Apple Intelligence: ❌ device not eligible (requires A17 Pro / M1+ with 8GB+)")
            case .appleIntelligenceNotEnabled:
                print("[DIAGNOSTICS] Apple Intelligence: ❌ disabled — enable in System Settings ▸ Apple Intelligence & Siri")
            case .modelNotReady:
                print("[DIAGNOSTICS] Apple Intelligence: ⏳ model downloading or not ready yet — try again shortly")
            @unknown default:
                print("[DIAGNOSTICS] Apple Intelligence: ❌ unavailable for an unknown reason")
            }
        }
        #else
        print("[DIAGNOSTICS] FoundationModels framework not available on this build target.")
        #endif
    }

    // MARK: - Feedback categories

    enum FeedbackCategory {
        case modelError         // threw an error when it shouldn't
        case guardrailFired     // safety guardrail triggered incorrectly
        case tooVerbose         // response was excessively long
        case didNotFollowIntent // model ignored or misunderstood the instruction
        case toolCallLoop       // model called tools repeatedly without resolving

        #if canImport(FoundationModels)
        @available(macOS 26.0, *)
        var toFoundationModels: LanguageModelFeedback.Issue.Category {
            switch self {
            case .modelError:         return .incorrect
            case .guardrailFired:     return .triggeredGuardrailUnexpectedly
            case .tooVerbose:         return .tooVerbose
            case .didNotFollowIntent: return .didNotFollowInstructions
            case .toolCallLoop:       return .unhelpful
            }
        }
        #endif
    }
}

// MARK: - Integrate diagnostics into SottoIntelligence error handling

extension SottoIntelligence {
    /// Call after a successful polish/completion to submit positive feedback,
    /// helping Apple tune the on-device model for dictation polish patterns.
    @available(macOS 26.0, *)
    func submitPositiveFeedback(for session: AnyObject, input: String) {
        Task.detached(priority: .background) {
            JarvisDiagnostics.recordPositive(session: session, input: input)
        }
    }
}

// MARK: - URL helper

private extension URL {
    static var sottoDataDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Projects/Sotto/sotto-data")
    }
}
