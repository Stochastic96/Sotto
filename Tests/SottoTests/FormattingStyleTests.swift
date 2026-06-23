import Testing
@testable import SottoCore

@Suite struct FormattingStyleTests {

    // MARK: - .verbatim

    @Test func verbatimLeavesTextUnchanged() {
        #expect(FormattingStyle.verbatim.apply(to: "Hello.") == "Hello.")
    }

    @Test func verbatimPreservesEllipsis() {
        #expect(FormattingStyle.verbatim.apply(to: "Hmm...") == "Hmm...")
    }

    @Test func verbatimHandlesEmptyString() {
        #expect(FormattingStyle.verbatim.apply(to: "") == "")
    }

    // MARK: - .prose

    @Test func proseLeavesTextUnchanged() {
        #expect(FormattingStyle.prose.apply(to: "Hello.") == "Hello.")
    }

    @Test func prosePreservesTrailingPeriod() {
        #expect(FormattingStyle.prose.apply(to: "Done.") == "Done.")
    }

    // MARK: - .chat

    @Test func chatRemovesTrailingPeriod() {
        #expect(FormattingStyle.chat.apply(to: "Hello.") == "Hello")
    }

    @Test func chatPreservesTextWithoutPeriod() {
        #expect(FormattingStyle.chat.apply(to: "Hello") == "Hello")
    }

    @Test func chatPreservesEllipsis() {
        // "..." ends with "." but also ends with "..." — should NOT strip
        #expect(FormattingStyle.chat.apply(to: "Hmm...") == "Hmm...")
    }

    @Test func chatHandlesEmptyString() {
        #expect(FormattingStyle.chat.apply(to: "") == "")
    }

    @Test func chatHandlesPeriodOnly() {
        #expect(FormattingStyle.chat.apply(to: ".") == "")
    }

    @Test func chatHandlesMultipleSentences() {
        // Only the trailing period is stripped
        #expect(FormattingStyle.chat.apply(to: "One. Two.") == "One. Two")
    }
}
