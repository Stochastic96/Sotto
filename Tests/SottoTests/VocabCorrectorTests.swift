import Testing
import Foundation
@testable import SottoCore

// Serialized: addCorrection/removeCorrection do a non-atomic read-modify-write on a
// single shared UserDefaults dictionary, so tests that mutate it race under Swift
// Testing's default parallel execution.
@Suite("VocabCorrector", .serialized)
struct VocabCorrectorTests {

    @Test func correctsKnownBrandMishear() {
        #expect(VocabCorrector.apply(to: "open github and check xcode") == "open GitHub and check Xcode")
    }

    @Test func isCaseInsensitiveOnInput() {
        #expect(VocabCorrector.apply(to: "I love SWIFTUI") == "I love SwiftUI")
    }

    @Test func onlyMatchesWholeWords() {
        // "ios" must not fire inside "biosphere" or similar embedded occurrences.
        #expect(VocabCorrector.apply(to: "biosphere reserve") == "biosphere reserve")
    }

    @Test func removesFillerArtifactPairs() {
        #expect(VocabCorrector.apply(to: "so um uh let's go") == "so let's go")
    }

    @Test func leavesUnrelatedTextUnchanged() {
        let text = "The quick brown fox jumps over the lazy dog"
        #expect(VocabCorrector.apply(to: text) == text)
    }

    @Test func userCorrectionOverridesBuiltIn() {
        VocabCorrector.addCorrection(mishear: "github", correct: "GITHUB!!")
        defer { VocabCorrector.removeCorrection(for: "github") }
        #expect(VocabCorrector.apply(to: "open github") == "open GITHUB!!")
    }

    @Test func userCorrectionIsRemovable() {
        VocabCorrector.addCorrection(mishear: "testword", correct: "TestWord")
        #expect(VocabCorrector.apply(to: "a testword here") == "a TestWord here")
        VocabCorrector.removeCorrection(for: "testword")
        #expect(VocabCorrector.apply(to: "a testword here") == "a testword here")
    }
}
