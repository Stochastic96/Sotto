import Foundation

extension CommandEngine {
    static func checkWindowShortcut(for t: String) -> ZeroLatencyShortcut? {
        switch t {
        case "maximize", "maximize window", "full screen", "full screen window", "make window full screen":
            return ZeroLatencyShortcut(
                command: "native:win_maximize",
                voiceFeedback: "मिस्टर लॉर्ड, window को फुल स्क्रीन पे चेप दिया है। दिल्ली से हूँ भाई, सीन एकदम मक्खन कर दिया।",
                hudMessage: "Window Maximized"
            )
        case "minimize", "minimize window", "hide window":
            return ZeroLatencyShortcut(
                command: "native:win_minimize",
                voiceFeedback: "window को छोटा कर दिया है मिस्टर लॉर्ड, चिल मारो।",
                hudMessage: "Window Minimized"
            )
        case "tile left", "tile window left", "left align window", "window left":
            return ZeroLatencyShortcut(
                command: "native:win_left",
                voiceFeedback: "लो मिस्टर लॉर्ड, window को left में सेट कर दिया है। भौकाल टाइलिंग!",
                hudMessage: "Window Tiled Left"
            )
        case "tile right", "tile window right", "right align window", "window right":
            return ZeroLatencyShortcut(
                command: "native:win_right",
                voiceFeedback: "Right side में window चेप दी है मिस्टर लॉर्ड, एकदम सॉलिड सीन है।",
                hudMessage: "Window Tiled Right"
            )
        case "center", "center window", "center active window":
            return ZeroLatencyShortcut(
                command: "native:win_center",
                voiceFeedback: "Window को center में सेट कर दिया है, मिस्टर लॉर्ड। तेरे भाई का जुगाड़ एकदम मक्खन है।",
                hudMessage: "Window Centered"
            )
        case "close window", "close active window":
            return ZeroLatencyShortcut(
                command: "native:win_close",
                voiceFeedback: "लो भाई, window ही साफ़ कर दी। भसड़ ख़त्म!",
                hudMessage: "Window Closed"
            )
        case "tile top", "tile window top", "top half window", "window top", "tile top half", "tile window top half":
            return ZeroLatencyShortcut(
                command: "native:win_top_half",
                voiceFeedback: "लो भाई, window को ऊपर वाले half में सेट कर दिया है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Top"
            )
        case "tile bottom", "tile window bottom", "bottom half window", "window bottom", "tile bottom half", "tile window bottom half":
            return ZeroLatencyShortcut(
                command: "native:win_bottom_half",
                voiceFeedback: "लो भाई, window को नीचे वाले half में सेट कर दिया है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Bottom"
            )
        case "tile top left", "window top left", "tile window top left":
            return ZeroLatencyShortcut(
                command: "native:win_top_left",
                voiceFeedback: "Window top-left corner में सेट कर दी है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Top-Left"
            )
        case "tile top right", "window top right", "tile window top right":
            return ZeroLatencyShortcut(
                command: "native:win_top_right",
                voiceFeedback: "Window top-right corner in set कर दी है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Top-Right"
            )
        case "tile bottom left", "window bottom left", "tile window bottom left":
            return ZeroLatencyShortcut(
                command: "native:win_bottom_left",
                voiceFeedback: "Window bottom-left corner in set कर दी है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Bottom-Left"
            )
        case "tile bottom right", "window bottom right", "tile window bottom right":
            return ZeroLatencyShortcut(
                command: "native:win_bottom_right",
                voiceFeedback: "Window bottom-right corner in set कर दी है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Bottom-Right"
            )
        case "make window small", "small window", "resize small":
            return ZeroLatencyShortcut(
                command: "native:win_small",
                voiceFeedback: "Window को छोटा और center में कर दिया है मिस्टर लॉर्ड।",
                hudMessage: "Window Resized Small"
            )
        case "make window medium", "medium window", "resize medium":
            return ZeroLatencyShortcut(
                command: "native:win_medium",
                voiceFeedback: "Window को medium size में center कर दिया है मिस्टर लॉर्ड।",
                hudMessage: "Window Resized Medium"
            )
        case "make window large", "large window", "resize large":
            return ZeroLatencyShortcut(
                command: "native:win_large",
                voiceFeedback: "Window को large size में center कर दिया है मिस्टर लॉर्ड।",
                hudMessage: "Window Resized Large"
            )
        default:
            return nil
        }
    }
}
