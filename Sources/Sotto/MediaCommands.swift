import Foundation

extension CommandEngine {
    static func checkMediaShortcut(for t: String) -> ZeroLatencyShortcut? {
        switch t {
        case "play spotify", "resume spotify", "spotify play", "resume music", "play music":
            return ZeroLatencyShortcut(
                command: "native:media_play",
                voiceFeedback: "लो भाई, गाना चालू कर दिया। मचा दो भौकाल!",
                hudMessage: "Music Playing"
            )
        case "pause spotify", "pause music", "spotify pause", "stop music", "stop spotify":
            return ZeroLatencyShortcut(
                command: "native:media_pause",
                voiceFeedback: "गाना रोक दिया भाई, शांति छा गई!",
                hudMessage: "Music Paused"
            )
        case "next song", "next track", "spotify next", "skip song", "skip track":
            return ZeroLatencyShortcut(
                command: "native:media_next",
                voiceFeedback: "लो भाई, अगला गाना लगा दिया।",
                hudMessage: "Next Track"
            )
        case "previous song", "previous track", "spotify back", "spotify previous":
            return ZeroLatencyShortcut(
                command: "native:media_prev",
                voiceFeedback: "लो भाई, पिछला गाना लगा दिया।",
                hudMessage: "Previous Track"
            )
        case "volume up", "increase volume", "louder":
            return ZeroLatencyShortcut(
                command: "native:volume_up",
                voiceFeedback: "आवाज़ बढ़ा दी भाई, फुल स्पीड!",
                hudMessage: "Volume Up"
            )
        case "volume down", "decrease volume", "quieter":
            return ZeroLatencyShortcut(
                command: "native:volume_down",
                voiceFeedback: "आवाज़ कम कर दी भाई, थोड़ी शांति।",
                hudMessage: "Volume Down"
            )
        case "mute", "mute volume", "silence":
            return ZeroLatencyShortcut(
                command: "native:mute",
                voiceFeedback: "Mute मार दिया भाई।",
                hudMessage: "Volume Muted"
            )
        case "unmute", "unmute volume":
            return ZeroLatencyShortcut(
                command: "native:unmute",
                voiceFeedback: "Unmute कर दिया भाई।",
                hudMessage: "Volume Unmuted"
            )
        case "brightness up", "increase brightness", "brighter":
            return ZeroLatencyShortcut(
                command: "native:brightness_up",
                voiceFeedback: "लो भाई, screen की चमक बढ़ा दी।",
                hudMessage: "Brightness Up"
            )
        case "brightness down", "decrease brightness", "dimmer":
            return ZeroLatencyShortcut(
                command: "native:brightness_down",
                voiceFeedback: "लो भाई, screen की चमक कम कर दी।",
                hudMessage: "Brightness Down"
            )
        default:
            return nil
        }
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
