import Testing
import Foundation
@testable import SottoCore

@Suite("PromptPrep")
struct PromptPrepTests {

    @Test func googleAdsNeedsScreenContext() {
        #expect(PromptUseCase.googleAds.needsScreenContext)
        #expect(PromptUseCase.googleAds.label == "Google Ads help")
    }

    @Test func explainScreenNeedsScreenContext() {
        #expect(PromptUseCase.explainScreen.needsScreenContext)
    }

    @Test func linkedInPostDoesNotNeedScreenContext() {
        #expect(!PromptUseCase.linkedInPost(topic: "hiring").needsScreenContext)
    }

    @Test func customDoesNotNeedScreenContext() {
        #expect(!PromptUseCase.custom(instruction: "do X").needsScreenContext)
    }

    @Test func linkedInPostInstructionIncludesTopicWhenGiven() {
        let instruction = PromptUseCase.linkedInPost(topic: "hiring").instruction
        #expect(instruction.contains("about hiring"))
    }

    @Test func linkedInPostInstructionOmitsTopicWhenNil() {
        let instruction = PromptUseCase.linkedInPost(topic: nil).instruction
        #expect(!instruction.contains("about"))
    }

    @Test func customInstructionPassesThroughVerbatim() {
        #expect(PromptUseCase.custom(instruction: "summarize this").instruction == "summarize this")
    }

    @Test func builderAppendsScreenTextWhenNeeded() {
        let prompt = PromptBuilder.build(.explainScreen, screenText: "Some screen content")
        #expect(prompt.assembledText.contains("Some screen content"))
        #expect(prompt.useCaseLabel == "Explain screen")
    }

    @Test func builderOmitsScreenTextWhenNotNeeded() {
        let prompt = PromptBuilder.build(.linkedInPost(topic: nil), screenText: "Ignored content")
        #expect(!prompt.assembledText.contains("Ignored content"))
    }

    @Test func builderOmitsScreenSectionWhenScreenTextIsBlank() {
        let prompt = PromptBuilder.build(.explainScreen, screenText: "   ")
        #expect(!prompt.assembledText.contains("currently on my screen"))
    }

    @Test func storeRoundTripsThroughUserDefaults() {
        PromptStore.clear()
        #expect(PromptStore.loadLast() == nil)

        let prompt = PreppedPrompt(id: UUID(), useCaseLabel: "Test", assembledText: "Hello", createdAt: Date())
        PromptStore.save(prompt)
        #expect(PromptStore.loadLast() == prompt)

        PromptStore.clear()
        #expect(PromptStore.loadLast() == nil)
    }
}
