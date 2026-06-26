import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels

// MARK: - SiriDelegatable Protocol

/// A Jarvis tool that can fall back to Siri when its native path fails.
///
/// **Why this exists:** Sotto has native implementations for reminders, calendar
/// events, and app launches because they work offline and preserve privacy. But
/// when those paths fail (permission denied, app not on a known path, etc.) Siri
/// is the natural next step — it already handles these domains and understands
/// natural language dates, app names, etc. `SiriDelegatable` encodes that
/// fallback relationship as a protocol so there is no silent failure.
///
/// **How to conform:**
/// 1. Change `Tool` to `SiriDelegatable` in the struct declaration.
/// 2. Add `func siriQuery(for arguments: Arguments) -> String` that converts
///    the structured args back to a natural-language Siri prompt.
/// 3. Wrap your `call()` body with `siriDelegatedCall(tool:arguments:native:)`.
///
/// Sotto never routes to Siri when the native call succeeds, so the privacy
/// and offline guarantees are preserved on the happy path.
@available(macOS 26.0, *)
protocol SiriDelegatable: Tool {
    /// Produces the natural-language Siri prompt that achieves the same goal
    /// as calling this tool with `arguments`.
    func siriQuery(for arguments: Arguments) -> String
}

// MARK: - Shared fallback helper

/// Runs `native()` and, if it signals failure, retries the same intent via Siri.
///
/// Failure is detected when the result starts with "Failed" or contains
/// "permission" — the convention used by all Jarvis native tools. On any other
/// result the value is returned unchanged, so Siri is never involved on the
/// happy path.
@available(macOS 26.0, *)
@MainActor
func siriDelegatedCall<T: SiriDelegatable>(
    tool: T,
    arguments: T.Arguments,
    native: () async throws -> String
) async throws -> String {
    let result = try await native()
    let lower = result.lowercased()
    guard lower.hasPrefix("failed") || lower.contains("permission") || lower.contains("couldn't") else {
        return result
    }
    let query = tool.siriQuery(for: arguments)
    await SiriBridge.send(query)
    return "Couldn't do it natively — routed to Siri: \"\(query)\""
}
#endif
