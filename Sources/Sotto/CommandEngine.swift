import Foundation
import AppKit
import Vision
import os
import SottoCore
import ScreenCaptureKit

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

/// Rules-first command processing. Cheap, instant, zero RAM.
enum CommandEngine {
    struct ZeroLatencyShortcut {
        let command: String
        let voiceFeedback: String
        let hudMessage: String
        var showOutputInWindow: Bool = false
        var windowTitle: String = ""
    }
    
    // The dictionary IS the lock state — no separate lock variable needed.
    private static let skillTriggers = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func registerSkillTrigger(_ trigger: String, skillName: String) {
        var clean = trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasSuffix(".") || clean.hasSuffix(",") || clean.hasSuffix("?") || clean.hasSuffix("!") {
            clean.removeLast()
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        skillTriggers.withLock { [clean] in $0[clean] = skillName }
        print("[ENGINE] Registered skill trigger: '\(clean)' -> skill: '\(skillName)'")
    }

    static func registerAllEnabledSkills() {
        let enabledSkills = SkillStore.listAll().filter { $0.enabled }
        for skill in enabledSkills {
            registerSkillTrigger(skill.trigger, skillName: skill.name)
        }
    }

    static func checkZeroLatencyShortcut(for raw: String) -> ZeroLatencyShortcut? {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanT = t
        while cleanT.hasSuffix(".") || cleanT.hasSuffix(",") || cleanT.hasSuffix("?") || cleanT.hasSuffix("!") {
            cleanT.removeLast()
        }
        cleanT = cleanT.trimmingCharacters(in: .whitespacesAndNewlines)

        // Check for registered custom skill triggers
        let matchedSkill = skillTriggers.withLock { [cleanT] in $0[cleanT] }

        if let skillName = matchedSkill {
            return ZeroLatencyShortcut(
                command: "skill:\(skillName)",
                voiceFeedback: "Running skill \(skillName).",
                hudMessage: "Run Skill: \(skillName)"
            )
        }

        // Siri triggers (bypasses agent pipelines for instant zero-latency delegation)
        if ["open siri", "launch siri", "start siri", "activate siri", "ask siri", "tell siri", "siri"].contains(cleanT) {
            return ZeroLatencyShortcut(
                command: "native:open_siri",
                voiceFeedback: "Siri opening.",
                hudMessage: "Open Siri"
            )
        }

        for prefix in ["ask siri to ", "ask siri ", "tell siri to ", "tell siri ", "siri, ", "siri "] {
            if cleanT.hasPrefix(prefix) {
                let query = String(raw.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
                if !query.isEmpty {
                    return ZeroLatencyShortcut(
                        command: "native:ask_siri:\(query)",
                        voiceFeedback: "Delegating query to Siri.",
                        hudMessage: "Siri: \(query)"
                    )
                }
            }
        }

        if isSiriNativeCommand(cleanT) {
            if cleanT.contains("weather") || cleanT.contains("temperature") || cleanT.contains("forecast") {
                Task {
                    await CooperativeWorkflowManager.shared.setPending(.weatherGoOutside)
                    // Wait until Siri window is dismissed / loses focus instead of assuming timings
                    await SiriBridge.waitForSiriDismiss()
                    await MainActor.run {
                        AppController.shared?.hud.show("🌤️ Going outside?")
                        AppController.shared?.speak("Are you planning to go outside?")
                    }
                }
            }

            return ZeroLatencyShortcut(
                command: "native:ask_siri:\(raw)",
                voiceFeedback: "Delegating query to Siri.",
                hudMessage: "Siri: \(raw)"
            )
        }

        // Parametric reflex: "set volume to 90 percent" / "brightness to 60%"
        if let cmd = SystemCommandParser.parse(cleanT) {
            switch cmd {
            case .setVolume(let pct):
                return ZeroLatencyShortcut(
                    command: "native:set_volume:\(pct)",
                    voiceFeedback: "Volume set to \(pct)%.",
                    hudMessage: "Volume \(pct)%")
            case .setBrightness(let pct):
                return ZeroLatencyShortcut(
                    command: "native:set_brightness:\(pct)",
                    voiceFeedback: "Brightness set to \(pct)%.",
                    hudMessage: "Brightness \(pct)%")
            }
        }

        // Delegate to registered CommandMatcher chain (WindowMatcher → BrowserMatcher → MediaMatcher)
        if let shortcut = shortcutMatchers.lazy.compactMap({ $0.match(cleanT) }).first { return shortcut }

        // ── SYSTEM CONTROLS (keyword-based so transcription variants are accepted) ──
        if cleanT.contains("sleep") && (cleanT.contains("mac") || cleanT.contains("computer") ||
           cleanT.contains("machine") || cleanT.contains("laptop") || cleanT == "sleep") {
            return ZeroLatencyShortcut(
                command: "native:sleep",
                voiceFeedback: "Going to sleep.",
                hudMessage: "Mac Sleeping"
            )
        }
        if cleanT.contains("lock") && (cleanT.contains("mac") || cleanT.contains("screen") ||
           cleanT.contains("computer") || cleanT.contains("device") || cleanT.contains("laptop")) {
            return ZeroLatencyShortcut(
                command: "native:lock",
                voiceFeedback: "Screen locked.",
                hudMessage: "Mac Locked"
            )
        }
        if cleanT.contains("empty trash") || cleanT.contains("empty the trash") ||
           cleanT.contains("clean trash") || cleanT.contains("empty bin") ||
           cleanT.contains("empty recycling") || cleanT.contains("clear trash") {
            return ZeroLatencyShortcut(
                command: "native:empty_trash",
                voiceFeedback: "Trash emptied.",
                hudMessage: "Trash Emptied"
            )
        }

        // ── SYSTEM DIAGNOSTIC SHORTCUTS ──
        if cleanT == "system status" || cleanT == "system report" || cleanT == "battery and wifi" || cleanT == "device status" || cleanT == "system info" {
            return ZeroLatencyShortcut(
                command: "native:system_status",
                voiceFeedback: "", // spoken dynamically by the action
                hudMessage: "System Status",
                showOutputInWindow: true,
                windowTitle: "System Status"
            )
        }
        if cleanT == "ram status" || cleanT == "ram usage" || cleanT == "memory usage" || cleanT == "check ram" || cleanT == "ram info" {
            return ZeroLatencyShortcut(
                command: "native:ram_status",
                voiceFeedback: "", // spoken dynamically by the action
                hudMessage: "RAM Status",
                showOutputInWindow: true,
                windowTitle: "RAM Status"
            )
        }

        return nil
    }

    static func orchestratorAction(for raw: String) -> OrchestratorAction? {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "open claude" || t == "open claude popover" || t == "claude popover" || t == "claude" || t == "ask claude" {
            return .claudeNewChat
        }
        if t == "send to claude" || t == "send prompt" || t == "send this to claude" {
            return .sendLastPromptToClaude
        }
        return prepPromptAction(for: t)
    }

    private static func prepPromptAction(for t: String) -> OrchestratorAction? {
        if t.hasPrefix("prep linkedin post") || t.hasPrefix("prep post") {
            let topic = topicAfterAbout(in: t)
            return .prepPrompt(.linkedInPost(topic: topic))
        }
        if t.hasPrefix("prep google ad") || t.hasPrefix("prep copy") {
            return .prepPrompt(.googleAds)
        }
        if t.hasPrefix("prep screen summary") || t.hasPrefix("explain screen") || t.hasPrefix("prep screen") {
            return .prepPrompt(.explainScreen)
        }
        if t.hasPrefix("prep custom prompt") || t.hasPrefix("prep prompt") {
            return .prepPrompt(.custom(instruction: ""))
        }
        return nil
    }

    private static func topicAfterAbout(in t: String) -> String? {
        if let r = t.range(of: " about ") {
            let topic = String(t[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return topic.isEmpty ? nil : topic
        }
        return nil
    }

    static func ocrScreen() async -> String { await performScreenOCR() }

    /// Last non-empty text result from any pipeline run — exposed so "copy that" can put
    /// it on the clipboard without needing access to HUDOverlay.
    nonisolated(unsafe) static var lastResult: String = ""

    static func process(_ raw: String, context: AppContext, selection: String? = nil) async -> CommandOutput {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Apply vocabulary corrections before any other processing.
        text = VocabCorrector.apply(to: text)

        // Preprocess speech artifacts ("dot", "file name/called" etc.)
        text = preprocessSpeechArtifacts(text)

        let lowerText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // --- "Remember that X" / "note that X" → save to personal memory directly ---
        let rememberPrefixes = ["remember that ", "remember this: ", "remember, ", "note that ", "note this: ", "save this: "]
        for prefix in rememberPrefixes where lowerText.hasPrefix(prefix) {
            let fact = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !fact.isEmpty {
                let key = "note_\(Int(Date().timeIntervalSince1970))"
                UserProfile.remember(key: key, fact: fact)
                print("[ENGINE] Memory saved: \(fact)")
                return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
            }
        }

        // --- "Copy that" → copy last result to clipboard ---
        let copyThatPhrases = ["copy that", "copy the result", "copy last result", "copy that result"]
        if copyThatPhrases.contains(lowerText) {
            let last = CommandEngine.lastResult
            if !last.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(last, forType: .string)
                print("[ENGINE] Copied last result to clipboard.")
            }
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }

        // Search trigger delegates
        if let out = await processSearchCommands(lowerText: lowerText, text: text) {
            return out
        }

        // Click commands
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

        // AI Orchestration / OCR delegates
        if let out = await processAIOrchestration(lowerText: lowerText, text: text, selection: selection) {
            return out
        }

        // Shell / terminal commands
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

        // Browser and website delegates
        if let out = processBrowserAndWebsites(lowerText: lowerText, text: text) {
            return out
        }

        // Spotify/music delegates
        if let out = processSpotifyMusic(lowerText: lowerText, text: text) {
            return out
        }

        // Shortcuts & Siri triggers
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
        }

        // Google searches
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

        // Focus & find searches
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

        // General app opens
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

        // Document / File uploading
        var pressReturn = false
        var fileURL: URL? = nil

        var extracted = extractFolderAndFileName(from: text)
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
                    
                    var cleanText = text
                    for phrase in uploadFolderPhrases + ["upload"] {
                        let escaped = NSRegularExpression.escapedPattern(for: phrase)
                        if let regex = try? Regex("\\b\(escaped)\\b").ignoresCase() {
                            cleanText = cleanText.replacing(regex, with: "")
                        }
                    }
                    text = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        // "send it" / "press enter" triggers
        for phrase in sendPhrases {
            let pattern = "[,.!?\\s]*\(phrase)[.!?]?\\s*$"
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                text.removeSubrange(range)
                pressReturn = true
                break
            }
        }

        // New paragraph and new line spoken formatting
        text = text.replacingOccurrences(
            of: "[,.]?\\s*\\bnew paragraph\\b[,.]?\\s*",
            with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(
            of: "[,.]?\\s*\\bnew line\\b[,.]?\\s*",
            with: "\n", options: [.regularExpression, .caseInsensitive])

        // Symbol mapping
        text = text.replacingOccurrences(
            of: "\\bat sign\\s+", with: "@",
            options: [.regularExpression, .caseInsensitive])

        text = context.style.apply(to: text)
        text = text.trimmingCharacters(in: .whitespaces)
        return CommandOutput(text: text, pressReturnAfter: pressReturn, fileURL: fileURL)
    }

    static func extractFileName(from text: String) -> String? {
        let patterns = [
            ("file\\s+named\\s+([a-zA-Z0-9_.-]+)", false),
            ("file\\s+([a-zA-Z0-9_.-]+\\.[a-zA-Z0-9]+)", false),
            ("file\\s+([a-zA-Z0-9_.-]+)", true)
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
            guard let regex = try? Regex(pattern).ignoresCase(),
                  let match = text.firstMatch(of: regex),
                  let captured = match.output[1].substring else { continue }
            var fileName = String(captured)
            while fileName.hasSuffix(".") || fileName.hasSuffix(",") || fileName.hasSuffix("?") || fileName.hasSuffix("!") || fileName.hasSuffix(":") || fileName.hasSuffix(";") {
                fileName.removeLast()
            }
            if checkStopWords && stopWords.contains(fileName.lowercased()) { continue }
            if !fileName.isEmpty { return fileName }
        }
        return nil
    }

    static func findFile(named name: String, under rootPath: String) -> URL? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let fileManager = FileManager.default
        let expandedPath = (rootPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath)

        if rootURL.lastPathComponent.lowercased() == name.lowercased() {
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("[BENCHMARK] Workspace root itself matches '\(name)' in \(String(format: "%.2f", duration * 1000))ms")
            return rootURL
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var bestMatch: URL?
        var filesScanned = 0

        while let fileURL = enumerator.nextObject() as? URL {
            filesScanned += 1
            let filename = fileURL.lastPathComponent.lowercased()
            let query = name.lowercased()

            if filename == query {
                bestMatch = fileURL
                break
            }

            if filename.hasPrefix(query) {
                bestMatch = fileURL
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("[BENCHMARK] File search for '\(name)' completed in \(String(format: "%.2f", duration * 1000))ms, scanned \(filesScanned) files. Found: \(bestMatch?.lastPathComponent ?? "NONE")")
        return bestMatch
    }

    static func preprocessSpeechArtifacts(_ input: String) -> String {
        let lower = input.lowercased()
        var text = input
        
        let fileCallKeywords = ["file called ", "file name ", "filename "]
        for keyword in fileCallKeywords {
            if let r = lower.range(of: keyword) {
                let after = input[r.upperBound...]
                let words = after.split(separator: " ")
                guard !words.isEmpty else { continue }
                
                var targetWord = String(words[0])
                var trailingCleaned = ""
                
                while targetWord.hasSuffix(".") || targetWord.hasSuffix(",") || targetWord.hasSuffix("?") || targetWord.hasSuffix("!") || targetWord.hasSuffix(":") || targetWord.hasSuffix(";") {
                    trailingCleaned = String(targetWord.last!) + trailingCleaned
                    targetWord.removeLast()
                }
                
                let cleanedName = cleanPunctuation(targetWord)
                if !cleanedName.isEmpty && cleanedName != targetWord {
                    let fullTargetPattern = targetWord + trailingCleaned
                    let replacement = "file " + cleanedName + trailingCleaned
                    text = text.replacingOccurrences(of: keyword + fullTargetPattern, with: replacement, options: .caseInsensitive)
                }
            }
        }

        if lower.contains(" dot ") {
            text = text.replacingOccurrences(of: " dot swift", with: ".swift", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot py", with: ".py", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot js", with: ".js", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot ts", with: ".ts", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot json", with: ".json", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot md", with: ".md", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot txt", with: ".txt", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot html", with: ".html", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot css", with: ".css", options: .caseInsensitive)
            text = text.replacingOccurrences(of: " dot sh", with: ".sh", options: .caseInsensitive)
        }
        
        return text
    }

    static func openApp(named name: String) -> Bool {
        return launchApp(named: name)
    }

    @discardableResult
    static func launchApp(named name: String) -> Bool {
        let cleanName = normalizeName(name)
        let aliases: [String: String] = [
            "chrome": "Google Chrome",
            "google chrome": "Google Chrome",
            "safari": "Safari",
            "xcode": "Xcode",
            "slack": "Slack",
            "spotify": "Spotify",
            "messages": "Messages",
            "mail": "Mail",
            "finder": "Finder",
            "terminal": "Terminal",
            "activity monitor": "Activity Monitor",
            "system settings": "System Settings",
            "system preferences": "System Settings"
        ]
        
        let appToLaunch = aliases[cleanName.lowercased()] ?? cleanName
        
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Siri") {
            if appToLaunch.lowercased() == "siri" {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
                return true
            }
        }

        let workspace = NSWorkspace.shared
        let fileManager = FileManager.default
        let appDirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "~/Applications"]
        for dir in appDirs {
            let expandedDir = (dir as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expandedDir)
            if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
                while let appURL = enumerator.nextObject() as? URL {
                    if appURL.lastPathComponent.lowercased() == "\(appToLaunch.lowercased()).app" {
                        let config = NSWorkspace.OpenConfiguration()
                        workspace.openApplication(at: appURL, configuration: config) { _, error in
                            if let error = error {
                                print("[ENGINE] Failed to launch application from search: \(error.localizedDescription)")
                            }
                        }
                        return true
                    }
                }
            }
        }
        
        print("[ENGINE] Failed to find or launch application: \(appToLaunch)")
        return false
    }

    static func googleSearch(query: String, inBrowser browser: String? = nil) {
        guard let escapedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let urlStr = "https://www.google.com/search?q=\(escapedQuery)"
        guard let url = URL(string: urlStr) else { return }
        
        if let browserName = browser {
            let workspace = NSWorkspace.shared
            let fileManager = FileManager.default
            let appDirs = ["/Applications", "/System/Applications"]
            var browserURL: URL? = nil
            
            for dir in appDirs {
                let url = URL(fileURLWithPath: dir)
                if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
                    while let appURL = enumerator.nextObject() as? URL {
                        if appURL.lastPathComponent.lowercased() == "\(browserName.lowercased()).app" {
                            browserURL = appURL
                            break
                        }
                    }
                }
            }
            
            if let appURL = browserURL {
                let config = NSWorkspace.OpenConfiguration()
                config.arguments = [urlStr]
                workspace.openApplication(at: appURL, configuration: config)
                return
            }
        }
        
        NSWorkspace.shared.open(url)
    }

    static func openWebsite(urlStr: String) {
        var cleanUrl = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanUrl.hasPrefix("http://") && !cleanUrl.hasPrefix("https://") {
            cleanUrl = "https://" + cleanUrl
        }
        if let url = URL(string: cleanUrl) {
            NSWorkspace.shared.open(url)
        }
    }

    static func searchSpotify(query: String) {
        guard let escapedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let spotifySearchURL = "spotify:search:\(escapedQuery)"
        if let url = URL(string: spotifySearchURL) {
            NSWorkspace.shared.open(url)
            print("[ENGINE] Opened Spotify search for: \(query)")
        }
    }

    static func runShortcut(named name: String, input: String? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        if let input = input {
            process.arguments = ["run", name, "--input-text", input]
        } else {
            process.arguments = ["run", name]
        }
        try? process.run()
    }

    static func runShellCommand(_ command: String, currentDirectory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryPath = (currentDirectory as NSString).expandingTildeInPath
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return "Execution failed: \(error.localizedDescription)"
        }
    }

    static func runAppleScriptNative(scriptPath: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptPath] + arguments
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return "AppleScript failed: \(error.localizedDescription)"
        }
    }

    static func runCommandNatively(_ fullCommand: String) -> String {
        let parts = fullCommand.split(separator: " ").map(String.init)
        guard !parts.isEmpty else { return "Empty command" }
        
        if parts[0] == "osascript" {
            let scriptPath = parts[1].replacingOccurrences(of: "\"", with: "")
            let arguments = Array(parts.dropFirst(2)).map { $0.replacingOccurrences(of: "\"", with: "") }
            return runAppleScriptNative(scriptPath: scriptPath, arguments: arguments)
        } else if parts[0] == "bash" {
            let scriptPath = parts[1].replacingOccurrences(of: "\"", with: "")
            let rootPath = SettingsController.workspacePath
            return runShellCommand("bash \"\(scriptPath)\"", currentDirectory: rootPath)
        } else {
            let rootPath = SettingsController.workspacePath
            return runShellCommand(fullCommand, currentDirectory: rootPath)
        }
    }

    static func captureScreenImage(displayID: CGDirectDisplayID) async -> CGImage? {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = 1920
        streamConfig.height = 1080
        
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
                return nil
            }
            
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: streamConfig)
            return image
        } catch {
            print("[SCREEN-OCR] Failed to capture screen: \(error.localizedDescription)")
            return nil
        }
    }

    static func performScreenOCR() async -> String {
        guard let image = await captureScreenImage(displayID: CGMainDisplayID()) else {
            return "Screen capture failed."
        }
        
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil else {
                    continuation.resume(returning: "OCR Request failed: \(error?.localizedDescription ?? "unknown error")")
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "No text found.")
                    return
                }
                
                var recognizedText = ""
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    recognizedText += candidate.string + "\n"
                }
                continuation.resume(returning: recognizedText)
            }
            
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: "Failed to perform OCR: \(error.localizedDescription)")
            }
        }
    }

    static func findAndClickText(_ target: String) async -> Bool {
        guard let image = await captureScreenImage(displayID: CGMainDisplayID()) else {
            return false
        }
        
        let screenWidth = CGFloat(image.width)
        let screenHeight = CGFloat(image.height)
        
        let foundRect: CGRect? = await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    if candidate.string.lowercased().contains(target.lowercased()) {
                        let boundingBox = observation.boundingBox
                        
                        let rect = CGRect(
                            x: boundingBox.origin.x * screenWidth,
                            y: (1.0 - boundingBox.origin.y - boundingBox.height) * screenHeight,
                            width: boundingBox.width * screenWidth,
                            height: boundingBox.height * screenHeight
                        )
                        continuation.resume(returning: rect)
                        return
                    }
                }
                continuation.resume(returning: nil)
            }
            
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
        
        guard let rect = foundRect else {
            print("[SCREEN-OCR] Text '\(target)' not found on screen.")
            return false
        }
        
        let clickX = rect.origin.x + (rect.size.width / 2.0)
        let clickY = rect.origin.y + (rect.size.height / 2.0)
        
        print("[SCREEN-OCR] Found '\(target)' at (\(clickX), \(clickY)). Simulating click...")
        
        let source = CGEventSource(stateID: .privateState)
        let clickPoint = CGPoint(x: clickX, y: clickY)
        
        guard let mouseDownEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left),
              let mouseUpEvent = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left) else {
            return false
        }
        
        mouseDownEvent.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        mouseUpEvent.post(tap: .cghidEventTap)
        return true
    }

    static func extractFolderAndFileName(from text: String) -> (folder: String?, file: String?) {
        let patterns = [
            ("in\\s+folder\\s+([a-zA-Z0-9_/.-]+)\\s+(?:find|get|open|read|upload)\\s+file\\s+named\\s+([a-zA-Z0-9_.-]+)", false),
            ("in\\s+folder\\s+([a-zA-Z0-9_/.-]+)\\s+(?:find|get|open|read|upload)\\s+file\\s+([a-zA-Z0-9_.-]+)", false),
            ("in\\s+folder\\s+([a-zA-Z0-9_/.-]+)\\s+file\\s+([a-zA-Z0-9_.-]+)", false),
            ("folder\\s+([a-zA-Z0-9_/.-]+)\\s+file\\s+([a-zA-Z0-9_.-]+)", false)
        ]
        
        for (pattern, _) in patterns {
            guard let regex = try? Regex(pattern).ignoresCase(),
                  let match = text.firstMatch(of: regex),
                  let folderSub = match.output[1].substring,
                  let fileSub = match.output[2].substring else { continue }
            let folder = String(folderSub).trimmingCharacters(in: .whitespacesAndNewlines)
            let file = String(fileSub).trimmingCharacters(in: .whitespacesAndNewlines)
            return (folder, file)
        }

        // Single match check: only folder
        let folderPatterns = [
            ("in\\s+folder\\s+([a-zA-Z0-9_/.-]+)", false),
            ("in\\s+directory\\s+([a-zA-Z0-9_/.-]+)", false),
            ("under\\s+folder\\s+([a-zA-Z0-9_/.-]+)", false)
        ]

        for (pattern, _) in folderPatterns {
            guard let regex = try? Regex(pattern).ignoresCase(),
                  let match = text.firstMatch(of: regex),
                  let folderSub = match.output[1].substring else { continue }
            let folder = String(folderSub).trimmingCharacters(in: .whitespacesAndNewlines)
            return (folder, nil)
        }
        
        return (nil, nil)
    }

    static func findDirectory(named name: String, under rootPath: String) -> URL? {
        let startTime = CFAbsoluteTimeGetCurrent()
        let fileManager = FileManager.default
        let expandedPath = (rootPath as NSString).expandingTildeInPath
        let rootURL = URL(fileURLWithPath: expandedPath)

        if rootURL.lastPathComponent.lowercased() == name.lowercased() {
            return rootURL
        }

        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var bestMatch: URL?
        var foldersScanned = 0

        while let fileURL = enumerator.nextObject() as? URL {
            var isDir: AnyObject?
            try? (fileURL as NSURL).getResourceValue(&isDir, forKey: .isDirectoryKey)
            guard let isDirectory = isDir as? Bool, isDirectory else { continue }
            
            foldersScanned += 1
            let folderName = fileURL.lastPathComponent.lowercased()
            
            if isDirectoryMatch(relativeDir: fileURL.path.replacingOccurrences(of: rootURL.path, with: ""), searchQuery: name) {
                bestMatch = fileURL
                break
            }
            
            if folderName == name.lowercased() {
                bestMatch = fileURL
            }
        }

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        print("[BENCHMARK] Folder search for '\(name)' completed in \(String(format: "%.2f", duration * 1000))ms, scanned \(foldersScanned) folders. Found: \(bestMatch?.path ?? "NONE")")
        return bestMatch
    }

    static func isDirectoryMatch(relativeDir: String, searchQuery: String) -> Bool {
        let cleanRel = relativeDir.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanQuery = searchQuery.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        if cleanRel == cleanQuery { return true }
        if cleanRel.hasSuffix("/" + cleanQuery) { return true }
        return false
    }

    static func normalizeName(_ name: String) -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasSuffix(".") || clean.hasSuffix(",") || clean.hasSuffix("?") || clean.hasSuffix("!") {
            clean.removeLast()
        }
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanPunctuation(_ input: String) -> String {
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return String(input.unicodeScalars.filter { allowedCharacters.contains($0) })
    }

    static func stripFileCommand(from input: String, fileName: String, folderName: String) -> String {
        let phrases = [
            "in folder \(folderName) find file named \(fileName)",
            "in folder \(folderName) find file \(fileName)",
            "in folder \(folderName) file \(fileName)",
            "folder \(folderName) file \(fileName)",
            "file named \(fileName) in folder \(folderName)",
            "file \(fileName) in folder \(folderName)"
        ]
        
        var cleanText = input
        for phrase in phrases {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            if let regex = try? Regex("\\b\(escaped)\\b").ignoresCase() {
                cleanText = cleanText.replacing(regex, with: "")
            }
        }
        return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripGlobalFileCommand(from input: String, fileName: String) -> String {
        let phrases = [
            "find file named \(fileName)",
            "find file \(fileName)",
            "file named \(fileName)",
            "file \(fileName)"
        ]

        var cleanText = input
        for phrase in phrases {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            if let regex = try? Regex("\\b\(escaped)\\b").ignoresCase() {
                cleanText = cleanText.replacing(regex, with: "")
            }
        }
        return cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSiriNativeCommand(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return false }
        
        let developerKeywords = ["code", "script", "git", "terminal", "cli", "shell", "run command", "compiler", "swift file", "scratch", "develop", "bug", "refactor", "ram", "gpu", "memory usage", "system status", "hardware", "cpu"]
        for kw in developerKeywords {
            if t.contains(kw) { return false }
        }

        // 1. Weather — routed straight to Siri, covers common phrasing synonyms
        if t.contains("weather") || t.contains("temperature") || t.contains("forecast") ||
           t.contains("outside today") || t.contains("raining") || t.contains("is it rain") ||
           t.contains("will it rain") || t.contains("will it snow") || t.contains("is it hot") ||
           t.contains("is it cold") || t.contains("umbrella") || t.contains("how hot") ||
           t.contains("how cold") || t.contains("storm") || t.contains("sunny outside") {
            return true
        }

        // 2. Reminders & Tasks
        if t.contains("remind me to") || t.contains("create a reminder") || t.contains("add a reminder") || t.contains("new reminder") ||
            t.hasPrefix("create task") || t.hasPrefix("new task") || t.hasPrefix("add task") ||
            t.contains("check my reminder") || t.contains("show my reminder") || t.contains("my reminder") {
            return true
        }

        // 3. Calendar & Meetings
        if t.contains("schedule a meeting") || t.contains("create a calendar event") || t.contains("add to my calendar") ||
            t.contains("schedule meeting") || t.hasPrefix("new meeting") || t.hasPrefix("add event") ||
            t.contains("check my calendar") || t.contains("show my calendar") || t.contains("my calendar") ||
            t.contains("do i have an event") || t.contains("events for today") || t.contains("my schedule") || t.contains("what is my schedule") {
            return true
        }

        // 4. Alarms & Timers
        if t.contains("set alarm") || t.contains("set a timer") || t.contains("start a timer") ||
           t.contains("wake me up at") || t.contains("create a timer") || t.contains("timer for ") {
            return true
        }

        // 5. Messages, Mail & Calls
        if t.hasPrefix("send a message") || t.hasPrefix("send a text") || t.hasPrefix("message ") || t.hasPrefix("text ") ||
           t.hasPrefix("email ") || t.hasPrefix("send an email") || t.hasPrefix("call ") ||
           t.hasPrefix("facetime ") || t.hasPrefix("whatsapp ") {
            return true
        }

        // 6. Sports / Stocks / Factual lookup / Location search fallback
        if t.contains("stock price of") || t.contains("sports score") || t.contains("who won the game") ||
            t.contains("what is the capital of") || t.contains("how high is") || t.contains("who is the president of") ||
            t.contains("what's the capital of") || t.contains("where is ") || t.contains("who is ") || t.contains("what is ") ||
            t.contains("tell me about ") || t.contains("search for ") || t.contains("search google for ") || t.contains("look up ") {
            return true
        }

        return false
    }
}

fileprivate let sendPhrases = [
    "send it", "send this", "press enter", "hit enter", "submit", "post it"
]
