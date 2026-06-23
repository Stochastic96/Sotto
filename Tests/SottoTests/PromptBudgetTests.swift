import Testing
@testable import SottoCore

@Suite struct PromptBudgetTests {

    @Test func emptyStringMinimumOneToken() {
        #expect(PromptBudget.estimatedTokens("") == 1)
    }

    @Test func tokenCountIsCharsDividedByFour() {
        #expect(PromptBudget.estimatedTokens("abcd") == 1)
        #expect(PromptBudget.estimatedTokens("abcdefgh") == 2)
        #expect(PromptBudget.estimatedTokens(String(repeating: "a", count: 400)) == 100)
    }

    @Test func shortTextFitsWindow() {
        #expect(PromptBudget.fitsAppleWindow("Hello, world!"))
    }

    @Test func oversizedTextDoesNotFit() {
        // 16001 tokens requires > 64004 chars (integer division floors)
        let huge = String(repeating: "a", count: 64004)
        #expect(!PromptBudget.fitsAppleWindow(huge))
    }

    @Test func exactBoundaryFits() {
        // 64000 chars / 4 = 16000 tokens == appleSafeTokens
        let boundary = String(repeating: "a", count: 64000)
        #expect(PromptBudget.fitsAppleWindow(boundary))
    }

    @Test func multiplePartsAccumulateTokens() {
        // 4 parts × 4000 tokens = 16000 — exactly at limit
        let part = String(repeating: "a", count: 16000) // 4000 tokens
        #expect(PromptBudget.fitsAppleWindow(part, part, part, part))
        // One extra token pushes it over
        #expect(!PromptBudget.fitsAppleWindow(part, part, part, part, "aaaa"))
    }
}
