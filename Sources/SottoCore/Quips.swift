import Foundation

/// Dry, JARVIS/TARS-style one-liners for Sotto's confirmations. Kept here so the
/// deterministic (no-LLM) paths sound witty *reliably* — without trusting the small
/// on-device model to be funny on cue.
public enum Quips {
    public static func siri() -> String { siriLines.randomElement() ?? "Handing that to Siri." }
    public static func done() -> String { doneLines.randomElement() ?? "Done, boss." }
    public static func weatherTail() -> String { weatherTails.randomElement() ?? "" }

    /// An instant, zero-token opener spoken the moment routing knows which tool is about to
    /// run — so Jarvis is already talking while the model grinds. Keyed by internal tool name
    /// (never spoken back with the name); falls back to a generic opener for unmapped tools.
    public static func starting(forTool tool: String) -> String {
        (startingLines[tool] ?? genericStarting).randomElement() ?? "On it."
    }

    // Small-talk & self-knowledge pools (used by `SmallTalk` for the zero-token fast path).
    // Deliberately kept varied so repeated greetings feel live, not scripted.
    public static func greeting() -> String { greetingLines.randomElement() ?? "At your service." }
    public static func howAreYou() -> String { howAreYouLines.randomElement() ?? "Sharp as ever." }
    public static func thanks() -> String { thanksLines.randomElement() ?? "Anytime, boss." }
    public static func identity() -> String { identityLines.randomElement() ?? "Sotto's voice — your Mac's in-house assistant." }
    public static func capabilities() -> String { capabilityLines.randomElement() ?? "Open apps, run the Mac, search the web, draft scripts — and I hand the Apple errands to Siri." }

    /// A witty "that's Siri's department" line for a specific delegated domain
    /// (e.g. "reminders", "alarms"). The domain is woven into a randomly chosen template.
    public static func siriHowTo(_ domain: String) -> String {
        let cap = domain.prefix(1).uppercased() + domain.dropFirst()
        let templates = [
            "\(cap)? That's Siri's department — just say what you want and I'll pass it straight over.",
            "I let Siri handle \(domain). She lives for that stuff; I supervise.",
            "\(cap) go through Siri. Say it naturally and I'll relay it, then take the credit.",
            "For \(domain) I tap Siri on the shoulder — tell me the details and consider it handed off.",
            "\(cap)? I delegate those to Siri. One word from you and she's on it.",
        ]
        return templates.randomElement() ?? "\(cap)? I hand those to Siri."
    }

    private static let genericStarting = [
        "On it — try to look impressed.",
        "Working on it. Don't hold your breath — actually, do.",
        "Give me a second, this won't take long.",
        "Right away. I live for this.",
    ]
    private static let startingLines: [String: [String]] = [
        "open_app": [
            "Booting it up — brace for splash screens.",
            "Opening it. The disk spins, the people rejoice.",
            "Firing it up now.",
        ],
        "open_website": [
            "Pulling it up — the internet awaits.",
            "Loading it. Try to contain your excitement.",
        ],
        "web_search": [
            "Consulting the collective wisdom of the internet. Wish me luck.",
            "Searching — I'll separate the signal from the cat videos.",
            "On the hunt. Give me a beat.",
        ],
        "wikipedia_lookup": [
            "Raiding the encyclopedia so you don't have to.",
            "Checking the record. Facts incoming.",
        ],
        "control_spotify": [
            "Cueing the music. Questionable taste, but they're your ears.",
            "Spinning it up.",
        ],
        "ask_siri": [
            "Handing this to Siri. Someone has to do the easy jobs.",
            "Delegating to Siri — I'll supervise from here.",
        ],
        "get_weather": [
            "Checking the sky so you don't have to.",
            "Fetching the forecast. Don't shoot the messenger.",
        ],
        "create_note": [
            "Jotting that down before it escapes.",
            "Noted. Literally.",
        ],
    ]

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

    private static let greetingLines = [
        "Right here, boss.",
        "At your service.",
        "Listening.",
        "Go ahead — I'm all ears.",
        "Online and caffeinated. What's the move?",
        "Present and accounted for.",
    ]
    private static let howAreYouLines = [
        "Sharp as ever.",
        "Running cool — eight gigs and loving it.",
        "Never better. You?",
        "Operational and mildly smug.",
        "Peak form, obviously.",
        "All systems nominal. Thanks for asking.",
    ]
    private static let thanksLines = [
        "Anytime, boss.",
        "That's what I'm here for.",
        "Don't mention it — but I'll remember it.",
        "Pleasure's mine, naturally.",
    ]
    private static let identityLines = [
        "I'm Jarvis — Sotto's voice, living in your menu bar and running entirely on-device.",
        "Jarvis. Your Mac's in-house assistant, no cloud, no eavesdropping.",
        "The name's Jarvis. I run this Mac so you don't have to touch it.",
    ]
    private static let capabilityLines = [
        "I open apps, run the Mac — volume, windows, dark mode, sleep — search the web, read your screen, and draft scripts. The Apple errands I hand to Siri.",
        "Plenty: launch apps, control the system, search, take notes, draft skills. Reminders and messages I delegate to Siri.",
        "Think of me as the operator: apps, windows, search, screen reading, scripting. For alarms and texts, I ring Siri.",
    ]
}
