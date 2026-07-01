import Testing
@testable import SottoCore

@Suite("SystemCommandParser")
struct SystemCommandParserTests {

    @Test func parsesExplicitSetVolume() {
        #expect(SystemCommandParser.parse("set volume to 90 percent") == .setVolume(percent: 90))
    }

    @Test func parsesExplicitSetBrightness() {
        #expect(SystemCommandParser.parse("set brightness to 60%") == .setBrightness(percent: 60))
    }

    @Test func parsesMakeVolumePhrasing() {
        #expect(SystemCommandParser.parse("make volume 30") == .setVolume(percent: 30))
    }

    @Test func clampsAboveHundred() {
        #expect(SystemCommandParser.parse("set volume to 150 percent") == .setVolume(percent: 100))
    }

    @Test func clampsBelowZeroNeverProduced() {
        // No negative numbers can be parsed by firstInteger, so this is really testing
        // that a 0 value is preserved (not treated as "no command").
        #expect(SystemCommandParser.parse("set volume to 0 percent") == .setVolume(percent: 0))
    }

    @Test func rejectsEmbeddedMentionNotStartingWithOpener() {
        // "remind me to set volume to 90 percent" does not open with a command word.
        #expect(SystemCommandParser.parse("remind me to set volume to 90 percent") == nil)
    }

    @Test func rejectsRelativePhrasingWithNoExplicitTarget() {
        #expect(SystemCommandParser.parse("turn volume up a bit") == nil)
    }

    @Test func rejectsUnrelatedCommand() {
        #expect(SystemCommandParser.parse("open safari") == nil)
    }

    @Test func volumeWinsWhenBothMentioned() {
        #expect(SystemCommandParser.parse("set volume and brightness to 50 percent") == .setVolume(percent: 50))
    }
}
