import Foundation

extension CommandEngine {
    static func checkMediaShortcut(for t: String) -> ZeroLatencyShortcut? {

        // ── UNMUTE (check before mute to avoid "unmute" matching "mute") ──
        if t.contains("unmute") || t == "turn sound back on" || t == "turn audio back on" {
            return ZeroLatencyShortcut(
                command: "native:unmute",
                voiceFeedback: "Unmuted.",
                hudMessage: "Volume Unmuted"
            )
        }

        // ── MUTE ──
        if t.contains("mute") || t == "silence" || t == "silence the volume" || t == "no sound" {
            return ZeroLatencyShortcut(
                command: "native:mute",
                voiceFeedback: "Muted.",
                hudMessage: "Volume Muted"
            )
        }

        // ── VOLUME UP ──
        if t.contains("volume up") || t.contains("louder") || t.contains("increase volume") ||
           t.contains("turn up") || t.contains("raise the volume") || t.contains("raise volume") ||
           t.contains("higher volume") || t == "volume higher" {
            return ZeroLatencyShortcut(
                command: "native:volume_up",
                voiceFeedback: "Volume up.",
                hudMessage: "Volume Up"
            )
        }

        // ── VOLUME DOWN ──
        if t.contains("volume down") || t.contains("quieter") || t.contains("decrease volume") ||
           t.contains("turn down") || t.contains("lower the volume") || t.contains("lower volume") ||
           t.contains("reduce volume") || t == "volume lower" {
            return ZeroLatencyShortcut(
                command: "native:volume_down",
                voiceFeedback: "Volume down.",
                hudMessage: "Volume Down"
            )
        }

        // ── BRIGHTNESS UP ──
        if t.contains("brightness up") || t.contains("brighter") || t.contains("increase brightness") ||
           t.contains("turn up brightness") || t.contains("raise brightness") || t.contains("more brightness") {
            return ZeroLatencyShortcut(
                command: "native:brightness_up",
                voiceFeedback: "Brightness up.",
                hudMessage: "Brightness Up"
            )
        }

        // ── BRIGHTNESS DOWN ──
        if t.contains("brightness down") || t.contains("dimmer") || t.contains("decrease brightness") ||
           t.contains("dim the screen") || t.contains("dim screen") || t.contains("lower brightness") ||
           t.contains("reduce brightness") || t.contains("less brightness") {
            return ZeroLatencyShortcut(
                command: "native:brightness_down",
                voiceFeedback: "Brightness down.",
                hudMessage: "Brightness Down"
            )
        }

        // ── NEXT TRACK ──
        if t.contains("next song") || t.contains("next track") || t.contains("skip song") ||
           t.contains("skip track") || t.contains("skip this") || t.contains("spotify next") ||
           t == "next" || t == "skip" || t == "forward" {
            return ZeroLatencyShortcut(
                command: "native:media_next",
                voiceFeedback: "Next track.",
                hudMessage: "Next Track"
            )
        }

        // ── PREVIOUS TRACK ──
        if t.contains("previous song") || t.contains("previous track") || t.contains("last song") ||
           t.contains("spotify back") || t.contains("go back") && t.contains("song") ||
           t == "previous" || t == "go back" && t.contains("track") {
            return ZeroLatencyShortcut(
                command: "native:media_prev",
                voiceFeedback: "Previous track.",
                hudMessage: "Previous Track"
            )
        }

        // ── PAUSE / STOP ── (media_play is a play/pause toggle)
        // Check before generic play so "pause" doesn't fall through.
        let isPause = t.contains("pause") || t == "stop music" || t == "stop the music" ||
                      t == "stop spotify" || t == "stop playback" || t == "pause playback"
        if isPause {
            return ZeroLatencyShortcut(
                command: "native:media_play",
                voiceFeedback: "Paused.",
                hudMessage: "Music Paused"
            )
        }

        // ── PLAY / RESUME (generic — no song name) ──
        // Do NOT intercept "play X on spotify" or "play [song]" — those need Jarvis/SpotifyTool.
        let isGenericPlay = t == "play" || t == "play music" || t == "play the music" ||
                            t == "play spotify" || t == "play on spotify" || t == "unpause" ||
                            t == "resume" || t == "resume music" || t == "resume spotify" ||
                            t == "resume playback" || t == "start music" || t == "start playing" ||
                            t == "continue playing" || t == "continue music"
        if isGenericPlay {
            return ZeroLatencyShortcut(
                command: "native:media_play",
                voiceFeedback: "Playing.",
                hudMessage: "Music Playing"
            )
        }

        return nil
    }

    static func processSpotifyMusic(lowerText: String, text: String) -> CommandOutput? {
        if lowerText.hasPrefix("search spotify for ") {
            var query = String(text.dropFirst(19)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Spotify search '\(query)'")
            searchSpotify(query: query)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("open spotify and search ") {
            var query = String(text.dropFirst(24)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Spotify search '\(query)'")
            searchSpotify(query: query)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("open spotify and play ") {
            var query = String(text.dropFirst(22)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Spotify play '\(query)'")
            searchSpotify(query: query)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("play ") && lowerText.hasSuffix(" on spotify") {
            var song = String(text.dropFirst(5).dropLast(11)).trimmingCharacters(in: .whitespaces)
            while song.hasSuffix(".") || song.hasSuffix(",") || song.hasSuffix("?") || song.hasSuffix("!") { song.removeLast() }
            print("[ENGINE] Command recognized: Spotify play '\(song)'")
            searchSpotify(query: song)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }
        return nil
    }
}
