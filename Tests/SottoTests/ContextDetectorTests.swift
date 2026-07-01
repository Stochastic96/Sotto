import Testing
@testable import SottoCore

@Suite("FormattingStyle")
struct FormattingStyleTests {

    @Test func chatStyleDropsTrailingPeriod() {
        #expect(FormattingStyle.chat.apply(to: "see you soon.") == "see you soon")
    }

    @Test func chatStylePreservesEllipsis() {
        #expect(FormattingStyle.chat.apply(to: "wait for it...") == "wait for it...")
    }

    @Test func chatStyleLeavesTextWithoutTrailingPeriodAlone() {
        #expect(FormattingStyle.chat.apply(to: "see you soon!") == "see you soon!")
    }

    @Test func verbatimStyleNeverModifiesText() {
        let text = "print(\"hello.\")"
        #expect(FormattingStyle.verbatim.apply(to: text) == text)
    }

    @Test func proseStyleNeverModifiesText() {
        let text = "This is a complete sentence."
        #expect(FormattingStyle.prose.apply(to: text) == text)
    }
}
