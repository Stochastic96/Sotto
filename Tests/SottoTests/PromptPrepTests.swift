import Testing
import Foundation
@testable import SottoCore

@Suite struct PromptUseCaseTests {

    @Test func labelsMatchExpected() {
        #expect(PromptUseCase.googleAds.label == "Google Ads help")
        #expect(PromptUseCase.linkedInPost(topic: nil).label == "LinkedIn post")
        #expect(PromptUseCase.explainScreen.label == "Explain screen")
        #expect(PromptUseCase.custom(instruction: "x").label == "Custom prompt")
    }

    @Test func screenContextRequiredForGoogleAds() {
        #expect(PromptUseCase.googleAds.needsScreenContext == true)
    }

    @Test func screenContextRequiredForExplainScreen() {
        #expect(PromptUseCase.explainScreen.needsScreenContext == true)
    }

    @Test func screenContextNotRequiredForLinkedInPost() {
        #expect(PromptUseCase.linkedInPost(topic: nil).needsScreenContext == false)
        #expect(PromptUseCase.linkedInPost(topic: "AI trends").needsScreenContext == false)
    }

    @Test func screenContextNotRequiredForCustom() {
        #expect(PromptUseCase.custom(instruction: "Do X").needsScreenContext == false)
    }

    @Test func linkedInInstructionIncludesTopic() {
        let instruction = PromptUseCase.linkedInPost(topic: "AI").instruction
        #expect(instruction.contains("about AI"))
    }

    @Test func linkedInInstructionOmitsTopicWhenNil() {
        let instruction = PromptUseCase.linkedInPost(topic: nil).instruction
        #expect(!instruction.contains(" about "))
    }

    @Test func customInstructionIsPassedThrough() {
        let text = "Translate this to French"
        #expect(PromptUseCase.custom(instruction: text).instruction == text)
    }
}

@Suite struct PromptBuilderTests {

    @Test func useCaseLabelIsPreserved() {
        let prompt = PromptBuilder.build(.googleAds, screenText: nil)
        #expect(prompt.useCaseLabel == "Google Ads help")
    }

    @Test func screenTextAppendedWhenUseCaseRequiresIt() {
        let prompt = PromptBuilder.build(.googleAds, screenText: "CTR: 2.4%")
        #expect(prompt.assembledText.contains("CTR: 2.4%"))
        #expect(prompt.assembledText.contains("currently on my screen"))
    }

    @Test func screenTextOmittedWhenUseCaseDoesNotRequireIt() {
        let prompt = PromptBuilder.build(.linkedInPost(topic: nil), screenText: "some OCR text")
        #expect(!prompt.assembledText.contains("some OCR text"))
        #expect(!prompt.assembledText.contains("currently on my screen"))
    }

    @Test func screenTextOmittedWhenNil() {
        let prompt = PromptBuilder.build(.googleAds, screenText: nil)
        #expect(!prompt.assembledText.contains("currently on my screen"))
    }

    @Test func whitespaceOnlyScreenTextIsIgnored() {
        let prompt = PromptBuilder.build(.googleAds, screenText: "   \n  ")
        #expect(!prompt.assembledText.contains("currently on my screen"))
    }

    @Test func screenTextIsTrimmedBeforeAppending() {
        let prompt = PromptBuilder.build(.googleAds, screenText: "  real content  ")
        #expect(prompt.assembledText.contains("real content"))
    }

    @Test func preppedPromptRoundTripsViaCodable() throws {
        let original = PromptBuilder.build(.explainScreen, screenText: "Hello world")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PreppedPrompt.self, from: data)
        #expect(decoded == original)
    }

    @Test func eachBuildProducesUniqueID() {
        let a = PromptBuilder.build(.googleAds, screenText: nil)
        let b = PromptBuilder.build(.googleAds, screenText: nil)
        #expect(a.id != b.id)
    }
}
