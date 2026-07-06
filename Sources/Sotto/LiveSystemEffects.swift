import Foundation
import SottoCore

// Production conformers for the capability protocols declared in SottoCore. Each simply
// forwards to the existing concrete static helper, so runtime behaviour is unchanged — the
// only new thing is that tools now hold the protocol and can be handed a spy in tests.
// These are the defaults injected into every tool (see the `system`/`spotify`/etc.
// properties on the Tool structs in JarvisTools.swift and WorkspaceTools.swift).

struct LiveSystemControl: SystemControlling {
    func getVolume() -> Float { SystemControlHelper.getVolume() }
    func setVolume(_ volume: Float) -> Bool { SystemControlHelper.setVolume(volume) }
    func isMuted() -> Bool { SystemControlHelper.isMuted() }
    func setMuted(_ muted: Bool) -> Bool { SystemControlHelper.setMuted(muted) }
    func getBrightness() -> Float { SystemControlHelper.getBrightness() }
    func setBrightness(_ value: Float) -> Bool { SystemControlHelper.setBrightness(value) }
}

struct LiveSystemPower: SystemPowerControlling {
    func lockScreen() async { await NativeSystemOrchestrator.lockScreen() }
    func emptyTrash() async { await NativeSystemOrchestrator.emptyTrash() }
    func purgeRAM() async -> Bool { await NativeSystemOrchestrator.purgeRAM() }
    func sleepDisplay() async { await NativeSystemOrchestrator.sleepDisplay() }
    func createNote(_ text: String) async -> Bool { await NativeSystemOrchestrator.createNote(text) }
}

struct LiveClipboard: ClipboardAccessing {
    func get() -> String { NativeClipboard.get() }
    func set(_ text: String) { NativeClipboard.set(text) }
}

struct LiveWindowControl: WindowControlling {
    func getRunningApps() -> [String] { WindowManager.getRunningApps() }
    func activateApp(pid: Int32) -> Bool { WindowManager.activateApp(pid: pid) }
    func getWindowList() -> [String] { WindowManager.getWindowList() }
}

struct LiveKeySimulator: KeySimulating {
    func simulate(key: String, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) async -> Bool {
        await KeySimulator.simulate(key: key, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
    }
}

struct LiveSpotify: SpotifyControlling {
    var permissionHint: String { SpotifyControl.permissionHint }
    func play() async -> Bool { await SpotifyControl.play() }
    func pause() async -> Bool { await SpotifyControl.pause() }
    func next() async -> Bool { await SpotifyControl.next() }
    func previous() async -> Bool { await SpotifyControl.previous() }
    func searchAndPlay(_ query: String) async -> String { await SpotifyControl.searchAndPlay(query) }
}
