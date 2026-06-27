import Foundation

extension CommandEngine {
    static func processSearchCommands(lowerText: String, text: String) async -> CommandOutput? {
        // --- 0. Claude Popover Research ---
        let researchPrefixes = [
            "get me research done on topic ",
            "get me research done on ",
            "do research on topic ",
            "do research on ",
            "research topic ",
            "research "
        ]
        
        for prefix in researchPrefixes {
            if lowerText.hasPrefix(prefix) {
                var topic = String(text.dropFirst(prefix.count))
                while topic.hasSuffix(".") || topic.hasSuffix(",") || topic.hasSuffix("?") || topic.hasSuffix("!") {
                    topic.removeLast()
                }
                let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTopic.isEmpty {
                    print("[ENGINE] Native Swift trigger: Claude Popover Research for '\(cleanTopic)'")
                    
                    let prompt = """
                    Conduct a comprehensive research on the topic: "\(cleanTopic)".
                    Structure your analysis into clear sections. For each key area, provide a short title and a concise one-sentence description of the key findings. Keep the response clean and easy to scan.
                    """
                    
                    let response = await ClaudeQuickEntry.sendAndReadResponse(prompt)
                    return CommandOutput(text: response, pressReturnAfter: false, fileURL: nil)
                }
            }
        }

        // --- 1. Wikipedia/Fact Lookup ---
        if lowerText.hasPrefix("who is ") || lowerText.hasPrefix("what is ") || lowerText.hasPrefix("tell me about ") {
            var query = text
            if lowerText.hasPrefix("who is ") { query = String(text.dropFirst(7)) }
            else if lowerText.hasPrefix("what is ") { query = String(text.dropFirst(8)) }
            else if lowerText.hasPrefix("tell me about ") { query = String(text.dropFirst(14)) }
            
            while query.hasSuffix(".") || query.hasSuffix(",") || query.hasSuffix("?") || query.hasSuffix("!") { query.removeLast() }
            let cleanQuery = query.trimmingCharacters(in: .whitespaces)
            
            print("[ENGINE] Native Swift trigger: Wiki lookup for '\(cleanQuery)'")
            await JarvisSwiftExecutor.runWikiGet(query: cleanQuery)
            return CommandOutput(text: "", pressReturnAfter: false, fileURL: nil)
        }
        
        // --- 2. Location Lookup ---
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
        
        // --- 3. LinkedIn Shortcuts ---
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
        
        // --- 4. Google Ads Shortcuts ---
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
        return nil
    }
}
