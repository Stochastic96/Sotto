import Testing
@testable import SottoCore

@Suite struct VocabCorrectorTests {

    @Test func builtInBrandNamesAreFixed() {
        #expect(VocabCorrector.apply(to: "I pushed to github today") == "I pushed to GitHub today")
        #expect(VocabCorrector.apply(to: "opened xcode") == "opened Xcode")
        #expect(VocabCorrector.apply(to: "building for macos") == "building for macOS")
        #expect(VocabCorrector.apply(to: "using swiftui") == "using SwiftUI")
    }

    @Test func correctionIsCaseInsensitive() {
        #expect(VocabCorrector.apply(to: "Using GITHUB actions") == "Using GitHub actions")
        #expect(VocabCorrector.apply(to: "XCODE is open") == "Xcode is open")
    }

    @Test func fillerPairsAreRemoved() {
        let result = VocabCorrector.apply(to: "I um uh want to push this")
        #expect(!result.contains("um uh"))
        #expect(result.contains("want to push this"))
    }

    @Test func uncorrectedWordsArePreserved() {
        let input = "The quick brown fox"
        #expect(VocabCorrector.apply(to: input) == input)
    }

    @Test func partialWordMatchIsNotReplaced() {
        // "ios" should not match inside "bios" (word boundary check)
        let input = "check the bios settings"
        #expect(VocabCorrector.apply(to: input) == input)
    }

    @Test func emptyStringIsHandled() {
        #expect(VocabCorrector.apply(to: "") == "")
    }
}
