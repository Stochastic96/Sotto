import Foundation

/// Dry, JARVIS/TARS-style one-liners for Sotto's confirmations. Kept here so the
/// deterministic (no-LLM) paths sound witty *reliably* — without trusting the small
/// on-device model to be funny on cue.
enum Quips {
    static func siri() -> String { siriLines.randomElement() ?? "Handing that to Siri." }
    static func done() -> String { doneLines.randomElement() ?? "Done, boss." }
    static func weatherTail() -> String { weatherTails.randomElement() ?? "" }

    private static let siriLines = [
        "Handing that to Siri — brace for mild competence.",
        "Off to Siri. Someone has to do the easy jobs.",
        "Delegating to Siri. I'll take the credit, naturally.",
        "Siri's on it, boss. I'll supervise from here.",
        "Passing it down to Siri. Try to act impressed.",
    ]
    private static let doneLines = [
        "Done. You're welcome.",
        "Handled. Effortlessly, obviously.",
        "Consider it done, boss.",
        "Easy. Don't tell the other apps.",
    ]
    private static let weatherTails = [
        "Dress accordingly, genius.",
        "Don't shoot the messenger.",
        "I just report it, I don't arrange it.",
        "Umbrella optional, drama not included.",
    ]
}
