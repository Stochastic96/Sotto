import Foundation

/// Token-budget heuristics for routing between Apple Intelligence and MLX Qwen.
///
/// Apple's newer on-device foundation models support a much larger context window (up to 32k).
/// We set a higher safe input ceiling to accommodate longer screen parses and history context
/// while keeping MLX Qwen as a fallback for extremely large tasks.
public enum PromptBudget {
    /// Safe input ceiling (tokens) for Apple Intelligence, leaving room for output.
    public static let appleSafeTokens = 16000

    public static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// True if the combined parts comfortably fit Apple Intelligence's window.
    public static func fitsAppleWindow(_ parts: String...) -> Bool {
        parts.reduce(0) { $0 + estimatedTokens($1) } <= appleSafeTokens
    }
}
