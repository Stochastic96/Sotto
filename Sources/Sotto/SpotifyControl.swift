import AppKit
import Foundation

/// Native, Spotify-SPECIFIC control.
///
/// Global media keys (`MediaControl` NX keys) are routed by macOS to whichever player
/// it considers active — which is exactly why "play on Spotify" could also start Apple
/// Music and the reply lied about what happened. Every command here is addressed to
/// Spotify *by name* via AppleScript, so it only ever affects Spotify.
///
/// "Play a specific song" needs a `spotify:track:…` URI, and Spotify's scripting can't
/// search the catalog. So when Spotify Web API credentials are configured (Client
/// Credentials flow — no user login), we look up the best-matching track URI over the
/// network and hand it back to AppleScript to play locally. Without credentials we fall
/// back to opening Spotify's in-app search (which can't auto-play).
enum SpotifyControl {
    static let bundleID = "com.spotify.client"

    // MARK: - Presence

    static func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Launch Spotify if needed and wait briefly until it's registered and scriptable.
    @discardableResult
    static func ensureRunning() async -> Bool {
        if isRunning() { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<12 {                       // up to ~3s
            try? await Task.sleep(for: .milliseconds(250))
            if isRunning() { return true }
        }
        return isRunning()
    }

    // MARK: - AppleScript transport (always addressed to Spotify)

    /// Shown when macOS blocks Apple Events (error -1743) — so the tool reports the truth
    /// instead of the model claiming a success that never happened.
    static let permissionHint = "macOS is blocking Sotto from controlling Spotify. Enable it under System Settings ▸ Privacy & Security ▸ Automation ▸ Sotto ▸ Spotify, then try again."

    /// Runs `tell application "Spotify" to <command>` on the main thread (Apple Events are
    /// delivered most reliably via the main run loop). Returns true only when it actually
    /// succeeded — a failed/blocked command returns false so callers never fake success.
    @MainActor
    @discardableResult
    static func tell(_ command: String) -> Bool {
        guard let script = NSAppleScript(source: "tell application \"Spotify\" to \(command)") else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            print("[SPOTIFY] '\(command)' failed: \(error)")
            return false
        }
        return true
    }

    /// Reads a string property from Spotify (e.g. current track), or nil on error.
    @MainActor
    static func query(_ command: String) -> String? {
        guard let script = NSAppleScript(source: "tell application \"Spotify\" to \(command)") else { return nil }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        return error == nil ? out.stringValue : nil
    }

    @MainActor @discardableResult static func play()      -> Bool { tell("play") }
    @MainActor @discardableResult static func pause()     -> Bool { tell("pause") }
    @MainActor @discardableResult static func playPause() -> Bool { tell("playpause") }
    @MainActor @discardableResult static func next()      -> Bool { tell("next track") }
    @MainActor @discardableResult static func previous()  -> Bool { tell("previous track") }
    @MainActor @discardableResult static func playTrack(uri: String) -> Bool { tell("play track \"\(uri)\"") }

    /// "Song — Artist" for the currently playing track, or nil if nothing is playing.
    @MainActor static func currentTrack() -> String? {
        guard let name = query("name of current track"),
              let artist = query("artist of current track"),
              !name.isEmpty else { return nil }
        return artist.isEmpty ? name : "\(name) — \(artist)"
    }

    // MARK: - Catalog search (Spotify Web API, Client Credentials — optional)

    static var clientID: String { UserDefaults.standard.string(forKey: "sotto_spotify_client_id") ?? "" }
    static var clientSecret: String { UserDefaults.standard.string(forKey: "sotto_spotify_client_secret") ?? "" }
    static var hasAPICredentials: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    /// Best-matching track for `query`, or nil if no credentials / no match.
    static func searchTrackURI(_ query: String) async -> (uri: String, label: String)? {
        guard hasAPICredentials, let token = await fetchToken() else { return nil }
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.spotify.com/v1/search?q=\(q)&type=track&limit=1") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let data = try? await ResilientNetworkClient.fetchData(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tracks = json["tracks"] as? [String: Any],
              let items = tracks["items"] as? [[String: Any]],
              let first = items.first,
              let uri = first["uri"] as? String else { return nil }
        let name = first["name"] as? String ?? query
        let artist = (first["artists"] as? [[String: Any]])?.first?["name"] as? String ?? ""
        return (uri, artist.isEmpty ? name : "\(name) — \(artist)")
    }

    private static func fetchToken() async -> String? {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let basic = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        guard let data = try? await ResilientNetworkClient.fetchData(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { return nil }
        return token
    }

    /// Open Spotify, find the song, and play it. Falls back to in-app search (no auto-play)
    /// when no API credentials are configured.
    static func searchAndPlay(_ query: String) async -> String {
        guard isInstalled() else { return "Spotify isn't installed." }
        guard await ensureRunning() else { return "Couldn't launch Spotify." }

        if let found = await searchTrackURI(query) {
            let ok = await playTrack(uri: found.uri)
            return ok ? "Playing \(found.label) on Spotify." : "Found \(found.label), but \(permissionHint)"
        }

        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let u = URL(string: "spotify:search:\(q)") {
            await MainActor.run { _ = NSWorkspace.shared.open(u) }
        }
        return hasAPICredentials
            ? "Couldn't find \(query) on Spotify; opened its search instead."
            : "Opened Spotify search for \(query). Add a Spotify API key in settings to auto-play songs."
    }
}
