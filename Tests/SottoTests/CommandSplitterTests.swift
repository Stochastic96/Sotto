import Testing
@testable import SottoCore

@Suite struct CommandSplitterTests {

    @Test func singleCommandReturnsItself() {
        #expect(CommandSplitter.clauses("open xcode") == ["open xcode"])
        #expect(CommandSplitter.isCompound("open xcode") == false)
    }

    @Test func splitsOnAnd() {
        #expect(CommandSplitter.clauses("open finder and open xcode") == ["open finder", "open xcode"])
        #expect(CommandSplitter.isCompound("open finder and open xcode") == true)
    }

    @Test func splitsOnThen() {
        #expect(CommandSplitter.clauses("lock the screen then sleep") == ["lock the screen", "sleep"])
    }

    @Test func splitsOnAndThenAsOneBoundary() {
        // "and then" must not leave a dangling "then" clause.
        #expect(CommandSplitter.clauses("open xcode and then open terminal") == ["open xcode", "open terminal"])
    }

    @Test func splitsOnSemicolon() {
        #expect(CommandSplitter.clauses("open finder; open xcode") == ["open finder", "open xcode"])
    }

    @Test func handlesThreeClauses() {
        #expect(CommandSplitter.clauses("open finder and open xcode and open terminal")
                == ["open finder", "open xcode", "open terminal"])
    }

    @Test func trimsWhitespaceAndDropsEmpties() {
        #expect(CommandSplitter.clauses("open finder  and   ") == ["open finder"])
    }

    @Test func doesNotSplitOnComma() {
        // Commas are deliberately not boundaries — they appear inside single commands.
        #expect(CommandSplitter.clauses("open xcode, finder") == ["open xcode, finder"])
    }

    @Test func emptyInputReturnsSingleEmptyOriginal() {
        #expect(CommandSplitter.clauses("") == [""])
    }
}
