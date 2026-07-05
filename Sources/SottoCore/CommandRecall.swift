import Foundation

/// What the Jarvis Brain does when a remembered command fires.
/// - `tool`: replay a tool call natively with the exact arguments JSON captured from
///   past real calls (never synthesized — stale/guessed args must not reach tools).
/// - `kernel`: run a bound Kernel reflex by capability name; the reflex re-parses the
///   raw utterance itself, so there are no stored arguments to go stale.
public enum BrainAction: Codable, Equatable, Sendable {
    case tool(name: String, argsJson: String)
    case kernel(capability: String)
}

/// One remembered command: the canonical phrase, its embedding, and the action to run.
public struct BrainEntry: Codable, Sendable {
    public let phrase: String
    public let vector: [Double]
    public let action: BrainAction

    public init(phrase: String, vector: [Double], action: BrainAction) {
        self.phrase = phrase
        self.vector = vector
        self.action = action
    }
}

/// Pure matching logic for the Jarvis Brain associative command memory. Vectors are
/// computed by the caller (NLEmbedding lives in the app target); this stays AppKit- and
/// NaturalLanguage-free so it is unit-testable with synthetic vectors.
public enum CommandRecall {

    /// Sentence embeddings score antonyms as near-identical ("play spotify" vs "pause
    /// spotify"), so a cosine match alone could fire the opposite action. Each pair
    /// lists words that must not disagree between the query and the matched phrase.
    static let polarityPairs: [(String, String)] = [
        ("play", "pause"), ("play", "stop"),
        ("resume", "pause"), ("resume", "stop"), ("continue", "pause"),
        ("open", "close"), ("open", "quit"),
        ("on", "off"), ("up", "down"),
        ("mute", "unmute"), ("next", "previous"),
        ("start", "stop"), ("enable", "disable"),
        ("show", "hide"), ("lock", "unlock"),
        ("maximize", "minimize"),
    ]

    /// Best remembered command that survives every guard, or nil (→ fall through to
    /// the LLM). Thresholds are calibrated to Apple's `NLEmbedding` sentence model,
    /// whose scores run low: true paraphrases measure ~0.65–0.77 while unrelated
    /// commands sit ~0.2–0.4. Tool entries need a higher bar than kernel entries
    /// because they replay stored arguments verbatim, and additionally must pass the
    /// slot-consistency guard: entity swaps ("open safari" vs "open chrome",
    /// "volume to 80" vs "volume to 20") score HIGHER than paraphrases (0.82–0.94
    /// measured), so no cosine threshold alone can make argument replay safe.
    public static func match(
        queryVector: [Double],
        queryPhrase: String,
        entries: [BrainEntry],
        kernelThreshold: Double = 0.65,
        toolThreshold: Double = 0.72
    ) -> (entry: BrainEntry, similarity: Double)? {
        guard !queryVector.isEmpty else { return nil }
        var best: (entry: BrainEntry, similarity: Double)? = nil
        for entry in entries {
            let s = cosine(queryVector, entry.vector)
            guard s > (best?.similarity ?? -1) else { continue }
            guard !polarityConflict(queryPhrase, entry.phrase) else { continue }
            switch entry.action {
            case .kernel:
                guard s >= kernelThreshold else { continue }
            case .tool(_, let argsJson):
                guard s >= toolThreshold,
                      slotTokensSatisfied(query: queryPhrase, phrase: entry.phrase, argsJson: argsJson)
                else { continue }
            }
            best = (entry, s)
        }
        return best
    }

    /// Slot-consistency guard for argument replay. The "slots" are tokens that appear
    /// in BOTH the stored arguments JSON and the remembered phrase — i.e. the parts of
    /// the arguments that were originally dictated (the app name, the number, the
    /// query). Every slot token must also appear in the new utterance; otherwise the
    /// user said the same kind of command about a DIFFERENT target and replaying the
    /// old arguments would act on the wrong thing. Unparseable JSON fails closed.
    public static func slotTokensSatisfied(query: String, phrase: String, argsJson: String) -> Bool {
        guard let argTokens = jsonValueTokens(argsJson) else { return false }
        let phraseTokens = tokens(of: phrase)
        let queryTokens = tokens(of: query)
        let slots = argTokens.intersection(phraseTokens)
        return slots.isSubset(of: queryTokens)
    }

    /// Alphanumeric tokens (length ≥ 2, lowercased) of every string/number VALUE in
    /// the JSON, recursively. Nil when the JSON doesn't parse.
    static func jsonValueTokens(_ json: String) -> Set<String>? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        var out: Set<String> = []
        func walk(_ value: Any) {
            switch value {
            case let s as String: out.formUnion(tokens(of: s))
            case let n as NSNumber: out.formUnion(tokens(of: "\(n)"))
            case let arr as [Any]: arr.forEach(walk)
            case let dict as [String: Any]: dict.values.forEach(walk)
            default: break
            }
        }
        walk(root)
        return out
    }

    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    /// True when the two phrases sit on opposite sides of any polarity pair — e.g. the
    /// query says "play" where the remembered phrase says "pause". Word-boundary based
    /// so "unmute" never registers as "mute".
    public static func polarityConflict(_ query: String, _ phrase: String) -> Bool {
        let q = tokens(of: query)
        let p = tokens(of: phrase)
        for (a, b) in polarityPairs {
            let qa = q.contains(a), qb = q.contains(b)
            let pa = p.contains(a), pb = p.contains(b)
            if (qa && !qb && pb && !pa) || (qb && !qa && pa && !pb) { return true }
        }
        return false
    }

    /// Lowercased alphanumeric tokens of length ≥ 2 (so digits like "80" count as
    /// slot tokens, but stray single letters don't).
    static func tokens(of text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 2 })
    }
}
