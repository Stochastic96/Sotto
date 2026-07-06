import Foundation

/// Records that a tool was invoked (for the CommandLearner's phrase→tool learning). Tools
/// hold this instead of reaching into `CommandLearner.shared`, so the global telemetry
/// dependency is explicit and a test can inject a spy that captures recorded calls.
///
/// The requirement is String-based (`argumentsJson`) so this protocol stays Foundation-only
/// and lives in SottoCore. The convenient `arguments:` overload that serializes a
/// `@Generable` value lives as a protocol extension in the Sotto target (where
/// FoundationModels is available).
public protocol CommandRecording: Sendable {
    func recordToolCall(toolName: String, argumentsJson: String) async
}
