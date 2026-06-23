import Testing
@testable import SottoCore

@Suite struct QuipsTests {

    @Test func siriReturnsNonEmptyString() {
        for _ in 0..<20 {
            #expect(!Quips.siri().isEmpty)
        }
    }

    @Test func doneReturnsNonEmptyString() {
        for _ in 0..<20 {
            #expect(!Quips.done().isEmpty)
        }
    }

    @Test func weatherTailReturnsString() {
        // The contract allows an empty string fallback, so just verify no crash
        for _ in 0..<20 {
            _ = Quips.weatherTail()
        }
    }

    @Test func siriEventuallyVaries() {
        // With 5 lines and 50 samples, P(all identical) = (1/5)^49 ≈ 0
        let samples = (0..<50).map { _ in Quips.siri() }
        #expect(Set(samples).count > 1)
    }

    @Test func doneEventuallyVaries() {
        let samples = (0..<50).map { _ in Quips.done() }
        #expect(Set(samples).count > 1)
    }
}
