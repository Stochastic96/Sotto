import Testing
@testable import SottoCore

@Suite("SmallTalk")
struct SmallTalkTests {

    // MARK: - Positive: greetings & how-are-you get an instant, non-empty reply.

    @Test func greetingsMatch() {
        for phrase in ["hi", "hey", "hello", "good morning", "hey there", "yo", "you there"] {
            #expect(SmallTalk.match(phrase) != nil, "expected a canned reply for '\(phrase)'")
        }
    }

    @Test func howAreYouMatchesEvenWithPunctuation() {
        // The exact utterance from the log that mis-routed to the 10 s quick lane.
        for phrase in ["how are you?", "How are you", "how's it going", "what's up", "you good?"] {
            let reply = SmallTalk.match(phrase)
            #expect(reply != nil, "expected a canned reply for '\(phrase)'")
            #expect(reply.map { !$0.text.isEmpty } ?? false)
        }
    }

    @Test func thanksAndIdentityAndCapabilities() {
        #expect(SmallTalk.match("thanks") != nil)
        #expect(SmallTalk.match("who are you") != nil)
        #expect(SmallTalk.match("what can you do") != nil)
        #expect(SmallTalk.match("what's your name?") != nil)
    }

    // MARK: - Positive: Siri-domain capability questions explain the delegation.

    @Test func howToReminderExplainsSiri() {
        // The other exact log utterance: "how can you make reminder?"
        let reply = SmallTalk.match("how can you make reminder?")
        #expect(reply != nil)
        #expect(reply?.text.lowercased().contains("siri") ?? false)
    }

    @Test func bareCapabilityQuestionsAboutSiriDomains() {
        for phrase in ["how do you set an alarm", "can you send messages?", "do you make reminders"] {
            let reply = SmallTalk.match(phrase)
            #expect(reply != nil, "expected a Siri-delegation explanation for '\(phrase)'")
            #expect(reply?.text.lowercased().contains("siri") ?? false)
        }
    }

    // MARK: - Positive: "how do you <own capability>" questions get an instant hint.

    @Test func selfCapabilityHowToQuestions() {
        // "how you open" is the exact ASR-garbled utterance from the log (dropped "do").
        for phrase in ["how you open", "how do you open apps", "how do you search the web",
                       "how do you control the volume", "how do you take a note"] {
            let reply = SmallTalk.match(phrase)
            #expect(reply != nil, "expected a self-capability hint for '\(phrase)'")
            // Must never leak an internal tool name.
            #expect(!(reply?.text.lowercased().contains("open_app") ?? true))
        }
    }

    // MARK: - Negative: imperatives MUST fall through (nil) so the pipeline acts on them.

    @Test func imperativesDoNotMatch() {
        let commands = [
            "make a reminder for 5pm",
            "set an alarm for 7",
            "text John I'll be late",
            "remind me to call mom at 6",
            "open xcode",
            "can you open xcode",          // polite imperative — must still launch, not explain
            "play some music",
            "what's the weather in paris",
            "search for swift concurrency",
        ]
        for cmd in commands {
            #expect(SmallTalk.match(cmd) == nil, "'\(cmd)' should fall through to the real pipeline")
        }
    }

    @Test func emptyOrWakeOnlyReturnsNil() {
        #expect(SmallTalk.match("") == nil)
        #expect(SmallTalk.match("   ") == nil)
    }
}
