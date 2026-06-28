import Foundation

extension CommandEngine {
    static func checkWindowShortcut(for t: String) -> ZeroLatencyShortcut? {
        // A recognised window-action word must be present so random sentences don't fire.
        let hasWinWord = t.contains("tile") || t.contains("window") || t.contains("snap") ||
                         t.contains("split") || t.contains("half") || t.contains("align") ||
                         t.contains("resize") || t.contains("move") || t.contains("put") ||
                         t.contains("maximize") || t.contains("minimise") || t.contains("minimize") ||
                         t.contains("full screen") || t.contains("fullscreen") ||
                         t.contains("close") || t.contains("screen")

        guard hasWinWord else { return nil }

        // ── CORNERS (check first — most specific, must not fall through to halves) ──
        if t.contains("top") && t.contains("left") {
            return ZeroLatencyShortcut(
                command: "native:win_top_left",
                voiceFeedback: "Snapped to top-left.",
                hudMessage: "Window Top-Left"
            )
        }
        if t.contains("top") && t.contains("right") {
            return ZeroLatencyShortcut(
                command: "native:win_top_right",
                voiceFeedback: "Snapped to top-right.",
                hudMessage: "Window Top-Right"
            )
        }
        if t.contains("bottom") && t.contains("left") {
            return ZeroLatencyShortcut(
                command: "native:win_bottom_left",
                voiceFeedback: "Snapped to bottom-left.",
                hudMessage: "Window Bottom-Left"
            )
        }
        if t.contains("bottom") && t.contains("right") {
            return ZeroLatencyShortcut(
                command: "native:win_bottom_right",
                voiceFeedback: "Snapped to bottom-right.",
                hudMessage: "Window Bottom-Right"
            )
        }

        // ── HALVES ──
        if t.contains("left") {
            return ZeroLatencyShortcut(
                command: "native:win_left",
                voiceFeedback: "Tiled left.",
                hudMessage: "Window Tiled Left"
            )
        }
        if t.contains("right") {
            return ZeroLatencyShortcut(
                command: "native:win_right",
                voiceFeedback: "Tiled right.",
                hudMessage: "Window Tiled Right"
            )
        }
        if t.contains("top") || t.contains("upper") {
            return ZeroLatencyShortcut(
                command: "native:win_top_half",
                voiceFeedback: "Tiled to top half.",
                hudMessage: "Window Tiled Top"
            )
        }
        if t.contains("bottom") || t.contains("lower") {
            return ZeroLatencyShortcut(
                command: "native:win_bottom_half",
                voiceFeedback: "Tiled to bottom half.",
                hudMessage: "Window Tiled Bottom"
            )
        }

        // ── MAXIMIZE / FULL SCREEN ──
        if t.contains("full screen") || t.contains("fullscreen") || t.contains("maximize") ||
           t.contains("maximise") || t.contains("full size") {
            return ZeroLatencyShortcut(
                command: "native:win_maximize",
                voiceFeedback: "Window maximized.",
                hudMessage: "Window Maximized"
            )
        }

        // ── MINIMIZE / HIDE ──
        if t.contains("minimize") || t.contains("minimise") || t.contains("hide window") ||
           t.contains("hide the window") {
            return ZeroLatencyShortcut(
                command: "native:win_minimize",
                voiceFeedback: "Window minimized.",
                hudMessage: "Window Minimized"
            )
        }

        // ── CLOSE ──
        if t.contains("close window") || t.contains("close the window") || t.contains("close this window") {
            return ZeroLatencyShortcut(
                command: "native:win_close",
                voiceFeedback: "Window closed.",
                hudMessage: "Window Closed"
            )
        }

        // ── CENTER ── (left/right already handled above)
        if t.contains("center") || t.contains("centre") {
            return ZeroLatencyShortcut(
                command: "native:win_center",
                voiceFeedback: "Window centered.",
                hudMessage: "Window Centered"
            )
        }

        // ── SIZE PRESETS ──
        if t.contains("small") {
            return ZeroLatencyShortcut(
                command: "native:win_small",
                voiceFeedback: "Window resized small.",
                hudMessage: "Window Resized Small"
            )
        }
        if t.contains("medium") {
            return ZeroLatencyShortcut(
                command: "native:win_medium",
                voiceFeedback: "Window resized medium.",
                hudMessage: "Window Resized Medium"
            )
        }
        if t.contains("large") {
            return ZeroLatencyShortcut(
                command: "native:win_large",
                voiceFeedback: "Window resized large.",
                hudMessage: "Window Resized Large"
            )
        }

        return nil
    }
}
