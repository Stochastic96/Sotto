import Foundation

// Capability protocols for the concrete, side-effecting system helpers in the Sotto
// executable target (SystemControlHelper, NativeSystemOrchestrator, NativeClipboard,
// WindowManager, KeySimulator, SpotifyControl). Each of those is a `struct`/`enum` of
// `static` funcs, so tools that call them by type name can't be unit-tested — invoking a
// tool really changes the Mac. These protocols give every tool an injectable seam: the
// real app injects a `Live*` conformer (in the Sotto target) that forwards to the static
// helper, while tests inject a spy that records calls and returns canned values.
//
// The protocols live in SottoCore (Foundation-only, no AppKit) so the SottoTests target —
// which depends only on SottoCore — can declare fakes and exercise tool logic. All return
// types are Foundation-level, so no AppKit leaks in here.

/// Output volume, mute state, and screen brightness. Mirrors `SystemControlHelper`.
public protocol SystemControlling: Sendable {
    func getVolume() -> Float
    func setVolume(_ volume: Float) -> Bool
    func isMuted() -> Bool
    func setMuted(_ muted: Bool) -> Bool
    func getBrightness() -> Float
    func setBrightness(_ value: Float) -> Bool
}

/// System power/state actions. Mirrors `NativeSystemOrchestrator` (which is `@MainActor`,
/// hence the `async` requirements — conformers hop to the main actor internally).
public protocol SystemPowerControlling: Sendable {
    func lockScreen() async
    func emptyTrash() async
    func purgeRAM() async -> Bool
    func sleepDisplay() async
    func createNote(_ text: String) async -> Bool
}

/// Read/write the system clipboard. Mirrors `NativeClipboard`.
public protocol ClipboardAccessing: Sendable {
    func get() -> String
    func set(_ text: String)
}

/// Enumerate running apps / windows and bring an app forward. Mirrors `WindowManager`.
public protocol WindowControlling: Sendable {
    func getRunningApps() -> [String]
    func activateApp(pid: Int32) -> Bool
    func getWindowList() -> [String]
}

/// Post synthetic keystrokes. Mirrors `KeySimulator`.
public protocol KeySimulating: Sendable {
    func simulate(key: String, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) async -> Bool
}

/// Spotify-specific transport control. Mirrors the subset of `SpotifyControl` that tools
/// invoke (playback + search-and-play + the permission hint string).
public protocol SpotifyControlling: Sendable {
    var permissionHint: String { get }
    func play() async -> Bool
    func pause() async -> Bool
    func next() async -> Bool
    func previous() async -> Bool
    func searchAndPlay(_ query: String) async -> String
}
