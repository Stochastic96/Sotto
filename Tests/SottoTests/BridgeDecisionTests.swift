import Testing
@testable import SottoCore

@Suite("BridgeDecision")
struct BridgeDecisionTests {

    // MARK: - Delegation (explicit wake opener + task)

    @Test func plainWakeOpenerDelegates() {
        #expect(BridgeDecision.classify("Jarvis open Xcode") == .delegate(command: "open Xcode"))
    }

    @Test func heyWakeOpenerDelegates() {
        #expect(BridgeDecision.classify("Hey Jarvis open Xcode") == .delegate(command: "open Xcode"))
    }

    @Test func okWakeOpenerDelegates() {
        #expect(BridgeDecision.classify("ok jarvis lock the screen") == .delegate(command: "lock the screen"))
    }

    @Test func toleratesFusedHejarvisMishear() {
        // The native model sometimes hears "Hey Jarvis" as one fused token.
        #expect(BridgeDecision.classify("Hejarvis what time is it") == .delegate(command: "what time is it"))
    }

    @Test func preservesCommandCasingAndPunctuation() {
        #expect(BridgeDecision.classify("Jarvis email Bob about the Q3 KPI") == .delegate(command: "email Bob about the Q3 KPI"))
    }

    @Test func stripsPunctuationAfterWakeWord() {
        #expect(BridgeDecision.classify("Jarvis, open Safari") == .delegate(command: "open Safari"))
    }

    // MARK: - No task (wake word alone)

    @Test func wakeWordAloneIsNoTask() {
        #expect(BridgeDecision.classify("Jarvis") == .noTask)
    }

    @Test func wakeWordWithPunctuationOnlyIsNoTask() {
        #expect(BridgeDecision.classify("Jarvis.") == .noTask)
    }

    @Test func heyWakeWordAloneIsNoTask() {
        #expect(BridgeDecision.classify("Hey Jarvis") == .noTask)
    }

    // MARK: - Near miss (wake token present, but not the opener)

    @Test func wakeTokenMidSentenceIsNearMiss() {
        #expect(BridgeDecision.classify("as I told Jarvis yesterday it works") == .nearMiss)
    }

    @Test func wakeTokenAtEndIsNearMiss() {
        #expect(BridgeDecision.classify("that reminds me of Jarvis") == .nearMiss)
    }

    // MARK: - Plain dictation (no wake token at all)

    @Test func ordinaryDictationIsNone() {
        #expect(BridgeDecision.classify("The quick brown fox jumps over the lazy dog") == .none)
    }

    @Test func openerWithoutWakeIsNone() {
        // "hey there team" opens with an opener but the next token is not the wake word.
        #expect(BridgeDecision.classify("hey there team") == .none)
    }

    @Test func emptyInputIsNone() {
        #expect(BridgeDecision.classify("") == .none)
        #expect(BridgeDecision.classify("    ") == .none)
    }

    @Test func doesNotFalseMatchWordsMerelyContainingWake() {
        // A real word that neither equals nor ends in "jarvis" must not trigger.
        #expect(BridgeDecision.classify("the javelin was thrown far") == .none)
    }

    // MARK: - command convenience accessor

    @Test func commandAccessorReturnsOnlyForDelegate() {
        #expect(BridgeDecision.classify("Jarvis open Xcode").command == "open Xcode")
        #expect(BridgeDecision.classify("Jarvis").command == nil)
        #expect(BridgeDecision.classify("hello world").command == nil)
    }
}
