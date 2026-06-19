import Foundation
import AppKit
import Vision

enum SearchShortcutType: String {
    case find // Cmd+F
    case location // Cmd+L
}

struct CommandOutput {
    var text: String
    var pressReturnAfter: Bool
    var fileURL: URL?
    var searchShortcut: SearchShortcutType? = nil
    var delayBeforeInject: Double = 0.0
    var showLocalExplanation: Bool = false
    var explanationTitle: String = ""
}

/// Multi-step browser-orchestration flows that Sotto drives deterministically
/// (no LLM tokens). The "thinking" tokens are spent later by the web AI itself.
enum OrchestratorAction: CustomStringConvertible {
    case claudeNewChat
    case prepPrompt(PromptUseCase)
    case sendLastPromptToClaude

    var description: String {
        switch self {
        case .claudeNewChat:          return "claudeNewChat"
        case .prepPrompt(let u):      return "prepPrompt(\(u.label))"
        case .sendLastPromptToClaude: return "sendLastPromptToClaude"
        }
    }
}

/// Rules-first command processing. Cheap, instant, zero RAM — the optional
/// Qwen polish pass (QwenRefiner) runs afterwards in AppController.
enum CommandEngine {
    struct ZeroLatencyShortcut {
        let command: String
        let voiceFeedback: String
        let hudMessage: String
        var showOutputInWindow: Bool = false
        var windowTitle: String = ""
    }
    
    static func checkZeroLatencyShortcut(for raw: String) -> ZeroLatencyShortcut? {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanT = t
        while cleanT.hasSuffix(".") || cleanT.hasSuffix(",") || cleanT.hasSuffix("?") || cleanT.hasSuffix("!") {
            cleanT.removeLast()
        }
        cleanT = cleanT.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch cleanT {
        // --- 1. WINDOW CONTROLS ---
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
                voiceFeedback: "Window top-right corner में सेट कर दी है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Top-Right"
            )
        case "tile bottom left", "window bottom left", "tile window bottom left":
            return ZeroLatencyShortcut(
                command: "native:win_bottom_left",
                voiceFeedback: "Window bottom-left corner में सेट कर दी है मिस्टर लॉर्ड।",
                hudMessage: "Window Tiled Bottom-Left"
            )
        case "tile bottom right", "window bottom right", "tile window bottom right":
            return ZeroLatencyShortcut(
                command: "native:win_bottom_right",
                voiceFeedback: "Window bottom-right corner में सेट कर दी है मिस्टर लॉर्ड।",
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
            
        // --- 2. BROWSER CONTROLS ---
        case "reload page", "reload tab", "refresh page", "refresh tab", "refresh", "reload":
            return ZeroLatencyShortcut(
                command: "native:browser_reload",
                voiceFeedback: "Page refresh मार दिया है मिस्टर लॉर्ड, चकाचक नया लोड हो गया।",
                hudMessage: "Page Reloaded"
            )
        case "go back", "go back page", "page back", "back tab", "browser back", "go back tab":
            return ZeroLatencyShortcut(
                command: "native:browser_back",
                voiceFeedback: "पीछे वाले page पे आ गए भाई।",
                hudMessage: "Page Back"
            )
        case "go forward", "go forward page", "page forward", "forward tab", "browser forward", "go forward tab":
            return ZeroLatencyShortcut(
                command: "native:browser_forward",
                voiceFeedback: "आगे वाले page पे आ गए मिस्टर लॉर्ड।",
                hudMessage: "Page Forward"
            )
        case "new tab", "open new tab", "create tab", "create new tab":
            return ZeroLatencyShortcut(
                command: "native:browser_new_tab",
                voiceFeedback: "नया tab खोल दिया है भाई, बकचोदी चालू करो।",
                hudMessage: "New Tab Opened"
            )
        case "close tab", "close current tab":
            return ZeroLatencyShortcut(
                command: "native:browser_close_tab",
                voiceFeedback: "Tab बंद कर दिया मिस्टर लॉर्ड, सीन क्लियर है।",
                hudMessage: "Tab Closed"
            )
        case "list tabs", "show all tabs", "what tabs are open", "get all tabs", "show tabs":
            return ZeroLatencyShortcut(
                command: "native:browser_list_tabs",
                voiceFeedback: "मिस्टर लॉर्ड, open tabs की list निकाल दी है, clipboard पे copy कर दी है।",
                hudMessage: "List of Tabs"
            )
            
        // --- 3. SYSTEM CONTROL & POWER ---
        case "sleep mac", "put mac to sleep", "sleep computer":
            return ZeroLatencyShortcut(
                command: "native:sleep",
                voiceFeedback: "Mac को सुला दिया है मिस्टर लॉर्ड, तेरे भाई ने चिल मार दिया।",
                hudMessage: "Mac Sleeping"
            )
        case "lock mac", "lock my mac", "lock screen", "lock computer":
            return ZeroLatencyShortcut(
                command: "native:lock",
                voiceFeedback: "Mac को lock कर दिया है मिस्टर लॉर्ड, सुरक्षा एकदम टाइट है।",
                hudMessage: "Mac Locked"
            )
        case "empty trash", "clean trash", "empty bin", "empty recycling bin":
            return ZeroLatencyShortcut(
                command: "native:empty_trash",
                voiceFeedback: "Trash की सारी भसड़ साफ़ कर दी है भाई, एकदम चकाचक!",
                hudMessage: "Trash Emptied"
            )
            
        // --- 4. SPOTIFY CONTROLS ---
        case "play spotify", "resume spotify", "spotify play", "resume music", "play music":
            return ZeroLatencyShortcut(
                command: "native:media_play",
                voiceFeedback: "लो भाई, गाना चालू कर दिया। मचा दो भौकाल!",
                hudMessage: "Spotify Playing"
            )
        case "pause spotify", "stop spotify", "spotify pause", "pause music", "stop music":
            return ZeroLatencyShortcut(
                command: "native:media_play",
                voiceFeedback: "गाना रोक दिया भाई।",
                hudMessage: "Spotify Paused"
            )
        case "next song", "next track", "skip song", "spotify next", "skip track":
            return ZeroLatencyShortcut(
                command: "native:media_next",
                voiceFeedback: "अगला गाना लगा दिया मिस्टर लॉर्ड, चिल मारो।",
                hudMessage: "Spotify Next Track"
            )
        case "previous song", "previous track", "back track", "spotify back", "spotify previous":
            return ZeroLatencyShortcut(
                command: "native:media_prev",
                voiceFeedback: "पीछे वाला गाना चालू कर दिया भाई।",
                hudMessage: "Spotify Previous Track"
            )
            
        // --- 5. SYSTEM VOLUME & BRIGHTNESS ---
        case "mute volume", "mute", "mute system", "silence mac":
            return ZeroLatencyShortcut(
                command: "native:mute",
                voiceFeedback: "आवाज़ बंद कर दी मिस्टर लॉर्ड, एकदम सन्नाटा!",
                hudMessage: "Volume Muted"
            )
        case "unmute volume", "unmute", "unmute system":
            return ZeroLatencyShortcut(
                command: "native:unmute",
                voiceFeedback: "लो भाई, आवाज़ वापस चालू कर दी।",
                hudMessage: "Volume Unmuted"
            )
        case "volume up", "increase volume", "louder", "make it louder":
            return ZeroLatencyShortcut(
                command: "native:volume_up",
                voiceFeedback: "आवाज़ बढ़ा दी भाई, भौकाल शुरू!",
                hudMessage: "Volume Up"
            )
        case "volume down", "decrease volume", "softer", "make it softer":
            return ZeroLatencyShortcut(
                command: "native:volume_down",
                voiceFeedback: "आवाज़ कम कर दी मिस्टर लॉर्ड।",
                hudMessage: "Volume Down"
            )
        case "brightness up", "increase brightness", "brighter", "make screen brighter":
            return ZeroLatencyShortcut(
                command: "native:brightness_up",
                voiceFeedback: "Brightness बढ़ा दी भाई, चकाचक रोशनी!",
                hudMessage: "Brightness Up"
            )
        case "brightness down", "decrease brightness", "dim screen", "make screen dimmer":
            return ZeroLatencyShortcut(
                command: "native:brightness_down",
                voiceFeedback: "Brightness कम कर दी मिस्टर लॉर्ड।",
                hudMessage: "Brightness Down"
            )
            
        // --- 6. DARK MODE & SHOW DESKTOP ---
        case "toggle dark mode", "dark mode", "toggle light mode", "appearance toggle", "toggle light dark mode":
            return ZeroLatencyShortcut(
                command: "native:dark_mode_toggle",
                voiceFeedback: "लो भाई, डार्क मोड चालू कर दिया। आँखों को चिल मारो मिस्टर लॉर्ड।",
                hudMessage: "Toggle Appearance"
            )
        case "show desktop", "hide windows", "desktop show", "reveal desktop":
            return ZeroLatencyShortcut(
                command: "native:show_desktop",
                voiceFeedback: "लो मिस्टर लॉर्ड, desktop साफ़ दिख रहा है। भसड़ गायब!",
                hudMessage: "Showing Desktop"
            )
            
        // --- 7. SYSTEM STATUS / DIAGNOSTICS ---
        case "system status", "system info", "check system status", "check system info", "mac status", "how is my mac", "status of my mac":
            return ZeroLatencyShortcut(
                command: "native:system_info",
                voiceFeedback: "", // Speak inside AppController
                hudMessage: "System Status Report",
                showOutputInWindow: true,
                windowTitle: "System Status Report"
            )
            
        // --- 8. RAM MEMORY STATUS ---
        case "ram status", "open ram", "check ram", "what is ram status", "ram info", "memory status", "check memory", "open memory", "memory info":
            return ZeroLatencyShortcut(
                command: "native:ram_info",
                voiceFeedback: "मिस्टर लॉर्ड, RAM status window खोल दी है। तेरे भाई ने सारा memory breakdown दिखा दिया है, चिल मारो।",
                hudMessage: "RAM Memory Status",
                showOutputInWindow: true,
                windowTitle: "RAM Memory Status"
            )
            
        default:
            return nil
        }
    }

    private static let sendPhrases = ["send it", "send message", "press enter", "press return"]

    /// Zero-LLM, deterministic matcher for multi-step browser flows. Returns an
    /// action only on an exact phrase match so it never hijacks normal dictation.
    /// Runs before any Qwen call, so these commands cost no tokens and no latency.
    static func orchestratorAction(for raw: String) -> OrchestratorAction? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".,!?".contains(last) { t.removeLast() }

        // 1. Prep-prompt (screen-aware co-pilot) commands — checked first because
        //    these need not mention Claude at all.
        if let prep = prepPromptAction(for: t) { return prep }

        // 2. "Send the prepared prompt to Claude" (batch step 2).
        if t.contains("send") && (t.contains("claude") || t.contains("cloud"))
            && (t.contains("prompt") || t.contains("that") || t.contains("it")) {
            return .sendLastPromptToClaude
        }

        // 3. Open Claude / start a new chat. Parakeet routinely mishears "Claude"
        //    as "cloud day" / "cloud ai" — normalize those first.
        var c = t
        for alias in ["cloud day", "cloud a i", "cloud ai", "cloud.ai",
                      "claude a i", "claude.ai", "clawed", "claw",
                      "cloudy", "claud", "clod"] {
            c = c.replacingOccurrences(of: alias, with: "claude")
        }
        // Don't hijack the one-shot "ask claude <question>" flow (handled in process()).
        if c.hasPrefix("ask claude") { return nil }
        if c.contains("claude") {
            let openIntents = ["open", "launch", "start", "go to", "goto",
                               "new chat", "initiate", "chat with", "begin", "switch to"]
            if openIntents.contains(where: { c.contains($0) }) { return .claudeNewChat }
        }
        return nil
    }

    /// Recognizes "prep / prepare / draft" style commands and maps them to a use case.
    private static func prepPromptAction(for t: String) -> OrchestratorAction? {
        let isPrep = t.hasPrefix("prep") || t.contains("prepare")
            || t.hasPrefix("draft") || t.contains("write a linkedin")
            || t.contains("help me with")
        guard isPrep else { return nil }

        if t.contains("linkedin") {
            return .prepPrompt(.linkedInPost(topic: topicAfterAbout(in: t)))
        }
        if t.contains("ad") { // "ads", "google ads", "ad help"
            return .prepPrompt(.googleAds)
        }
        if t.contains("screen") || t.contains("this") {
            return .prepPrompt(.explainScreen)
        }
        return nil
    }

    /// Extracts the topic following the word "about", if present.
    private static func topicAfterAbout(in t: String) -> String? {
        guard let range = t.range(of: " about ") else { return nil }
        let topic = t[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return topic.isEmpty ? nil : topic
    }

    /// Public wrapper exposing on-device Vision OCR of the screen under the cursor.
    static func ocrScreen() -> String { performScreenOCR() }

    static func process(_ raw: String, context: AppContext, selection: String? = nil) async -> CommandOutput {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Preprocess speech artifacts ("dot", "file name/called" etc.)
        text = preprocessSpeechArtifacts(text)

        let lowerText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // --- 0.4. Zero-Latency Direct Integrations (Wikipedia, Maps, LinkedIn, Google Ads) ---
        
        // Wikipedia/Fact Lookup
        if lowerText.hasPrefix("who is ") || lowerText.hasPrefix("what is ") || lowerText.hasPrefix("tell me about ") || lowerText.hasPrefix("research ") {
            var query = text
            if lowerText.hasPrefix("who is ") { query = String(text.dropFirst(7)) }
            else if lowerText.hasPrefix("what is ") { query = String(text.dropFirst(8)) }
            else if lowerText.hasPrefix("tell me about ") { query = String(text.dropFirst(14)) }
            else if lowerText.hasPrefix("research ") { query = String(text.dropFirst(9)) }
            
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            let cleanQuery = query.trimmingCharacters(in: .whitespaces)
            
            print("[ENGINE] Native Swift trigger: Wiki lookup for '\(cleanQuery)'")
            await JarvisSwiftExecutor.runWikiGet(query: cleanQuery)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }
        
        // Location Lookup
        if lowerText.hasPrefix("where is ") || lowerText.hasPrefix("locate ") {
            var query = text
            if lowerText.hasPrefix("where is ") { query = String(text.dropFirst(9)) }
            else if lowerText.hasPrefix("locate ") { query = String(text.dropFirst(7)) }
            
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            let cleanQuery = query.trimmingCharacters(in: .whitespaces)
            
            print("[ENGINE] Native Swift trigger: Location lookup for '\(cleanQuery)'")
            await JarvisSwiftExecutor.runLocation(placeName: cleanQuery)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }
        
        // LinkedIn Shortcuts
        if lowerText == "check my linkedin messages" || lowerText == "open linkedin messages" || lowerText == "linkedin messages" {
            print("[ENGINE] Native Swift trigger: LinkedIn Messages")
            await JarvisSwiftExecutor.runLinkedIn(subcmd: "messages")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText == "go to linkedin feed" || lowerText == "open linkedin feed" || lowerText == "linkedin feed" || lowerText == "open linkedin" {
            print("[ENGINE] Native Swift trigger: LinkedIn Feed")
            await JarvisSwiftExecutor.runLinkedIn(subcmd: "feed")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText == "go to linkedin profile" || lowerText == "open linkedin profile" || lowerText == "linkedin profile" {
            print("[ENGINE] Native Swift trigger: LinkedIn Profile")
            await JarvisSwiftExecutor.runLinkedIn(subcmd: "profile")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }
        
        // Google Ads Shortcuts
        if lowerText == "open google ads campaigns" || lowerText == "google ads campaigns" {
            print("[ENGINE] Native Swift trigger: Google Ads Campaigns")
            await JarvisSwiftExecutor.runGoogleAds(subcmd: "dashboard", arg: "campaigns")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText == "open google ads keyword planner" || lowerText == "google ads keyword planner" {
            print("[ENGINE] Native Swift trigger: Google Ads Keyword Planner")
            await JarvisSwiftExecutor.runGoogleAds(subcmd: "dashboard", arg: "keyword-planner")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText == "open google ads billing" || lowerText == "google ads billing" {
            print("[ENGINE] Native Swift trigger: Google Ads Billing")
            await JarvisSwiftExecutor.runGoogleAds(subcmd: "dashboard", arg: "billing")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText == "open google ads" || lowerText == "google ads" {
            print("[ENGINE] Native Swift trigger: Google Ads Overview")
            await JarvisSwiftExecutor.runGoogleAds(subcmd: "dashboard", arg: "overview")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }

        // Direct click triggers
        if lowerText.hasPrefix("click ") {
            let targetWord = String(text.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            print("[ENGINE] Spoken command: Click '\(targetWord)' on screen")
            let clicked = await findAndClickText(targetWord)
            return CommandOutput(
                text: clicked ? "" : "Could not find \(targetWord) on screen", 
                pressReturnAfter: false, 
                fileURL: nil
            )
        } else if lowerText.hasPrefix("sotto click ") {
            let targetWord = String(text.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines)
            print("[ENGINE] Spoken command: Sotto Click '\(targetWord)' on screen")
            let clicked = await findAndClickText(targetWord)
            return CommandOutput(
                text: clicked ? "" : "Could not find \(targetWord) on screen", 
                pressReturnAfter: false, 
                fileURL: nil
            )
        } else if lowerText == "approve" || lowerText == "approve request" || lowerText == "click approve" || lowerText == "click yes" || lowerText == "click allow" || lowerText == "click ok" {
            let words = ["approve", "allow", "yes", "ok", "y", "accept", "run", "agree"]
            var clicked = false
            for word in words {
                if await findAndClickText(word) {
                    clicked = true
                    break
                }
            }
            return CommandOutput(
                text: clicked ? "" : "Could not find approval buttons on screen", 
                pressReturnAfter: false, 
                fileURL: nil
            )
        }

        // 0.5. Selection-Aware Triggers
        if lowerText.hasPrefix("ask chatgpt about this selection") || lowerText.hasPrefix("ask chatgpt to explain this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain this selection:\n\(selectedStr)"
            openWebsite(urlStr: "https://chatgpt.com")
            return CommandOutput(text: prompt, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask claude about this selection") || lowerText.hasPrefix("ask claude to explain this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain this selection:\n\(selectedStr)"
            let response = await ClaudeQuickEntry.sendAndReadResponse(prompt)
            return CommandOutput(text: response, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("ask gemini about this selection") || lowerText.hasPrefix("ask gemini to explain this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain this selection:\n\(selectedStr)"
            openWebsite(urlStr: "https://gemini.google.com")
            return CommandOutput(text: prompt, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("explain this selection") || lowerText.hasPrefix("summarize this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain or summarize this selection in detail:\n\n\(selectedStr)"
            return CommandOutput(
                text: prompt,
                pressReturnAfter: false,
                fileURL: nil,
                showLocalExplanation: true,
                explanationTitle: "Selection Summary"
            )
        }

        // 0.6. Screen-OCR Triggers
        if lowerText.hasPrefix("ask chatgpt about this screen") {
            let screenText = performScreenOCR()
            let prompt = "Please explain/summarize this screen content:\n\(screenText)"
            openWebsite(urlStr: "https://chatgpt.com")
            return CommandOutput(text: prompt, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask claude about this screen") || lowerText.hasPrefix("explain this screen on claude") {
            let screenText = performScreenOCR()
            let prompt = "Please explain/summarize this screen content:\n\(screenText)"
            let response = await ClaudeQuickEntry.sendAndReadResponse(prompt)
            return CommandOutput(text: response, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("explain this screen") || lowerText.hasPrefix("summarize this screen") {
            let screenText = performScreenOCR()
            let prompt = "Summarize the text captured from my screen. Provide a clear, structured explanation of the key content:\n\n\(screenText)"
            return CommandOutput(
                text: prompt,
                pressReturnAfter: false,
                fileURL: nil,
                showLocalExplanation: true,
                explanationTitle: "Screen Summary"
            )
        }

        // AI Chatbot Orchestration Triggers
        if lowerText.hasPrefix("ask chatgpt ") {
            var question = String(text.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask ChatGPT '\(question)'")
            openWebsite(urlStr: "https://chatgpt.com")
            return CommandOutput(text: question, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask claude ") {
            var question = String(text.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask Claude Popover '\(question)'")
            let response = await ClaudeQuickEntry.sendAndReadResponse(question)
            return CommandOutput(text: response, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("ask gemini ") {
            var question = String(text.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask Gemini '\(question)'")
            openWebsite(urlStr: "https://gemini.google.com")
            return CommandOutput(text: question, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask perplexity ") {
            var question = String(text.dropFirst(15)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask Perplexity '\(question)'")
            openWebsite(urlStr: "https://perplexity.ai")
            return CommandOutput(text: question, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        }

        // Shell/Terminal Command Triggers
        if lowerText.hasPrefix("run terminal command ") {
            var cmd = String(text.dropFirst(21)).trimmingCharacters(in: .whitespaces)
            while cmd.hasSuffix(".") || cmd.hasSuffix(",") || cmd.hasSuffix("?") || cmd.hasSuffix("!") { cmd.removeLast() }
            let rootPath = SettingsController.workspacePath
            print("[ENGINE] Command recognized: Run terminal command '\(cmd)' under '\(rootPath)'")
            let output = runShellCommand(cmd, currentDirectory: rootPath)
            return CommandOutput(text: output, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("run command ") {
            var cmd = String(text.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            while cmd.hasSuffix(".") || cmd.hasSuffix(",") || cmd.hasSuffix("?") || cmd.hasSuffix("!") { cmd.removeLast() }
            let rootPath = SettingsController.workspacePath
            print("[ENGINE] Command recognized: Run command '\(cmd)' under '\(rootPath)'")
            let output = runShellCommand(cmd, currentDirectory: rootPath)
            return CommandOutput(text: output, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("shell command ") {
            var cmd = String(text.dropFirst(14)).trimmingCharacters(in: .whitespaces)
            while cmd.hasSuffix(".") || cmd.hasSuffix(",") || cmd.hasSuffix("?") || cmd.hasSuffix("!") { cmd.removeLast() }
            let rootPath = SettingsController.workspacePath
            print("[ENGINE] Command recognized: Run command '\(cmd)' under '\(rootPath)'")
            let output = runShellCommand(cmd, currentDirectory: rootPath)
            return CommandOutput(text: output, pressReturnAfter: false, fileURL: nil)
        }

        // 1. Chrome search triggers (checked first so "open google chrome..." doesn't fall into plain app open)
        if lowerText.hasPrefix("open chrome and search ") {
            var query = String(text.dropFirst(23)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            if query.lowercased().hasPrefix("for ") { query = String(query.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            print("[ENGINE] Command recognized: Chrome search '\(query)'")
            googleSearch(query: query, inBrowser: "Google Chrome")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("open google chrome and search ") {
            var query = String(text.dropFirst(30)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            if query.lowercased().hasPrefix("for ") { query = String(query.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            print("[ENGINE] Command recognized: Chrome search '\(query)'")
            googleSearch(query: query, inBrowser: "Google Chrome")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("chrome search ") {
            var query = String(text.dropFirst(14)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Chrome search '\(query)'")
            googleSearch(query: query, inBrowser: "Google Chrome")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("google chrome search ") {
            var query = String(text.dropFirst(21)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Chrome search '\(query)'")
            googleSearch(query: query, inBrowser: "Google Chrome")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }

        // 2. Open website or go to website triggers
        if lowerText.hasPrefix("open website ") {
            var urlStr = String(text.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            while urlStr.hasSuffix(".") || urlStr.hasSuffix(",") || urlStr.hasSuffix("?") || urlStr.hasSuffix("!") { urlStr.removeLast() }
            let lowerUrl = urlStr.lowercased().trimmingCharacters(in: .whitespaces)
            if lowerUrl == "claude" || lowerUrl == "claude ai" || lowerUrl == "claude.ai" || lowerUrl == "cloud" || lowerUrl == "cloud ai" || lowerUrl == "cloud.ai" {
                urlStr = "claude.ai"
            } else if lowerUrl == "chatgpt" || lowerUrl == "chat gpt" || lowerUrl == "chatgpt.com" {
                urlStr = "chatgpt.com"
            } else if lowerUrl == "gemini" || lowerUrl == "gemini ai" || lowerUrl == "gemini.google.com" {
                urlStr = "gemini.google.com"
            } else if lowerUrl == "perplexity" || lowerUrl == "perplexity ai" || lowerUrl == "perplexity.ai" {
                urlStr = "perplexity.ai"
            }
            print("[ENGINE] Command recognized: Open website '\(urlStr)'")
            openWebsite(urlStr: urlStr)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("go to ") {
            var urlStr = String(text.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            while urlStr.hasSuffix(".") || urlStr.hasSuffix(",") || urlStr.hasSuffix("?") || urlStr.hasSuffix("!") { urlStr.removeLast() }
            let lowerUrl = urlStr.lowercased().trimmingCharacters(in: .whitespaces)
            if lowerUrl == "claude" || lowerUrl == "claude ai" || lowerUrl == "claude.ai" || lowerUrl == "cloud" || lowerUrl == "cloud ai" || lowerUrl == "cloud.ai" {
                urlStr = "claude.ai"
            } else if lowerUrl == "chatgpt" || lowerUrl == "chat gpt" || lowerUrl == "chatgpt.com" {
                urlStr = "chatgpt.com"
            } else if lowerUrl == "gemini" || lowerUrl == "gemini ai" || lowerUrl == "gemini.google.com" {
                urlStr = "gemini.google.com"
            } else if lowerUrl == "perplexity" || lowerUrl == "perplexity ai" || lowerUrl == "perplexity.ai" {
                urlStr = "perplexity.ai"
            }
            print("[ENGINE] Command recognized: Go to website '\(urlStr)'")
            openWebsite(urlStr: urlStr)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("goto ") {
            var urlStr = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            while urlStr.hasSuffix(".") || urlStr.hasSuffix(",") || urlStr.hasSuffix("?") || urlStr.hasSuffix("!") { urlStr.removeLast() }
            let lowerUrl = urlStr.lowercased().trimmingCharacters(in: .whitespaces)
            if lowerUrl == "claude" || lowerUrl == "claude ai" || lowerUrl == "claude.ai" || lowerUrl == "cloud" || lowerUrl == "cloud ai" || lowerUrl == "cloud.ai" {
                urlStr = "claude.ai"
            } else if lowerUrl == "chatgpt" || lowerUrl == "chat gpt" || lowerUrl == "chatgpt.com" {
                urlStr = "chatgpt.com"
            } else if lowerUrl == "gemini" || lowerUrl == "gemini ai" || lowerUrl == "gemini.google.com" {
                urlStr = "gemini.google.com"
            } else if lowerUrl == "perplexity" || lowerUrl == "perplexity ai" || lowerUrl == "perplexity.ai" {
                urlStr = "perplexity.ai"
            }
            print("[ENGINE] Command recognized: Go to website '\(urlStr)'")
            openWebsite(urlStr: urlStr)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }

        // 3. Spotify search & play triggers
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

        // 3.5. Run macOS Shortcut or activate Siri triggers
        if lowerText.hasPrefix("run shortcut ") {
            let rest = String(text.dropFirst(13)).trimmingCharacters(in: .whitespaces)
            let lowerRest = rest.lowercased()

            if let withInputRange = lowerRest.range(of: " with input ") {
                let shortcutName = String(rest[..<withInputRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let input = String(rest[withInputRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                var cleanShortcutName = shortcutName
                while cleanShortcutName.hasSuffix(".") || cleanShortcutName.hasSuffix(",") || cleanShortcutName.hasSuffix("?") || cleanShortcutName.hasSuffix("!") {
                    cleanShortcutName.removeLast()
                }
                var cleanInput = input
                while cleanInput.hasSuffix(".") || cleanInput.hasSuffix(",") || cleanInput.hasSuffix("?") || cleanInput.hasSuffix("!") {
                    cleanInput.removeLast()
                }

                print("[ENGINE] Command recognized: Run shortcut '\(cleanShortcutName)' with input '\(cleanInput)'")
                runShortcut(named: cleanShortcutName, input: cleanInput)
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            } else if let withRange = lowerRest.range(of: " with ") {
                let shortcutName = String(rest[..<withRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let input = String(rest[withRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                var cleanShortcutName = shortcutName
                while cleanShortcutName.hasSuffix(".") || cleanShortcutName.hasSuffix(",") || cleanShortcutName.hasSuffix("?") || cleanShortcutName.hasSuffix("!") {
                    cleanShortcutName.removeLast()
                }
                var cleanInput = input
                while cleanInput.hasSuffix(".") || cleanInput.hasSuffix(",") || cleanInput.hasSuffix("?") || cleanInput.hasSuffix("!") {
                    cleanInput.removeLast()
                }

                print("[ENGINE] Command recognized: Run shortcut '\(cleanShortcutName)' with input '\(cleanInput)'")
                runShortcut(named: cleanShortcutName, input: cleanInput)
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            } else {
                var cleanShortcutName = rest
                while cleanShortcutName.hasSuffix(".") || cleanShortcutName.hasSuffix(",") || cleanShortcutName.hasSuffix("?") || cleanShortcutName.hasSuffix("!") {
                    cleanShortcutName.removeLast()
                }
                print("[ENGINE] Command recognized: Run shortcut '\(cleanShortcutName)'")
                runShortcut(named: cleanShortcutName)
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            }
        } else if lowerText.hasPrefix("run ") && lowerText.hasSuffix(" shortcut") {
            var shortcutName = String(text.dropFirst(4).dropLast(9)).trimmingCharacters(in: .whitespaces)
            while shortcutName.hasSuffix(".") || shortcutName.hasSuffix(",") || shortcutName.hasSuffix("?") || shortcutName.hasSuffix("!") {
                shortcutName.removeLast()
            }
            print("[ENGINE] Command recognized: Run shortcut '\(shortcutName)'")
            runShortcut(named: shortcutName)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText == "open siri" || lowerText == "open siri." || lowerText == "hey siri" || lowerText == "hey siri." || lowerText == "activate siri" || lowerText == "activate siri." || lowerText == "hey jarvis" || lowerText == "hey jarvis." || lowerText == "ask jarvis" || lowerText == "ask jarvis." || lowerText == "jarvis" || lowerText == "jarvis." {
            print("[ENGINE] Command recognized: Activate Siri (Jarvis alias)")
            launchApp(named: "Siri")
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }

        // 4. Google search / general search triggers
        if lowerText.hasPrefix("google ") {
            var query = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Google search '\(query)'")
            googleSearch(query: query)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("search ") {
            var query = String(text.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            if !lowerText.hasPrefix("search spotify for ") && !lowerText.hasPrefix("search for ") {
                print("[ENGINE] Command recognized: Search '\(query)'")
                googleSearch(query: query)
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            }
        }

        // 5. Focus & search (in-app type search)
        if lowerText.hasPrefix("type in search ") {
            var query = String(text.dropFirst(15)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Focus & search/type '\(query)'")
            return CommandOutput(text: query, pressReturnAfter: true, fileURL: nil, searchShortcut: .find)
        } else if lowerText.hasPrefix("find ") {
            var query = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            print("[ENGINE] Command recognized: Focus & search/find '\(query)'")
            return CommandOutput(text: query, pressReturnAfter: true, fileURL: nil, searchShortcut: .find)
        }

        // 6. Plain app open (checked last so specific triggers take precedence)
        if lowerText.hasPrefix("open ") {
            var appName = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            while appName.hasSuffix(".") || appName.hasSuffix(",") || appName.hasSuffix("?") || appName.hasSuffix("!") {
                appName.removeLast()
            }
            let lowerAppName = appName.lowercased().trimmingCharacters(in: .whitespaces)
            if lowerAppName == "claude" || lowerAppName == "claude ai" || lowerAppName == "claude.ai" || lowerAppName == "cloud" || lowerAppName == "cloud ai" || lowerAppName == "cloud.ai" {
                print("[ENGINE] Command recognized: Open Claude AI website")
                openWebsite(urlStr: "https://claude.ai")
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            } else if lowerAppName == "chatgpt" || lowerAppName == "chat gpt" || lowerAppName == "chatgpt.com" {
                print("[ENGINE] Command recognized: Open ChatGPT website")
                openWebsite(urlStr: "https://chatgpt.com")
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            } else if lowerAppName == "gemini" || lowerAppName == "gemini ai" || lowerAppName == "gemini.google.com" {
                print("[ENGINE] Command recognized: Open Gemini website")
                openWebsite(urlStr: "https://gemini.google.com")
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            } else if lowerAppName == "perplexity" || lowerAppName == "perplexity ai" || lowerAppName == "perplexity.ai" {
                print("[ENGINE] Command recognized: Open Perplexity website")
                openWebsite(urlStr: "https://perplexity.ai")
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            }
            print("[ENGINE] Command recognized: Open app '\(appName)'")
            launchApp(named: appName)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }

        var pressReturn = false
        var fileURL: URL? = nil

        // Check for file tagging triggers, supporting scoped folder search (e.g. "in folder Sotto find file AppController")
        var extracted = extractFolderAndFileName(from: text)
        
        // If we only extracted a folder path (like document/UCB) but no file name, split by slash to get the file name
        if let folder = extracted.folder, extracted.file == nil {
            if folder.contains("/") {
                let parts = folder.components(separatedBy: "/")
                if let lastPart = parts.last, !lastPart.isEmpty {
                    let parentParts = parts.dropLast().joined(separator: "/")
                    extracted = (parentParts.isEmpty ? nil : parentParts, lastPart)
                    print("[ENGINE] Split folder path into parent folder: '\(parentParts)' and file: '\(lastPart)'")
                }
            }
        }

        if var folderName = extracted.folder, let fileName = extracted.file {
            let rootPath = SettingsController.workspacePath
            
            // Clean up "from under" prefixes if they got picked up in the regex match
            let lowerFolder = folderName.lowercased()
            if lowerFolder.hasPrefix("from under ") {
                folderName = String(folderName.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            } else if lowerFolder.hasPrefix("under ") {
                folderName = String(folderName.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if lowerFolder.hasPrefix("from ") {
                folderName = String(folderName.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }
            
            if let folderURL = findDirectory(named: folderName, under: rootPath) {
                print("[ENGINE] Scoped search: Found folder '\(folderName)' at: \(folderURL.path)")
                if let matchedURL = findFile(named: fileName, under: folderURL.path) {
                    fileURL = matchedURL
                    print("[ENGINE] Found tagged file inside folder: \(matchedURL.path)")
                    text = stripFileCommand(from: text, fileName: fileName, folderName: folderName)
                } else {
                    print("[ENGINE] File named '\(fileName)' not found under folder '\(folderName)'")
                }
            } else {
                print("[ENGINE] Folder named '\(folderName)' not found under workspace '\(rootPath)'. Searching workspace globally...")
                if let matchedURL = findFile(named: fileName, under: rootPath) {
                    fileURL = matchedURL
                    print("[ENGINE] Found tagged file globally: \(matchedURL.path)")
                    text = stripFileCommand(from: text, fileName: fileName, folderName: folderName)
                }
            }
        } else if let fileName = extractFileName(from: text) {
            let rootPath = SettingsController.workspacePath
            if let matchedURL = findFile(named: fileName, under: rootPath) {
                fileURL = matchedURL
                print("[ENGINE] Found tagged file globally: \(matchedURL.path)")
                text = stripGlobalFileCommand(from: text, fileName: fileName)
            } else {
                print("[ENGINE] File named '\(fileName)' not found under '\(rootPath)'")
            }
        }

        // Fallback: If no file was matched but they said upload folder/directory/file, upload the workspace path itself
        if fileURL == nil {
            let lowerText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let uploadFolderPhrases = [
                "upload this folder", "upload the folder", "upload folder",
                "upload this directory", "upload the directory", "upload directory",
                "upload current folder", "upload current directory",
                "upload selected folder", "upload selected directory",
                "upload file", "upload the file", "upload a file", "upload it"
            ]
            
            if lowerText == "upload" || uploadFolderPhrases.contains(where: { lowerText.contains($0) }) {
                let rootPath = SettingsController.workspacePath
                let expandedPath = (rootPath as NSString).expandingTildeInPath
                let folderURL = URL(fileURLWithPath: expandedPath)
                if FileManager.default.fileExists(atPath: folderURL.path) {
                    fileURL = folderURL
                    print("[ENGINE] No specific file matched, falling back to uploading the workspace path itself: \(folderURL.path)")
                    
                    // Strip the upload phrase from the text so we don't paste it
                    var cleanText = text
                    for phrase in uploadFolderPhrases + ["upload"] {
                        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
                        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                            cleanText = regex.stringByReplacingMatches(in: cleanText, options: [], range: NSRange(location: 0, length: (cleanText as NSString).length), withTemplate: "")
                        }
                    }
                    text = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // Trailing "send it" / "press enter" → strip the phrase, hit Return after pasting.
        for phrase in sendPhrases {
            let pattern = "[,.!?\\s]*\(phrase)[.!?]?\\s*$"
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                text.removeSubrange(range)
                pressReturn = true
                break
            }
        }

        // Spoken structure tokens.
        text = text.replacingOccurrences(
            of: "[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*",
            with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "[,.]?\\s*\\bnew line\\b[,.]?\\s*",
            with: "\n", options: [.regularExpression, .caseInsensitive])

        // "at sign budget" → "@budget" (file/person tagging).
        text = text.replacingOccurrences(
            of: "\\bat sign\\s+", with: "@",
            options: [.regularExpression, .caseInsensitive])

        text = context.style.apply(to: text)
        text = text.trimmingCharacters(in: .whitespaces)
        return CommandOutput(text: text, pressReturnAfter: pressReturn, fileURL: fileURL)
    }

    private static func extractFileName(from text: String) -> String? {
        let patterns = [
            ("file\\s+named\\s+([a-zA-Z0-9_.-]+)", false),
            ("file\\s+([a-zA-Z0-9_.-]+\\.[a-zA-Z0-9]+)", false), // matches files with extensions like "main.swift"
            ("file\\s+([a-zA-Z0-9_.-]+)", true) // matches plain names like "index"
        ]

        let stopWords: Set<String> = [
            "is", "are", "the", "a", "an", "it", "in", "on", "at", "of", "to", "for", "with", "by",
            "this", "that", "these", "those", "my", "your", "his", "her", "their", "our", "me", "you",
            "him", "them", "us", "was", "were", "be", "been", "being", "have", "has", "had", "do",
            "does", "did", "but", "and", "or", "if", "then", "else", "than", "so", "no", "not",
            "any", "some", "all", "more", "most", "other", "such", "only", "own", "same", "too",
            "very", "can", "will", "just", "should", "would", "which", "about", "there", "here",
            "under", "from", "above", "below", "behind", "next", "over", "out", "up", "down", "through"
        ]

        for (pattern, checkStopWords) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsString = text as NSString
                let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
                if let match = results.first, match.numberOfRanges > 1 {
                    var fileName = nsString.substring(with: match.range(at: 1))

                    // Clean trailing punctuation
                    while fileName.hasSuffix(".") || fileName.hasSuffix(",") || fileName.hasSuffix("?") || fileName.hasSuffix("!") || fileName.hasSuffix(":") || fileName.hasSuffix(";") {
                        fileName.removeLast()
                    }

                    if checkStopWords {
                        let lower = fileName.lowercased()
                        if stopWords.contains(lower) {
                            continue
                        }
                    }

                    if !fileName.isEmpty {
                        return fileName
                    }
                }
            }
        }
        return nil
    }

    private static func findFile(named name: String, under rootPath: String) -> URL? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let fileManager = FileManager.default
        let expandedPath = (rootPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath)

        // 1. Check if the root directory itself matches the name (case-insensitive)
        if rootURL.lastPathComponent.lowercased() == name.lowercased() {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("[BENCHMARK] Workspace root itself matches '\(name)' in \(String(format: "%.2f", duration * 1000))ms")
            return rootURL
        }

        // 2. Otherwise search recursively
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var bestMatch: URL?
        var filesScanned = 0

        for case let fileURL as URL in enumerator {
            filesScanned += 1
            let path = fileURL.path
            // Optimization: skip large build/dependency directories to keep search instant
            if path.contains("/node_modules/") ||
               path.contains("/.git/") ||
               path.contains("/.build/") ||
               path.contains("/.xcbuild/") ||
               path.contains("/build/") ||
               path.contains("/Library/") {
                enumerator.skipDescendants()
                continue
            }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  let _ = resourceValues.isDirectory else {
                continue
            }

            let fileName = fileURL.lastPathComponent.lowercased()
            let searchName = name.lowercased()

            if fileName == searchName {
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                print("[BENCHMARK] Workspace file/folder search found exact match for '\(name)' in \(String(format: "%.2f", duration * 1000))ms (scanned \(filesScanned) items)")
                return fileURL
            }

            let nameWithoutExtension = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            if nameWithoutExtension == searchName {
                bestMatch = fileURL
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("[BENCHMARK] Workspace file/folder search finished in \(String(format: "%.2f", duration * 1000))ms (scanned \(filesScanned) items, bestMatch: \(bestMatch?.lastPathComponent ?? "none"))")
        return bestMatch
    }

    private static func preprocessSpeechArtifacts(_ input: String) -> String {
        var result = input

        // 0. Convert " slash " to "/"
        result = result.replacingOccurrences(
            of: "\\s+slash\\s+", with: "/",
            options: [.regularExpression, .caseInsensitive])

        // 1. Convert "X dot Y" to "X.Y"
        if let dotRegex = try? NSRegularExpression(pattern: "([a-zA-Z0-9_-]+)\\s+dot\\s+([a-zA-Z0-9_-]+)", options: .caseInsensitive) {
            let nsString = result as NSString
            result = dotRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: "$1.$2"
            )
        }

        // 2. Clean spaces around dots "X . Y" -> "X.Y"
        if let spaceDotRegex = try? NSRegularExpression(pattern: "([a-zA-Z0-9_-]+)\\s*\\.\\s*([a-zA-Z0-9_-]+)", options: .caseInsensitive) {
            let nsString = result as NSString
            result = spaceDotRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: "$1.$2"
            )
        }

        // 3. Normalize file triggers (e.g. "file name", "file called", "file cold" -> "file named")
        if let triggerRegex = try? NSRegularExpression(pattern: "file\\s+(?:name|called|named|code|cold|could|labeled|label|call|selected)\\s+", options: .caseInsensitive) {
            let nsString = result as NSString
            result = triggerRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: "file named "
            )
        }

        // 4. Normalize Spotify Search
        if let spotifySearchRegex = try? NSRegularExpression(pattern: "open\\s+spotify\\b(?:[\\s.,]*and)?(?:[\\s]*then)?\\s+search\\s+(?:for\\s+)?", options: .caseInsensitive) {
            let nsString = result as NSString
            result = spotifySearchRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: "open spotify and search "
            )
        }

        // 5. Normalize Spotify Play
        if let spotifyPlayRegex = try? NSRegularExpression(pattern: "open\\s+spotify\\b(?:[\\s.,]*and)?(?:[\\s]*then)?\\s+play\\s+(?:for\\s+)?", options: .caseInsensitive) {
            let nsString = result as NSString
            result = spotifyPlayRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: "open spotify and play "
            )
        }

        // 6. Normalize Chrome Search
        if let chromeSearchRegex = try? NSRegularExpression(pattern: "open\\s+(?:google\\s+)?chrome\\b(?:[\\s.,]*and)?(?:[\\s]*then)?\\s+(?:search\\s+(?:for\\s+)?|look\\s+for\\s+|find\\s+|google\\s+|check\\s+(?:the\\s+)?|query\\s+|go\\s+to\\s+)", options: .caseInsensitive) {
            let nsString = result as NSString
            result = chromeSearchRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: nsString.length),
                withTemplate: "open google chrome and search "
            )
        }

        return result
    }

    private static func launchApp(named name: String) {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var targetURL: URL? = nil
        if name.contains(".") {
            targetURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
        } else {
            let commonIDs = ["com.apple.\(name.lowercased())", "com.google.\(name)", "com.apple.Utilities.\(name)"]
            for bid in commonIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    targetURL = url
                    break
                }
            }
            if targetURL == nil {
                let paths = [
                    "/Applications/\(name).app",
                    "/System/Applications/\(name).app",
                    "/System/Applications/Utilities/\(name).app"
                ]
                for path in paths {
                    if FileManager.default.fileExists(atPath: path) {
                        targetURL = URL(fileURLWithPath: path)
                        break
                    }
                }
            }
        }
        
        if let appURL = targetURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                if let error = error {
                    print("[ENGINE] Failed to launch application natively: \(error.localizedDescription)")
                } else {
                    print("[BENCHMARK] Application '\(name)' launched natively in \(String(format: "%.2f", duration * 1000))ms")
                }
            }
        } else {
            let process = Process()
            process.launchPath = "/usr/bin/open"
            process.arguments = ["-a", name]
            try? process.run()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("[BENCHMARK] Application '\(name)' launched via /usr/bin/open fallback in \(String(format: "%.2f", duration * 1000))ms")
        }
    }

    private static func googleSearch(query: String, inBrowser browser: String? = nil) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let urlString = "https://www.google.com/search?q=\(encoded)"
        guard let url = URL(string: urlString) else { return }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        if let browserName = browser {
            // Check if it's a bundle ID
            if browserName.contains("."), let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserName) {
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = [urlString]
                NSWorkspace.shared.openApplication(at: browserURL, configuration: config) { _, error in
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    if let error = error {
                        print("[ENGINE] Failed to launch browser natively: \(error.localizedDescription)")
                    } else {
                        print("[BENCHMARK] Browser '\(browserName)' launched natively with search URL in \(String(format: "%.2f", duration * 1000))ms")
                    }
                }
                return
            }
            
            // Try resolving common browsers to their bundle identifier:
            var bundleID: String? = nil
            let lowerBrowser = browserName.lowercased()
            if lowerBrowser.contains("chrome") {
                bundleID = "com.google.Chrome"
            } else if lowerBrowser.contains("safari") {
                bundleID = "com.apple.Safari"
            } else if lowerBrowser.contains("firefox") {
                bundleID = "org.mozilla.firefox"
            } else if lowerBrowser.contains("edge") {
                bundleID = "com.microsoft.edgemac"
            }
            
            if let bID = bundleID, let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bID) {
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = [urlString]
                NSWorkspace.shared.openApplication(at: browserURL, configuration: config) { _, error in
                    let duration = CFAbsoluteTimeGetCurrent() - startTime
                    if let error = error {
                        print("[ENGINE] Failed to launch browser natively: \(error.localizedDescription)")
                    } else {
                        print("[BENCHMARK] Browser '\(browserName)' launched natively with search URL in \(String(format: "%.2f", duration * 1000))ms")
                    }
                }
                return
            }
            
            // Fallback to process opening with name
            let process = Process()
            process.launchPath = "/usr/bin/open"
            process.arguments = ["-a", browserName, urlString]
            try? process.run()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("[BENCHMARK] Browser '\(browserName)' launched via open fallback in \(String(format: "%.2f", duration * 1000))ms")
        } else {
            // Default browser open
            NSWorkspace.shared.open(url)
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("[BENCHMARK] Opened search URL in default browser in \(String(format: "%.2f", duration * 1000))ms")
        }
    }

    private static func openWebsite(urlStr: String) {
        var cleanURL = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanURL.lowercased().hasPrefix("http://") && !cleanURL.lowercased().hasPrefix("https://") {
            cleanURL = "https://" + cleanURL
        }
        if let url = URL(string: cleanURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private static func searchSpotify(query: String) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        guard let url = URL(string: "spotify:search:\(encoded)") else { return }

        let isRunning = NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == "com.spotify.client" || app.localizedName?.lowercased() == "spotify"
        }

        if isRunning {
            NSWorkspace.shared.open(url)
            print("[ENGINE] Spotify is already running. Sent search URL immediately.")
        } else {
            print("[ENGINE] Spotify is not running. Launching Spotify first...")
            if let spotifyURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                NSWorkspace.shared.openApplication(at: spotifyURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error = error {
                        print("[ENGINE] Failed to launch Spotify natively: \(error.localizedDescription)")
                        NSWorkspace.shared.open(url)
                    } else {
                        print("[ENGINE] Spotify launched natively. Waiting 2.0s for Spotify to load before sending search query...")
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2.0s delay
                            NSWorkspace.shared.open(url)
                            print("[ENGINE] Sent search URL to newly launched Spotify.")
                        }
                    }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func runShortcut(named name: String, input: String? = nil) {
        let process = Process()
        process.launchPath = "/usr/bin/shortcuts"
        process.arguments = ["run", name]

        if let input = input {
            let pipe = Pipe()
            process.standardInput = pipe
            try? process.run()
            if let data = input.data(using: .utf8) {
                try? pipe.fileHandleForWriting.write(contentsOf: data)
                try? pipe.fileHandleForWriting.close()
            }
        } else {
            try? process.run()
        }
    }

    static func runShellCommand(_ command: String, currentDirectory: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sottoDataPath = home.appendingPathComponent("Projects/Sotto/sotto-data").path
        let resolvedCommand = command.replacingOccurrences(of: "sotto-data/", with: sottoDataPath + "/")

        let startTime = CFAbsoluteTimeGetCurrent()
        let process = Process()
        process.launchPath = "/bin/bash"
        process.arguments = ["-c", resolvedCommand]

        let expandedPath = (currentDirectory as NSString).expandingTildeInPath
        process.currentDirectoryPath = expandedPath

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("[BENCHMARK] Shell command '\(command)' finished in \(String(format: "%.2f", duration * 1000))ms")
            
            if let output = String(data: data, encoding: .utf8) {
                return output.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return "Error running command: \(error.localizedDescription)"
        }
        return ""
    }

    static func runAppleScriptNative(scriptPath: String, arguments: [String]) -> String {
        let startTime = CFAbsoluteTimeGetCurrent()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sottoDataPath = home.appendingPathComponent("Projects/Sotto/sotto-data").path
        let resolvedPath = scriptPath.replacingOccurrences(of: "sotto-data/", with: sottoDataPath + "/")
        
        let url = URL(fileURLWithPath: resolvedPath)
        guard let script = NSAppleScript(contentsOf: url, error: nil) else {
            return "Failed to load AppleScript at \(url.path)"
        }
        
        var error: NSDictionary?
        let result: NSAppleEventDescriptor
        
        if arguments.isEmpty {
            result = script.executeAndReturnError(&error)
        } else {
            let parameters = NSAppleEventDescriptor.list()
            for (index, arg) in arguments.enumerated() {
                parameters.insert(NSAppleEventDescriptor(string: arg), at: index + 1)
            }
            
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(0x61736372), // 'ascr'
                eventID: AEEventID(0x70737562),     // 'psub'
                targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            
            event.setParam(NSAppleEventDescriptor(string: "run"), forKeyword: AEKeyword(0x736e616d)) // 'snam'
            event.setParam(parameters, forKeyword: AEKeyword(0x2d2d2d2d)) // '----'
            
            result = script.executeAppleEvent(event, error: &error)
        }
        
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("[BENCHMARK] AppleScript '\(scriptPath)' executed natively in-process in \(String(format: "%.2f", duration * 1000))ms")
        
        if let error = error {
            return "AppleScript Error: \(error)"
        }
        return result.stringValue ?? ""
    }

    static func runCommandNatively(_ fullCommand: String) -> String {
        let trimmed = fullCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmed.hasPrefix("osascript ") {
            let scriptPart = String(trimmed.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines)
            
            var tokens: [String] = []
            var currentToken = ""
            var insideQuotes = false
            
            for char in scriptPart {
                if char == "\"" || char == "'" {
                    insideQuotes.toggle()
                } else if char == " " && !insideQuotes {
                    if !currentToken.isEmpty {
                        tokens.append(currentToken)
                        currentToken = ""
                    }
                } else {
                    currentToken.append(char)
                }
            }
            if !currentToken.isEmpty {
                tokens.append(currentToken)
            }
            
            if let scriptPath = tokens.first {
                let args = Array(tokens.dropFirst())
                return runAppleScriptNative(scriptPath: scriptPath, arguments: args)
            }
        }
        
        let rootPath = SettingsController.workspacePath
        return runShellCommand(trimmed, currentDirectory: rootPath)
    }

    private static func performScreenOCR() -> String {
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Check screen capture permission
        if #available(macOS 10.15, *) {
            if !CGPreflightScreenCaptureAccess() {
                print("[VISION] Screen capture permission not granted. Requesting access...")
                _ = CGRequestScreenCaptureAccess()
                return "Screen capture permission not granted. Please enable Screen Recording for Sotto in System Settings -> Privacy & Security."
            }
        }
        
        // Native cursor-aware screen selection: Capture the display containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        var targetDisplayID = CGMainDisplayID()
        
        for screen in screens {
            if NSPointInRect(mouseLocation, screen.frame) {
                if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    targetDisplayID = displayID
                    break
                }
            }
        }
        
        guard let cgImage = CGDisplayCreateImage(targetDisplayID) else {
            print("[VISION] Failed to capture screen image for display \(targetDisplayID)")
            return "Failed to capture screen image"
        }

        var recognizedText = ""
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { (request, error) in
            defer { semaphore.signal() }
            guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                return
            }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            recognizedText = lines.joined(separator: "\n")
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("[VISION] Failed to perform text recognition: \(error)")
            return "Failed to analyze screen"
        }

        _ = semaphore.wait(timeout: .now() + 2.0)
        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("[BENCHMARK] Screen OCR completed in \(String(format: "%.2f", duration * 1000))ms (display: \(targetDisplayID))")
        return recognizedText
    }

    @discardableResult
    static func findAndClickText(_ target: String) async -> Bool {
        if #available(macOS 10.15, *) {
            if !CGPreflightScreenCaptureAccess() {
                print("[VISION] Screen capture permission not granted.")
                _ = CGRequestScreenCaptureAccess()
                return false
            }
        }
        
        let mouseLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        var targetDisplayID = CGMainDisplayID()
        
        for screen in screens {
            if NSPointInRect(mouseLocation, screen.frame) {
                if let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                    targetDisplayID = displayID
                    break
                }
            }
        }
        
        guard let cgImage = CGDisplayCreateImage(targetDisplayID) else {
            print("[VISION] Failed to capture screen image")
            return false
        }
        
        let screenWidth = CGFloat(cgImage.width)
        let screenHeight = CGFloat(cgImage.height)
        
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { (request, error) in
                    guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                        continuation.resume(returning: false)
                        return
                    }
                    
                    var bestObservation: VNRecognizedTextObservation? = nil
                    var exactMatchFound = false
                    
                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let candidateString = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        
                        if candidateString.caseInsensitiveCompare(target) == .orderedSame {
                            bestObservation = observation
                            exactMatchFound = true
                            break
                        } else if !exactMatchFound, candidateString.lowercased().contains(target.lowercased()) {
                            bestObservation = observation
                        }
                    }
                    
                    if let observation = bestObservation {
                        let box = observation.boundingBox
                        let midX = box.midX
                        let midY = box.midY
                        
                        let clickX = screenWidth * midX
                        let clickY = screenHeight * (1.0 - midY)
                        
                        let displayBounds = CGDisplayBounds(targetDisplayID)
                        let absolutePoint = CGPoint(x: displayBounds.origin.x + clickX, y: displayBounds.origin.y + clickY)
                        
                        print("[VISION] Found target '\(target)' (exact: \(exactMatchFound)) at display relative (\(clickX), \(clickY)), absolute \(absolutePoint)")
                        
                        DispatchQueue.main.async {
                            let source = CGEventSource(stateID: .combinedSessionState)
                            guard let mouseMove = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: absolutePoint, mouseButton: .left),
                                  let mouseDown = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: absolutePoint, mouseButton: .left),
                                  let mouseUp = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: absolutePoint, mouseButton: .left) else {
                                return
                            }
                            
                            mouseMove.post(tap: .cghidEventTap)
                            usleep(100_000)
                            mouseDown.post(tap: .cghidEventTap)
                            usleep(100_000)
                            mouseUp.post(tap: .cghidEventTap)
                            print("[VISION] Click event posted successfully to \(absolutePoint)")
                        }
                        continuation.resume(returning: true)
                    } else {
                        print("[VISION] Target '\(target)' not found on screen.")
                        continuation.resume(returning: false)
                    }
                }
                
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    print("[VISION] Failed to perform text recognition: \(error)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private static func extractFolderAndFileName(from text: String) -> (folder: String?, file: String?) {
        let patterns = [
            // "upload file [file] under/from/in [folder]"
            (#"\bupload\s+(?:a|the)?\s*file\s+(?:named\s+)?([a-zA-Z0-9_.-]+)\s+(?:under|from\s+under|in|from|inside)\s+(?:folder\s+)?([a-zA-Z0-9_ ./-]{1,50})"#, false),
            // "in/under folder [folder] find/search file [file]"
            (#"\b(?:in|under)\s+folder\s+([a-zA-Z0-9_ .-]{1,30})\s+(?:find|search\s+for)\s+file\s+(?:named\s+)?([a-zA-Z0-9_.-]+)"#, true),
            // "find/search file [file] in/under folder [folder]"
            (#"\b(?:find|search\s+for)\s+file\s+(?:named\s+)?([a-zA-Z0-9_.-]+)\s+(?:in|under)\s+folder\s+([a-zA-Z0-9_ .-]{1,30})"#, false),
            // "in/under [folder] find/search file [file]" (shorthand without the word "folder")
            (#"\b(?:in|under)\s+([a-zA-Z0-9_ .-]{1,30})\s+(?:find|search\s+for)\s+file\s+(?:named\s+)?([a-zA-Z0-9_.-]+)"#, true)
        ]
        
        for (pattern, folderFirst) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsString = text as NSString
                let results = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
                if let match = results.first, match.numberOfRanges > 2 {
                    let val1 = nsString.substring(with: match.range(at: 1))
                    let val2 = nsString.substring(with: match.range(at: 2))
                    
                    let folder = cleanPunctuation(folderFirst ? val1 : val2)
                    let file = cleanPunctuation(folderFirst ? val2 : val1)
                    
                    return (folder, file)
                }
            }
        }

        // Fallback parser for conversational or unstructured speech (e.g. "upload a file under ... you will see a file ...")
        let lowerText = text.lowercased()
        if lowerText.contains("upload") || lowerText.contains("file") {
            let stopWords: Set<String> = [
                "is", "are", "the", "a", "an", "it", "in", "on", "at", "of", "to", "for", "with", "by",
                "this", "that", "these", "those", "my", "your", "his", "her", "their", "our", "me", "you",
                "him", "them", "us", "was", "were", "be", "been", "being", "have", "has", "had", "do",
                "does", "did", "but", "and", "or", "if", "then", "else", "than", "so", "no", "not",
                "any", "some", "all", "more", "most", "other", "such", "only", "own", "same", "too",
                "very", "can", "will", "just", "should", "would", "which", "about", "there", "here",
                "under", "from", "above", "below", "behind", "next", "over", "out", "up", "down", "through"
            ]
            
            var folder: String? = nil
            // Find folder hint: look for text following "under", "in", "from", "inside"
            let folderPatterns = [
                #"\b(?:under|in|from|inside)\s+folder\s+([a-zA-Z0-9_ ./-]{1,40})"#,
                #"\b(?:under|in|from|inside)\s+([a-zA-Z0-9_ ./-]{1,40})"#
            ]
            for pattern in folderPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) {
                    let folderMatch = (text as NSString).substring(with: match.range(at: 1))
                    let clean = cleanPunctuation(folderMatch)
                    if !stopWords.contains(clean.lowercased()) {
                        folder = clean
                        break
                    }
                }
            }
            
            var file: String? = nil
            // Find file hint: look for text following "file named", "file", or "uploaded"
            let filePatterns = [
                #"\bfile\s+named\s+([a-zA-Z0-9_.-]+)"#,
                #"\bfile\s+([a-zA-Z0-9_.-]+\.[a-zA-Z0-9]+)"#,
                #"\bfile\s+([a-zA-Z0-9_.-]+)"#,
                #"\buploaded\s+([a-zA-Z0-9_.-]+)"#
            ]
            for pattern in filePatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                   let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) {
                    let fileMatch = (text as NSString).substring(with: match.range(at: 1))
                    let clean = cleanPunctuation(fileMatch)
                    if !stopWords.contains(clean.lowercased()) {
                        file = clean
                        break
                    }
                }
            }
            
            if folder != nil || file != nil {
                return (folder, file)
            }
        }
        
        return (nil, nil)
    }

    private static func findDirectory(named name: String, under rootPath: String) -> URL? {
        let fileManager = FileManager.default
        let expandedPath = (rootPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath)
        
        // Check if the root directory itself matches the query (e.g. root is Documents and we query 'document')
        if isDirectoryMatch(relativeDir: rootURL.lastPathComponent, searchQuery: name) {
            print("[ENGINE] Workspace root directory itself matches folder query '\(name)': \(rootURL.path)")
            return rootURL
        }
        
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        
        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            if path.contains("/node_modules/") || path.contains("/.git/") || path.contains("/.build/") || path.contains("/build/") {
                enumerator.skipDescendants()
                continue
            }
            
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDir = resourceValues.isDirectory, isDir else {
                continue
            }
            
            let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            
            if isDirectoryMatch(relativeDir: relativePath, searchQuery: name) {
                return fileURL
            }
        }
        return nil
    }

    private static func isDirectoryMatch(relativeDir: String, searchQuery: String) -> Bool {
        let normRelative = normalizeName(relativeDir)
        let normSearch = normalizeName(searchQuery)
        
        if normRelative == normSearch { return true }
        if normRelative.contains(normSearch) || normSearch.contains(normRelative) { return true }
        
        let searchWords = searchQuery.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            
        let relativeWords = relativeDir.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && $0 != "folder" && $0 != "directory" }
            
        guard !relativeWords.isEmpty else { return false }
        
        // Match if all path components of the relative directory exist inside the search query
        return relativeWords.allSatisfy { word in
            searchWords.contains(word)
        }
    }

    private static func normalizeName(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "and", with: "")
            .replacingOccurrences(of: "folder", with: "")
            .replacingOccurrences(of: "directory", with: "")
    }

    private static func cleanPunctuation(_ input: String) -> String {
        var str = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while str.hasSuffix(".") || str.hasSuffix(",") || str.hasSuffix("?") || str.hasSuffix("!") || str.hasSuffix(":") || str.hasSuffix(";") {
            str.removeLast()
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripFileCommand(from input: String, fileName: String, folderName: String) -> String {
        let escapedFile = NSRegularExpression.escapedPattern(for: fileName)
        let escapedFolder = NSRegularExpression.escapedPattern(for: folderName)
        
        var result = input
        
        let patterns = [
            "\\bupload\\s+(?:a|the)?\\s*file\\s+(?:named\\s+)?\(escapedFile)\\s+(?:under|from\\s+under|in|from|inside)\\s+(?:folder\\s+)?\(escapedFolder)",
            "\\b(?:in|under)\\s+folder\\s+\(escapedFolder)\\s+(?:find|search\\s+for)\\s+file\\s+(?:named\\s+)?\(escapedFile)",
            "\\b(?:find|search\\s+for)\\s+file\\s+(?:named\\s+)?\(escapedFile)\\s+(?:in|under)\\s+folder\\s+\(escapedFolder)",
            "\\b(?:in|under)\\s+\(escapedFolder)\\s+(?:find|search\\s+for)\\s+file\\s+(?:named\\s+)?\(escapedFile)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsString = result as NSString
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: nsString.length), withTemplate: "")
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripGlobalFileCommand(from input: String, fileName: String) -> String {
        let escapedFile = NSRegularExpression.escapedPattern(for: fileName)
        var result = input
        
        let patterns = [
            "\\bfile\\s+named\\s+\(escapedFile)",
            "\\bfile\\s+\(escapedFile)"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let nsString = result as NSString
                result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: nsString.length), withTemplate: "")
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
