import Testing
@testable import SottoCore

@Suite struct SystemCommandParserTests {

    @Test func parsesSetVolumeToPercent() {
        #expect(SystemCommandParser.parse("set volume to 90 percent") == .setVolume(percent: 90))
        #expect(SystemCommandParser.parse("make volume 50%") == .setVolume(percent: 50))
        #expect(SystemCommandParser.parse("set the volume to 0") == .setVolume(percent: 0))
    }

    @Test func parsesSetBrightnessToPercent() {
        #expect(SystemCommandParser.parse("set brightness to 60%") == .setBrightness(percent: 60))
        #expect(SystemCommandParser.parse("brightness to 100 percent") == .setBrightness(percent: 100))
    }

    @Test func clampsOutOfRange() {
        #expect(SystemCommandParser.parse("set volume to 150 percent") == .setVolume(percent: 100))
    }

    @Test func relativeCommandsAreNotParsed() {
        // No explicit number/target → leave to up/down shortcuts and the model.
        #expect(SystemCommandParser.parse("volume up") == nil)
        #expect(SystemCommandParser.parse("make it louder") == nil)
        #expect(SystemCommandParser.parse("dim the screen a little") == nil)
    }

    @Test func nonSystemCommandsReturnNil() {
        #expect(SystemCommandParser.parse("open xcode") == nil)
        #expect(SystemCommandParser.parse("what's the weather") == nil)
    }

    @Test func embeddedMentionsDoNotFire() {
        // A reflex must only fire on a direct command, not an embedded clause.
        #expect(SystemCommandParser.parse("remind me to set volume to 90 percent") == nil)
        #expect(SystemCommandParser.parse("write a note about brightness at 50%") == nil)
    }

    @Test func requiresASetCueNotJustANumber() {
        // "volume 90" has a number + a set-ish bareword? We require a cue; bare "volume 90"
        // has neither set/make/to/at nor percent, so it should not fire.
        #expect(SystemCommandParser.parse("volume 90") == nil)
        // But with a percent sign it's unambiguous.
        #expect(SystemCommandParser.parse("volume 90%") == .setVolume(percent: 90))
    }
}
