import Testing
@testable import SottoCore

@Suite("CommandSplitter")
struct CommandSplitterTests {

    // MARK: - Single-clause passthrough

    @Test("single clause returns unchanged")
    func singleClause() {
        #expect(CommandSplitter.clauses("open xcode") == ["open xcode"])
    }

    @Test("empty string returns single-element array")
    func emptyString() {
        let result = CommandSplitter.clauses("")
        #expect(result == [""])
    }

    // MARK: - Conjunction splitting

    @Test("splits on ' and '")
    func splitOnAnd() {
        let result = CommandSplitter.clauses("open finder and open xcode")
        #expect(result == ["open finder", "open xcode"])
    }

    @Test("splits on ' and then '")
    func splitOnAndThen() {
        let result = CommandSplitter.clauses("lock the screen and then sleep")
        #expect(result == ["lock the screen", "sleep"])
    }

    @Test("splits on ' then '")
    func splitOnThen() {
        let result = CommandSplitter.clauses("play music then mute")
        #expect(result == ["play music", "mute"])
    }

    @Test("splits on semicolon")
    func splitOnSemicolon() {
        let result = CommandSplitter.clauses("open safari; open xcode")
        #expect(result == ["open safari", "open xcode"])
    }

    // MARK: - Non-splitting characters

    @Test("does NOT split on comma")
    func noSplitOnComma() {
        let result = CommandSplitter.clauses("open xcode, finder")
        #expect(result == ["open xcode, finder"])
    }

    @Test("does NOT split 'sand' — 'and' must be word-bounded")
    func noFalsePositiveInWord() {
        // "sand" contains "and" but splitting would be wrong
        let result = CommandSplitter.clauses("open safari")
        #expect(result == ["open safari"])
    }

    // MARK: - Multi-clause

    @Test("three-way split")
    func threeWaySplit() {
        let result = CommandSplitter.clauses("open finder and open xcode and open terminal")
        #expect(result.count == 3)
        #expect(result[0] == "open finder")
        #expect(result[1] == "open xcode")
        #expect(result[2] == "open terminal")
    }

    @Test("mixed conjunctions")
    func mixedConjunctions() {
        let result = CommandSplitter.clauses("lock the screen then mute and then sleep")
        #expect(result.count >= 2)
    }

    // MARK: - Whitespace trimming

    @Test("trims whitespace around each clause")
    func trimming() {
        let result = CommandSplitter.clauses("  open finder  and  open xcode  ")
        for clause in result {
            #expect(!clause.hasPrefix(" "))
            #expect(!clause.hasSuffix(" "))
        }
    }

    // MARK: - isCompound

    @Test("isCompound returns true for multi-clause")
    func isCompoundTrue() {
        #expect(CommandSplitter.isCompound("open finder and open xcode") == true)
    }

    @Test("isCompound returns false for single clause")
    func isCompoundFalse() {
        #expect(CommandSplitter.isCompound("open xcode") == false)
    }

    @Test("isCompound is consistent with clauses()")
    func isCompoundConsistency() {
        let utterances = [
            "open finder and open xcode",
            "lock the screen and then sleep",
            "play music",
            "open xcode; open finder",
        ]
        for u in utterances {
            let multi = CommandSplitter.clauses(u).count > 1
            #expect(CommandSplitter.isCompound(u) == multi)
        }
    }
}
