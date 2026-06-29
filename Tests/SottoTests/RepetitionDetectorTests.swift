import Testing
import SottoCore

@Suite("RepetitionDetector")
struct RepetitionDetectorTests {

    @Test func shortTextNeverLoops() {
        #expect(!hasRepetitiveLoops("Hello world"))
        #expect(!hasRepetitiveLoops(""))
    }

    @Test func variedLongTextDoesNotLoop() {
        let text = "The quick brown fox jumps over the lazy dog and then ran away into the forest never to be seen again by anyone in the village"
        #expect(!hasRepetitiveLoops(text))
    }

    @Test func tripleRepeated5gramIsDetected() {
        // Three repetitions of the same 5-gram should trigger detection
        let repeated = "one two three four five "
        let text = repeated + repeated + repeated + "something else here"
        #expect(hasRepetitiveLoops(text))
    }

    @Test func twoRepetitionsIsNotALoop() {
        // Only two repetitions should not trigger (threshold is 3)
        let repeated = "one two three four five "
        let text = repeated + repeated + "then something completely different happens now"
        #expect(!hasRepetitiveLoops(text))
    }
}
