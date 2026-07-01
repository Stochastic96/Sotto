import Testing
@testable import SottoCore

@Suite("DisfluencyFilter")
struct DisfluencyFilterTests {

    @Test func stripsStandaloneFillers() {
        #expect(DisfluencyFilter.strip("um so uh I think we should go") == "so I think we should go")
    }

    @Test func leavesFillersEmbeddedInRealWordsAlone() {
        // "summer" contains "um", "ahead" contains "ah" — neither should be touched.
        #expect(DisfluencyFilter.strip("this summer we go ahead") == "this summer we go ahead")
    }

    @Test func reattachesTrailingPunctuationToPreviousWord() {
        #expect(DisfluencyFilter.strip("I think so uh.") == "I think so.")
    }

    @Test func collapsesDoubleSpacesLeftBehind() {
        #expect(DisfluencyFilter.strip("go   there") == "go there")
    }

    @Test func restoresCapitalizationWhenLeadingFillerStripped() {
        #expect(DisfluencyFilter.strip("Um this is important") == "This is important")
    }

    @Test func textWithNoFillersIsUnchanged() {
        let text = "The quick brown fox jumps over the lazy dog"
        #expect(DisfluencyFilter.strip(text) == text)
    }

    @Test func allFillersProducesEmptyResult() {
        #expect(DisfluencyFilter.strip("um uh hmm") == "")
    }
}
