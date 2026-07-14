import Foundation

/// Deterministic, zero-token responder for small talk and self-knowledge questions —
/// greetings, "how are you", "who are you", "what can you do", and "how do you make a
/// reminder"-style capability questions. Runs BEFORE any model lane so Jarvis answers a
/// hello or a self-question instantly instead of paying a ~10 s Foundation Models round-trip.
///
/// SAFETY: this handles META-questions ONLY. An imperative like "make a reminder for 5pm"
/// or "text John I'm late" must NOT match here — it has to fall through to the real
/// pipeline (which routes it to Siri and actually performs the action). Intercepting a
/// half-command with an explanation would be the same class of bug as acting on a
/// half-spoken dictation. When in doubt, `match` returns nil and the pipeline continues.
public enum SmallTalk {

    /// A canned reply: `text` is shown in the HUD, `spoken` is what the voice says.
    public struct Reply: Sendable {
        public let text: String
        public let spoken: String
        public init(_ text: String, spoken: String? = nil) {
            self.text = text
            self.spoken = spoken ?? text
        }
    }

    /// Returns a canned reply if `raw` is small talk or a self/capability question,
    /// otherwise nil (the caller falls through to the normal Jarvis pipeline).
    public static func match(_ raw: String) -> Reply? {
        let t = normalize(raw)
        guard !t.isEmpty else { return nil }

        // 1. Bare greetings ("hi", "hey there", "good morning") — whole-utterance match
        //    only, so "hey play music" is never hijacked.
        if greetings.contains(t) {
            return Reply(Quips.greeting())
        }

        // 2. "How are you" family — whole-utterance match against known phrasings, so a
        //    real question like "how are you going to fix this" falls through.
        if howAreYou.contains(t) {
            return Reply(Quips.howAreYou())
        }

        // 3. Thanks.
        if thanks.contains(t) {
            return Reply(Quips.thanks())
        }

        // 4. Identity — "who are you", "what's your name".
        if identity.contains(t) {
            return Reply(Quips.identity())
        }

        // 5. Capabilities — "what can you do", "how can you help".
        if capabilities.contains(t) {
            return Reply(Quips.capabilities())
        }

        // 6. "How/can you <do a Siri thing>" capability questions → explain that Siri
        //    handles that domain. Two gates:
        //    - "how do/can/would you …" is always informational (a how-to question),
        //      safe to explain even with details ("how do you set a reminder for 5pm").
        //    - "can you / do you / are you able to …" can be a polite imperative, so it
        //      only matches when the remainder is short and has no concrete arguments
        //      (no time, no digits) — "can you set alarms?" explains; "can you set an
        //      alarm for 7" falls through and actually gets set.
        if let (remainder, isHowTo) = siriPrefix(in: t) {
            if let domain = siriDomain(in: remainder) {
                if isHowTo || (!hasConcreteArgs(remainder) && wordCount(remainder) <= 3) {
                    return Reply(Quips.siriHowTo(domain))
                }
            }
            // 7. "How do you <own capability>" — a question about what Jarvis itself does
            //    (open apps, search, control the Mac). Answered with a quick spoken hint, no
            //    model and no leaked tool names. Gated to the informational "how …" prefixes
            //    ONLY, so a real imperative like "can you open Xcode" still falls through and
            //    actually launches it.
            if isHowTo, let line = selfCapabilityLine(remainder) {
                return Reply(line)
            }
        }

        return nil
    }

    // MARK: - Normalization

    /// Lowercases, trims, strips any leftover "hey jarvis" wake residue (defensive — the
    /// bridge usually strips it upstream), and drops trailing sentence punctuation so
    /// "how are you?" compares equal to "how are you".
    public static func normalize(_ raw: String) -> String {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for wake in ["hey jarvis", "ok jarvis", "okay jarvis", "hi jarvis", "hello jarvis", "jarvis"] {
            if t == wake { return "" }                       // "hey jarvis" alone → greeting handled below via set
            if t.hasPrefix(wake + " ") || t.hasPrefix(wake + ",") {
                t = String(t.dropFirst(wake.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                break
            }
        }
        t.stripTrailingPunctuation()
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Siri-domain detection

    /// If `t` opens with a capability-question prefix, returns the remainder plus whether
    /// it is a "how …" phrasing (always informational). Otherwise nil.
    private static func siriPrefix(in t: String) -> (remainder: String, isHowTo: Bool)? {
        // "how you " covers the common ASR drop of "do" ("how you open" ← "how do you open").
        let howPrefixes = ["how do you ", "how can you ", "how would you ", "how do i ",
                           "how does jarvis ", "how d you ", "how you ", "how to "]
        for p in howPrefixes where t.hasPrefix(p) {
            return (String(t.dropFirst(p.count)), true)
        }
        let canPrefixes = ["can you ", "could you ", "do you ", "are you able to ", "will you "]
        for p in canPrefixes where t.hasPrefix(p) {
            return (String(t.dropFirst(p.count)), false)
        }
        return nil
    }

    /// Maps a phrase onto the Siri-delegated domain it names (mirrors `AskSiriTool`'s
    /// domain list — the single source of truth for "what goes to Siri"), or nil.
    private static func siriDomain(in phrase: String) -> String? {
        let p = phrase.lowercased()
        let table: [(keys: [String], label: String)] = [
            (["reminder", "remind"], "reminders"),
            (["alarm"], "alarms"),
            (["timer"], "timers"),
            (["calendar", "appointment", "meeting", "event"], "calendar events"),
            (["imessage", "message", "text ", "texts", " text"], "messages"),
            (["email", "e-mail", "mail"], "emails"),
            (["facetime", "video call"], "FaceTime calls"),
            (["phone call", "call ", "dial", "phone"], "phone calls"),
        ]
        for entry in table where entry.keys.contains(where: { p.contains($0) }) {
            return entry.label
        }
        return nil
    }

    /// Maps a "how do you …" question about Jarvis's OWN abilities onto a short, spoken
    /// hint that tells the user how to phrase the command — never the internal tool name.
    /// Returns nil when the phrase names no known self-capability (→ falls through).
    private static func selfCapabilityLine(_ phrase: String) -> String? {
        let p = phrase.lowercased()
        if ["open", "launch", "start ", " app", "apps"].contains(where: { p.contains($0) }) {
            return "Easy — just say \"open Safari\" or \"launch Spotify\" and it's done."
        }
        if ["search", "google", "look up", "browse", "web"].contains(where: { p.contains($0) }) {
            return "Say \"search for\" and then whatever you're after — I'll pull it up."
        }
        if ["volume", "brightness", "window", "tile", "dark mode", "lock", "sleep",
            "mute", "control", "system"].contains(where: { p.contains($0) }) {
            return "Just tell me — \"mute\", \"volume up\", \"tile left\", \"lock the screen\". I run the Mac."
        }
        if ["note", "clipboard", "screen", "script", "skill", "task", "help", "work", "do"].contains(where: { p.contains($0) }) {
            return Quips.capabilities()
        }
        return nil
    }

    /// True if the phrase carries concrete task arguments (a time, a date, a digit),
    /// which marks it as a real request to perform rather than a capability question.
    private static func hasConcreteArgs(_ phrase: String) -> Bool {
        if phrase.contains(where: \.isNumber) { return true }
        let markers = [" am", " pm", "o'clock", "tomorrow", "tonight", "today", "next ",
                       "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                       "sunday", " at ", "remind me", " me to ", " to call", " to text"]
        return markers.contains(where: { phrase.contains($0) })
    }

    private static func wordCount(_ s: String) -> Int {
        s.split(whereSeparator: { $0 == " " }).count
    }

    // MARK: - Phrase sets (whole-utterance matches, already normalized)

    private static let greetings: Set<String> = [
        "hi", "hii", "hiii", "hey", "heya", "hiya", "hello", "hullo", "yo", "sup",
        "howdy", "greetings", "hey there", "hello there", "hi there", "good to see you",
        "good morning", "good afternoon", "good evening", "good night",
        "morning", "afternoon", "evening",
        "you there", "are you there", "you awake", "you up", "you online", "wake up",
    ]

    private static let howAreYou: Set<String> = [
        "how are you", "how are you doing", "how are you today", "how you doing",
        "how're you", "how's it going", "hows it going", "how is it going",
        "how do you do", "how are things", "how's things", "hows things",
        "what's up", "whats up", "what up", "how's life", "hows life",
        "you good", "are you good", "you okay", "are you okay", "how have you been",
        "how you been", "everything good", "all good",
    ]

    private static let thanks: Set<String> = [
        "thanks", "thank you", "thanks a lot", "thank you so much", "cheers",
        "appreciate it", "much appreciated", "nice one", "good job", "well done",
    ]

    private static let identity: Set<String> = [
        "who are you", "what are you", "what's your name", "whats your name",
        "what is your name", "your name", "who am i talking to", "who is this",
        "what are you called", "introduce yourself", "tell me about yourself",
    ]

    private static let capabilities: Set<String> = [
        "what can you do", "what do you do", "what can you help with",
        "what can you help me with", "how can you help", "how can you help me",
        "what are you capable of", "what are your capabilities", "what are your features",
        "what can i ask you", "what should i say", "what commands can i use",
        "help", "what can you do for me",
    ]

    /// Greeting / how-are-you / thanks phrasings, exposed so lane routing (`JarvisProfile`)
    /// shares this ONE source of truth instead of maintaining a parallel greeting list.
    /// `match` intercepts whole-utterance small talk first; routing uses these for the
    /// looser "is this utterance chatty" prefix check on what slips through.
    public static let smallTalkPhrases: Set<String> = greetings.union(howAreYou).union(thanks)
}
