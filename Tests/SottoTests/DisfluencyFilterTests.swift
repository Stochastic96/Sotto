import Testing
@testable import SottoCore

@Suite("DisfluencyFilter")
struct DisfluencyFilterTests {

    @Test("removes standalone fillers")
    func standaloneFillers() {
        #expect(DisfluencyFilter.strip("um I think uh we should go") == "I think we should go")
        #expect(DisfluencyFilter.strip("mm blah blah the meeting") == "the meeting")
    }

    @Test("removes a filler that is the entire input")
    func wholeInputFiller() {
        #expect(DisfluencyFilter.strip("blah") == "")
        #expect(DisfluencyFilter.strip("um uh mm") == "")
    }

    @Test("never touches fillers embedded in real words")
    func embeddedFillersPreserved() {
        #expect(DisfluencyFilter.strip("summer ahead of schedule") == "summer ahead of schedule")
        #expect(DisfluencyFilter.strip("the umbrella is hers") == "the umbrella is hers")
    }

    @Test("keeps trailing punctuation when dropping a filler")
    func punctuationPreserved() {
        #expect(DisfluencyFilter.strip("I am done uh.") == "I am done.")
        #expect(DisfluencyFilter.strip("wait um, let me check") == "wait, let me check")
    }

    @Test("restores leading capital after stripping a leading filler")
    func leadingCapitalRestored() {
        #expect(DisfluencyFilter.strip("Um the report is ready") == "The report is ready")
    }

    @Test("case-insensitive matching")
    func caseInsensitive() {
        #expect(DisfluencyFilter.strip("UH I mean HMM yes") == "I mean yes")
    }

    @Test("clean text passes through unchanged")
    func cleanPassthrough() {
        #expect(DisfluencyFilter.strip("Ship the build today.") == "Ship the build today.")
        #expect(DisfluencyFilter.strip("") == "")
    }
}
