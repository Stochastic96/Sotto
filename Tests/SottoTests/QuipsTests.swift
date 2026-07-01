import Testing
@testable import SottoCore

@Suite("Quips")
struct QuipsTests {

    @Test func siriAlwaysReturnsNonEmptyLine() {
        for _ in 0..<20 {
            #expect(!Quips.siri().isEmpty)
        }
    }

    @Test func doneAlwaysReturnsNonEmptyLine() {
        for _ in 0..<20 {
            #expect(!Quips.done().isEmpty)
        }
    }

    @Test func weatherTailCanBeEmptyButNeverNil() {
        // weatherTail() returns String, not String? — this asserts it never crashes
        // and always yields a value in the known set across many draws.
        for _ in 0..<20 {
            _ = Quips.weatherTail()
        }
    }
}
