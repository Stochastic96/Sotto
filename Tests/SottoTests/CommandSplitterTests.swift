import Testing
@testable import SottoCore

@Suite("CommandSplitter")
struct CommandSplitterTests {

    @Test func singleCommandIsNotSplit() {
        #expect(CommandSplitter.clauses("open finder") == ["open finder"])
        #expect(!CommandSplitter.isCompound("open finder"))
    }

    @Test func splitsOnAnd() {
        #expect(CommandSplitter.clauses("open finder and open xcode") == ["open finder", "open xcode"])
        #expect(CommandSplitter.isCompound("open finder and open xcode"))
    }

    @Test func splitsOnThen() {
        #expect(CommandSplitter.clauses("lock the screen then sleep") == ["lock the screen", "sleep"])
    }

    @Test func splitsOnAndThen() {
        #expect(CommandSplitter.clauses("open finder and then open xcode") == ["open finder", "open xcode"])
    }

    @Test func splitsOnSemicolon() {
        #expect(CommandSplitter.clauses("mute volume; lock screen") == ["mute volume", "lock screen"])
    }

    @Test func doesNotSplitOnCommas() {
        // Deliberately conservative: commas are ambiguous, so no split should occur.
        let text = "open xcode, finder"
        #expect(CommandSplitter.clauses(text) == [text])
        #expect(!CommandSplitter.isCompound(text))
    }

    @Test func trimsWhitespaceAroundClauses() {
        #expect(CommandSplitter.clauses("  open finder   and   open xcode  ") == ["open finder", "open xcode"])
    }

    @Test func emptyInputReturnsItselfAsSingleClause() {
        #expect(CommandSplitter.clauses("") == [""])
    }
}
