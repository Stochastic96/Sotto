import Testing
@testable import SottoCore

@Suite("CommandRecall")
struct CommandRecallTests {

    private func kernelEntry(_ phrase: String, _ vector: [Double]) -> BrainEntry {
        BrainEntry(phrase: phrase, vector: vector, action: .kernel(capability: "media_play"))
    }

    private func toolEntry(_ phrase: String, _ vector: [Double], args: String) -> BrainEntry {
        BrainEntry(phrase: phrase, vector: vector, action: .tool(name: "open_app", argsJson: args))
    }

    @Test func topMatchAboveThresholdWins() {
        let entries = [
            kernelEntry("pause spotify", [1, 0, 0]),
            kernelEntry("resume the music", [0.9, 0.1, 0]),   // closer to the query
        ]
        let hit = CommandRecall.match(
            queryVector: [0.92, 0.08, 0], queryPhrase: "resume my music please",
            entries: entries)
        #expect(hit?.entry.phrase == "resume the music")
        #expect((hit?.similarity ?? 0) > 0.99)
    }

    @Test func belowThresholdReturnsNil() {
        let entries = [kernelEntry("open safari", [1, 0, 0])]
        let hit = CommandRecall.match(
            queryVector: [0.5, 0.87, 0], queryPhrase: "write me a poem",   // cosine ≈ 0.5
            entries: entries)
        #expect(hit == nil)
    }

    @Test func polarityGuardRejectsAntonyms() {
        // Embeddings score "play X" vs "pause X" as near-identical; the guard must
        // reject even a perfect cosine match when the phrases disagree on polarity.
        let entries = [kernelEntry("pause spotify", [1, 0, 0])]
        let hit = CommandRecall.match(
            queryVector: [1, 0, 0], queryPhrase: "play spotify",
            entries: entries)
        #expect(hit == nil)
    }

    @Test func guardedTopHitYieldsToPassingRunnerUp() {
        // The best cosine hit fails the polarity guard; a slightly weaker but
        // guard-clean entry should win instead of the whole match failing.
        let entries = [
            kernelEntry("pause the music", [1, 0, 0]),
            kernelEntry("start the music", [0.99, 0.14, 0]),
        ]
        let hit = CommandRecall.match(
            queryVector: [1, 0, 0], queryPhrase: "play the music",
            entries: entries)
        #expect(hit?.entry.phrase == "start the music")
    }

    @Test func slotGuardRejectsEntitySwap() {
        // "open chrome" vs remembered "open safari" scores ABOVE the paraphrase band
        // (0.82+ measured on NLEmbedding) — the slot guard must catch what no cosine
        // threshold can: the stored args are about a different target.
        let entries = [toolEntry("open safari for me", [1, 0, 0], args: #"{"appName":"Safari"}"#)]
        #expect(CommandRecall.match(
            queryVector: [1, 0, 0], queryPhrase: "open chrome for me",
            entries: entries) == nil)
        // Same command about the SAME target passes.
        #expect(CommandRecall.match(
            queryVector: [1, 0, 0], queryPhrase: "get safari up for me",
            entries: entries) != nil)
    }

    @Test func slotGuardCoversNumbers() {
        let entries = [toolEntry("set volume to 80", [1, 0, 0], args: #"{"level":80}"#)]
        // 0.938 measured similarity for a different level — must still be rejected.
        #expect(CommandRecall.match(
            queryVector: [1, 0, 0], queryPhrase: "set volume to 20",
            entries: entries) == nil)
        #expect(CommandRecall.match(
            queryVector: [1, 0, 0], queryPhrase: "put the volume at 80",
            entries: entries) != nil)
    }

    @Test func slotGuardFailsClosedOnBadJson() {
        let entries = [toolEntry("open safari", [1, 0, 0], args: "not json at all")]
        #expect(CommandRecall.match(
            queryVector: [1, 0, 0], queryPhrase: "open safari",
            entries: entries) == nil)
    }

    @Test func slotTokensIgnoreUndictatedArgValues() {
        // Args tokens that never appeared in the remembered phrase (e.g. an enum case
        // the model chose, like "playPause") are not slots — only dictated content
        // constrains the query.
        #expect(CommandRecall.slotTokensSatisfied(
            query: "put the music on hold",
            phrase: "stop the music",
            argsJson: #"{"action":"playPause","query":null}"#))
        // But a dictated arg value ("pause" appears in the phrase) must be present in
        // the query — conservative rejection sends the turn to the LLM instead.
        #expect(!CommandRecall.slotTokensSatisfied(
            query: "spotify please",
            phrase: "pause spotify",
            argsJson: #"{"action":"pause"}"#))
    }

    @Test func polarityConflictPairs() {
        #expect(CommandRecall.polarityConflict("play spotify", "pause spotify"))
        #expect(CommandRecall.polarityConflict("close the window", "open the window"))
        #expect(CommandRecall.polarityConflict("turn wifi off", "turn wifi on"))
        #expect(CommandRecall.polarityConflict("volume down", "volume up"))
        #expect(CommandRecall.polarityConflict("next song", "previous song"))
        // Same side of a pair — no conflict.
        #expect(!CommandRecall.polarityConflict("pause the music", "pause spotify"))
        // Word-boundary safety: "unmute" must not register as "mute".
        #expect(!CommandRecall.polarityConflict("unmute the mac", "unmute sound"))
        #expect(CommandRecall.polarityConflict("unmute the mac", "mute sound"))
        // Unrelated phrases never conflict.
        #expect(!CommandRecall.polarityConflict("open safari", "search for cats"))
    }

    @Test func degenerateInputsReturnNil() {
        let entries = [kernelEntry("open safari", [1, 0, 0])]
        // Empty query vector.
        #expect(CommandRecall.match(queryVector: [], queryPhrase: "open safari",
                                    entries: entries) == nil)
        // Empty store.
        #expect(CommandRecall.match(queryVector: [1, 0, 0], queryPhrase: "open safari",
                                    entries: []) == nil)
        // Dimension mismatch scores 0 → below threshold.
        #expect(CommandRecall.match(queryVector: [1, 0], queryPhrase: "open safari",
                                    entries: entries) == nil)
        // Zero vector never divides by zero.
        #expect(CommandRecall.match(queryVector: [0, 0, 0], queryPhrase: "open safari",
                                    entries: entries) == nil)
    }

    @Test func cosineBasics() {
        #expect(abs(CommandRecall.cosine([1, 0], [1, 0]) - 1.0) < 1e-9)
        #expect(abs(CommandRecall.cosine([1, 0], [0, 1])) < 1e-9)
        #expect(CommandRecall.cosine([1, 0], [1, 0, 0]) == 0)   // mismatched dims
        #expect(CommandRecall.cosine([0, 0], [0, 0]) == 0)      // zero denom
    }
}
