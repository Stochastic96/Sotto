import AppKit
import AVFoundation
import SottoCore

extension AppController {
    
    // MARK: - Dictation pipeline (⌘⇧K) — PURE dictation: listen → AI polish → paste.
    //         No commands, no tasks, no Jarvis. Those live only in the Jarvis pipeline.
    
    func runDictationPipeline(raw: String, samples: [Float], context: AppContext) async {
        // PURE dictation only. The explicit dictation → Jarvis bridge (wake-word delegation) is
        // handled upstream in `AppController.endRecording`; by the time we get here the utterance
        // is guaranteed to be dictation (a `.none`/`.nearMiss` `BridgeDecision`), never a command.
        let pipelineStart = CFAbsoluteTimeGetCurrent()
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var polishDuration = 0.0

        // Deterministically strip filler / hesitation words ("um", "uh", "mm", "blah")
        // BEFORE anything else, so they're gone even when polish is skipped (short
        // utterances) or rejected. Never trust the LLM alone to remove disfluencies.
        text = DisfluencyFilter.strip(text)

        guard !text.isEmpty else {
            state = .idle
            hud.hide()
            return
        }
        
        // Skip polish for short inputs — saves 2-3 seconds on quick commands
        let wordCount = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        let skipPolish = wordCount < 6 || text.count < 40
        
        // AI polish (Apple Intelligence, warm) with a 15s safety timeout + sanity checks.
        if polishEnabled && !skipPolish, let intel = self.intelligence {
            state = .polishing
            // No polish spinner: the sneak-preview is (or is about to be) gone and
            // the polished text just appears in the app. We deliberately "use" the
            // polish time behind the already-visible preview instead of a spinner.
            let polishStart = CFAbsoluteTimeGetCurrent()
            let refinementTask = Task { [self, text] in
                let chunks = Self.splitIntoChunks(text)
                if chunks.count <= 1 {
                    // Stream partial snapshots to the HUD so the user sees characters
                    // arriving live instead of waiting 2-4s for the whole result.
                    return try await intel.refine(text, context: context, history: self.recentTranscripts) { @MainActor [weak self] partial in
                        // High-frequency display-only channel — never retriggers
                        // the structural HUD animation per streamed token.
                        self?.hud.updateProgressDetail(String(partial.suffix(60)))
                    }
                } else {
                    var polishedChunks: [String] = []
                    final class StringBox: @unchecked Sendable {
                        var value = ""
                    }
                    let accumulated = StringBox()
                    for chunk in chunks {
                        let partialProgress: @Sendable @MainActor (String) -> Void = { @MainActor [weak self, accumulated] partial in
                            let hudText = accumulated.value + (accumulated.value.isEmpty ? "" : "\n\n") + partial
                            self?.hud.updateProgressDetail(String(hudText.suffix(60)))
                        }
                        let polishedChunk = try await intel.refine(chunk, context: context, history: self.recentTranscripts, onProgress: partialProgress)
                        polishedChunks.append(polishedChunk)
                        accumulated.value += (accumulated.value.isEmpty ? "" : "\n\n") + polishedChunk
                    }
                    return polishedChunks.joined(separator: "\n\n")
                }
            }
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(15))
                refinementTask.cancel()
            }
            do {
                let polished = try await refinementTask.value
                timeoutTask.cancel()
                if isAcceptablePolish(original: text, polished: polished) {
                    text = polished
                }
            } catch {
                print("[DICTATION] AI Polish failed/timed out: \(error.localizedDescription). Using raw text.")
                refinementTask.cancel()
            }
            polishDuration = CFAbsoluteTimeGetCurrent() - polishStart
        }
        
        // Bail before touching the target app if the user aborted during polish —
        // cancelCurrent() already reset the HUD/state; typing now would be a surprise.
        if Task.isCancelled { return }

        soundTink?.play()

        // Reactivate the target app and paste. No search shortcuts, no files, no commands.
        // yieldActivation (macOS 14+) makes focus transfer faster; 80ms is ample after that.
        if let app = self.lastActiveApp {
            if #available(macOS 14.0, *) { NSApplication.shared.yieldActivation(to: app) }
            app.activate(options: [])
            try? await Task.sleep(for: .milliseconds(80))
        }
        await injector.inject(text, fileURL: nil, targetPID: lastActiveApp?.processIdentifier)
        
        statusBar.lastTranscript = text
        recentTranscripts.append(text)
        if recentTranscripts.count > 5 { recentTranscripts.removeFirst() }
        CommandEngine.lastResult = text
        learnFromDictation(raw: raw, polished: text)
        await EventBus.shared.emit(.userSpoke(text))
        DatasetLogger.shared.log(mode: "dictation", app: lastActiveApp?.localizedName, rawTranscript: raw, response: text, kind: "polish", samples: samples)
        
        let total = CFAbsoluteTimeGetCurrent() - pipelineStart
        print("[BENCHMARK] Dictation \(String(format: "%.0f", total * 1000))ms (polish: \(String(format: "%.0f", polishDuration * 1000))ms)")
        // Silent finish: the text appearing in the user's app IS the confirmation
        // (plus the soundTink above). No box, no notification — the minimal path.
        self.updateMemoryLedger()
        state = .idle
        hud.hide()
    }
    
    /// Sanity-checks an AI-polished dictation against truncation / expansion / loops.
    func isAcceptablePolish(original: String, polished: String) -> Bool {
        if polished.isEmpty { return false }
        let originalWords = original.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let polishedWords = polished.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if (polishedWords.count < Int(Double(originalWords.count) * 0.6)) || (originalWords.count >= 8 && polishedWords.count <= 3) {
            print("[DICTATION] Polish truncated; using raw."); return false
        }
        if (Double(polishedWords.count) > Double(originalWords.count) * 2.5) && originalWords.count >= 6 {
            print("[DICTATION] Polish expanded (likely hallucination); using raw."); return false
        }
        if hasRepetitiveLoops(polished) {
            print("[DICTATION] Polish looped; using raw."); return false
        }
        // Content-overlap guard: a weak model can echo a few-shot example or a prior
        // dictation instead of polishing the current input. Such output passes the
        // length checks (similar word count) but shares almost no words with the raw
        // transcript. Require meaningful overlap, else fall back to raw.
        let origSet = Set(originalWords.map { $0.lowercased() }.filter { $0.count > 3 })
        let polSet = Set(polishedWords.map { $0.lowercased() }.filter { $0.count > 3 })
        if originalWords.count >= 5, !origSet.isEmpty {
            let overlap = Double(origSet.intersection(polSet).count) / Double(origSet.count)
            if overlap < 0.45 {
                print("[DICTATION] Polish unrelated to input (overlap \(String(format: "%.0f%%", overlap * 100))); using raw.")
                return false
            }
        }
        return true
    }
    
    func learnFromDictation(raw: String, polished: String) {
        let cleanRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPolished = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanRaw.isEmpty && !cleanPolished.isEmpty else { return }
        
        // Don't learn style if the polished text still contains obvious filler words, disfluencies, or placeholders
        let lowerPolished = cleanPolished.lowercased()
        let fillerCheckWords = lowerPolished.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        let fillerWords: Set<String> = ["um", "uh", "ah", "umh", "blah"]
        for word in fillerCheckWords {
            if fillerWords.contains(word) {
                print("[LEARNING] Skipping learning: Polished text still contains filler '\(word)'")
                return
            }
        }
        if lowerPolished.contains("something like that") {
            print("[LEARNING] Skipping learning: Polished text still contains filler 'something like that'")
            return
        }
        
        // 1. Learn Style Examples (only if they are structurally different, meaning actual word cleaning occurred)
        let normRaw = cleanRaw.lowercased().filter { $0.isLetter || $0.isNumber }
        let normPolished = cleanPolished.lowercased().filter { $0.isLetter || $0.isNumber }
        // Only learn from a polish that did MEANINGFUL work. A near-identical pair (e.g.
        // "jargons" → "jargon") taught as a style example tells the model "don't change
        // anything," which is exactly the weak-polish behaviour we're trying to fix.
        if normRaw != normPolished, !Self.isTrivialEdit(normRaw, normPolished) {
            // Don't learn style if the polished text has repetitive loops
            if hasRepetitiveLoops(cleanPolished) {
                print("[LEARNING] Skipping learning: Polished text contains repetitive loops")
                return
            }
            
            // Don't learn style if the polished text is excessively long (hallucinated)
            let rawWords = cleanRaw.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let polishedWords = cleanPolished.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if rawWords.count >= 6 && Double(polishedWords.count) > Double(rawWords.count) * 2.5 {
                print("[LEARNING] Skipping learning: Polished text is excessively long compared to raw text")
                return
            }
            
            var examples: [DictationExample] = []
            if let data = UserDefaults.standard.data(forKey: "sotto_style_examples"),
               let decoded = try? JSONDecoder().decode([DictationExample].self, from: data) {
                examples = decoded
            }
            
            // Check if this example is already in the list
            if !examples.contains(where: { $0.raw == cleanRaw && $0.polished == cleanPolished }) {
                examples.append(DictationExample(raw: cleanRaw, polished: cleanPolished))
                if examples.count > 5 {
                    examples.removeFirst()
                }
                if let encoded = try? JSONEncoder().encode(examples) {
                    UserDefaults.standard.set(encoded, forKey: "sotto_style_examples")
                    print("[LEARNING] Saved new dictation style example: \(cleanRaw) -> \(cleanPolished)")
                }
            }
        }
        
        // 2. Learn Vocabulary / Jargon (Proper nouns, camelCase, technical terms, acronyms)
        let words = cleanPolished.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        var newJargon: Set<String> = []
        for (idx, word) in words.enumerated() {
            guard word.count >= 3 else { continue }
            
            let isFirstWord = (idx == 0)
            let hasNumber = word.contains { $0.isNumber }
            let isAllUppercase = word == word.uppercased()
            let hasInternalCapitals = word.dropFirst().contains { $0.isUppercase }
            
            // Only learn GENUINE jargon: ACRONYMS (CSRD), camelCase / internal caps
            // (FaceTime), or alphanumeric tokens (HRV2). Plain capitalized words are NOT
            // learned: at a sentence start almost every word is capitalized ("Sometime",
            // "Whole", "Not"), and the old `isPlainCapitalized` heuristic captured exactly
            // that noise — which was then injected into the polish prompt as "names and
            // jargon to spell correctly," degrading polish quality. Real proper nouns the
            // user cares about belong in Settings ▸ Custom Vocabulary, not auto-guessed.
            _ = isFirstWord
            let looksLikeJargon = isAllUppercase || hasInternalCapitals || hasNumber

            if looksLikeJargon, !AppController.commonWordStopList.contains(word.lowercased()) {
                newJargon.insert(word)
            }
        }
        
        if !newJargon.isEmpty {
            let existing = UserDefaults.standard.stringArray(forKey: "sotto_learned_vocabulary") ?? []
            // Case-insensitive dedup: keep one variant per word, preferring the one with
            // more uppercase letters (so "CSRD" wins over "Csrd").
            var byKey: [String: String] = [:]
            for term in existing + Array(newJargon) {
                let key = term.lowercased()
                if let current = byKey[key] {
                    let curUpper = current.filter { $0.isUppercase }.count
                    let newUpper = term.filter { $0.isUppercase }.count
                    if newUpper > curUpper { byKey[key] = term }
                } else {
                    byKey[key] = term
                }
            }
            var vocabArray = byKey.values.sorted()
            if vocabArray.count > 100 { vocabArray = Array(vocabArray.prefix(100)) }
            if vocabArray != existing.sorted() {
                UserDefaults.standard.set(vocabArray, forKey: "sotto_learned_vocabulary")
                print("[LEARNING] Learned new vocabulary terms: \(newJargon)")
            }
        }

        // Invalidate the intelligence actor's vocab/style cache so the next refine()
        // picks up the freshly written defaults without a per-call UserDefaults read.
        if let intel = intelligence {
            Task { await intel.refreshUserCaches() }
        }
    }

    /// True when `b` is only a trivial edit of `a` (e.g. a single typo fixed) — judged by
    /// how much of the longer string is unchanged at its head and tail. Such pairs aren't
    /// worth saving as style examples; they'd teach the polisher to leave speech alone.
    static func isTrivialEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ac = Array(a), bc = Array(b)
        let maxLen = max(ac.count, bc.count)
        guard maxLen > 0 else { return true }
        var prefix = 0
        while prefix < ac.count && prefix < bc.count && ac[prefix] == bc[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < (ac.count - prefix) && suffix < (bc.count - prefix)
            && ac[ac.count - 1 - suffix] == bc[bc.count - 1 - suffix] { suffix += 1 }
        let changed = maxLen - prefix - suffix
        return Double(changed) / Double(maxLen) < 0.10   // <10% of chars changed ⇒ trivial
    }

    /// Common English words that are NOT jargon even when capitalized (sentence starts,
    /// fillers, frequent words). Kept lowercased for case-insensitive matching.
    static let commonWordStopList: Set<String> = [
        "and", "the", "you", "for", "not", "but", "get", "set", "out", "yes", "yeah",
        "yep", "nope", "okay", "this", "that", "these", "those", "what", "when", "where",
        "why", "who", "which", "then", "there", "here", "now", "just", "also", "with",
        "from", "into", "about", "over", "under", "after", "before", "some", "any", "all",
        "have", "has", "had", "will", "would", "could", "should", "can", "may", "might",
        "must", "want", "need", "please", "well", "actually", "maybe", "really", "very",
        "too", "let", "lets", "because", "check", "make", "like", "how", "hey", "say",
        "tell", "ask", "open", "start", "stop", "thanks", "thank", "sure", "fine"
    ]
    
    static func splitIntoChunks(_ text: String, maxWordsPerChunk: Int = 80) -> [String] {
        // Split by paragraph first
        let paragraphs = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var chunks: [String] = []
        
        for para in paragraphs {
            let words = para.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if words.count <= maxWordsPerChunk {
                chunks.append(para)
            } else {
                // Split by sentence boundaries within the paragraph
                var currentChunk: [String] = []
                var currentWordCount = 0
                
                var currentSentence = ""
                for char in para {
                    currentSentence.append(char)
                    if char == "." || char == "?" || char == "!" {
                        let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let sentenceWords = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                            if currentWordCount + sentenceWords.count > maxWordsPerChunk && !currentChunk.isEmpty {
                                chunks.append(currentChunk.joined(separator: " "))
                                currentChunk = [trimmed]
                                currentWordCount = sentenceWords.count
                            } else {
                                currentChunk.append(trimmed)
                                currentWordCount += sentenceWords.count
                            }
                        }
                        currentSentence = ""
                    }
                }
                let remainder = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    currentChunk.append(remainder)
                }
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk.joined(separator: " "))
                }
            }
        }

        // Hard fallback: a long UNPUNCTUATED transcript (legacy backend, raw ASR) has no
        // sentence boundaries to split on and would come back as one giant chunk — which
        // is exactly the context overflow chunking exists to prevent. Split it by word
        // count; a mid-sentence seam is far cheaper than a truncated polish.
        var bounded: [String] = []
        for chunk in chunks {
            let words = chunk.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            if words.count <= maxWordsPerChunk + 20 {
                bounded.append(chunk)
            } else {
                var start = 0
                while start < words.count {
                    let end = min(start + maxWordsPerChunk, words.count)
                    bounded.append(words[start..<end].joined(separator: " "))
                    start = end
                }
            }
        }
        return bounded
    }
}
