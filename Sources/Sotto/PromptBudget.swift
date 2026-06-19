import Foundation

/// Token-budget heuristics for routing between Apple Intelligence and MLX Qwen.
///
/// Apple's on-device foundation model has a ~4096-token context window. We estimate
/// ~4 characters per token and keep headroom for the response, so anything likely to
/// exhaust the window is routed to MLX Qwen (which has a larger context) instead of
/// failing with `GenerationError.exceededContextWindowSize`.
enum PromptBudget {
    /// Safe input ceiling (tokens) for Apple Intelligence, leaving room for output.
    static let appleSafeTokens = 3000

    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    /// True if the combined parts comfortably fit Apple Intelligence's window.
    static func fitsAppleWindow(_ parts: String...) -> Bool {
        parts.reduce(0) { $0 + estimatedTokens($1) } <= appleSafeTokens
    }
}
