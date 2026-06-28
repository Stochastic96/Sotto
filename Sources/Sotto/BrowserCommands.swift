import Foundation

extension CommandEngine {
    static func checkBrowserShortcut(for t: String) -> ZeroLatencyShortcut? {
        switch t {
        case "reload page", "reload tab", "refresh page", "refresh tab", "refresh", "reload":
            return ZeroLatencyShortcut(
                command: "native:browser_reload",
                voiceFeedback: "Page reloaded.",
                hudMessage: "Page Reloaded"
            )
        case "go back", "go back page", "page back", "back tab", "browser back", "go back tab":
            return ZeroLatencyShortcut(
                command: "native:browser_back",
                voiceFeedback: "Going back.",
                hudMessage: "Page Back"
            )
        case "go forward", "go forward page", "page forward", "forward tab", "browser forward", "go forward tab":
            return ZeroLatencyShortcut(
                command: "native:browser_forward",
                voiceFeedback: "Going forward.",
                hudMessage: "Page Forward"
            )
        case "new tab", "open new tab", "create tab", "create new tab":
            return ZeroLatencyShortcut(
                command: "native:browser_new_tab",
                voiceFeedback: "New tab opened.",
                hudMessage: "New Tab Opened"
            )
        case "close tab", "close current tab":
            return ZeroLatencyShortcut(
                command: "native:browser_close_tab",
                voiceFeedback: "Tab closed.",
                hudMessage: "Tab Closed"
            )
        case "list tabs", "show all tabs", "what tabs are open", "get all tabs", "show tabs":
            return ZeroLatencyShortcut(
                command: "native:browser_list_tabs",
                voiceFeedback: "Open tabs listed and copied to clipboard.",
                hudMessage: "List of Tabs"
            )
        default:
            return nil
        }
    }
    
    static func processBrowserAndWebsites(lowerText: String, text: String) -> CommandOutput? {
        // 1. Chrome search triggers
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
        return nil
    }
}
