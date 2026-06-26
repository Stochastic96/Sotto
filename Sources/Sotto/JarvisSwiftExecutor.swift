import Foundation
import AppKit

struct JarvisSwiftExecutor {
    
    static func writeResearchReport(name: String, content: String) -> String {
        let researchDir = SettingsController.sottoDataURL.appendingPathComponent("research")
        try? FileManager.default.createDirectory(at: researchDir, withIntermediateDirectories: true)
        
        let safeName = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let fileURL = researchDir.appendingPathComponent("\(safeName).md")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }
    
    @MainActor
    static func runWikiGet(query: String) async {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanQuery.isEmpty { return }
        
        AppController.shared?.showHUD("🔍 Cache check…")
        
        // 1. Check Cache
        if let cached = SystemMemoryStore.get(key: "wiki:\(cleanQuery.lowercased())") {
            let reportPath = writeResearchReport(name: cleanQuery, content: "# Wikipedia Cache: \(cleanQuery)\n\n\(cached)\n")
            NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
            
            AppController.shared?.showHUD("✓ Wiki Cache Found")
            AppController.shared?.speak("मिस्टर लॉर्ड, personal Wikipedia से '\(cleanQuery)' की जानकारी मिल गई है, एकदम मक्खन! details open हैं।")
            return
        }
        
        // 2. Query Wikipedia API
        AppController.shared?.showHUD("🔍 Researching Wikipedia…")
        if let result = await SystemDiagnostics.queryWikipedia(query: cleanQuery) {
            let combinedVal = "### Wikipedia: \(result.title)\n\(result.extract)\n*(Source: \(result.url))*"
            
            SystemMemoryStore.set(key: "wiki:\(cleanQuery.lowercased())", value: combinedVal, category: "wikipedia")
            
            let reportPath = writeResearchReport(name: cleanQuery, content: "# Personal Wikipedia: \(cleanQuery) (Auto-Cached)\n\n\(combinedVal)\n")
            NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
            
            AppController.shared?.showHUD("✓ Wiki Cache Updated")
            AppController.shared?.speak("ओए मिस्टर लॉर्ड, मैंने '\(cleanQuery)' की जानकारी Wikipedia API से निकाल कर database में चेप दी है। दिल्ली से हूँ भाई, सब सेट कर देता हूँ।")
        } else {
            // Wikipedia failed, open browser Google Search as fallback
            if let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchUrl = URL(string: "https://www.google.com/search?q=\(encoded)") {
                NSWorkspace.shared.open(searchUrl)
            }
            AppController.shared?.showHUD("⚠️ Wiki Search Failed")
            AppController.shared?.speak("ओए भाई, Wikipedia पर '\(cleanQuery)' का कोई matching result नहीं मिला, पर मैंने Google Search खोल दिया है।")
        }
    }
    
    @MainActor
    static func runWikiSet(key: String, value: String) async {
        SystemMemoryStore.set(key: "wiki:\(key.lowercased())", value: value, category: "wikipedia")
        AppController.shared?.showHUD("✓ Wiki Memory Saved")
        AppController.shared?.speak("डन भाई, तेरे भाई ने Wikipedia में key '\(key)' को save कर दिया है।")
    }
    
    @MainActor
    static func runLocation(placeName: String) async {
        let cleanPlace = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanPlace.isEmpty { return }
        
        AppController.shared?.showHUD("🗺 Locating…")
        
        let mapsUrlString = "https://www.google.com/maps/place/\(cleanPlace.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        guard let mapsUrl = URL(string: mapsUrlString) else { return }
        
        if let result = await SystemDiagnostics.geocodeLocation(placeName: cleanPlace) {
            let combinedVal = "Location: \(cleanPlace)\nAddress: \(result.display_name)\nCoordinates: Latitude \(result.lat), Longitude \(result.lon)"
            SystemMemoryStore.set(key: "location:\(cleanPlace.lowercased())", value: combinedVal, category: "location")
            
            let report = "# Location Report: \(cleanPlace)\n\n**Address**: \(result.display_name)\n**Coordinates**: \(result.lat), \(result.lon)\n\n[Open in Google Maps](\(mapsUrlString))\n"
            let reportPath = writeResearchReport(name: "location_\(cleanPlace)", content: report)
            
            NSWorkspace.shared.open(mapsUrl)
            NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
            
            let addressFirstPart = result.display_name.components(separatedBy: ",").first ?? result.display_name
            AppController.shared?.showHUD("✓ Location Resolved")
            AppController.shared?.speak("लो भाई, \(cleanPlace) का scene set कर दिया है। यह \(addressFirstPart) में है। Maps खोल दिया है, दिल्ली से हूँ भाई, रास्ता कभी नहीं भूलता!")
        } else {
            NSWorkspace.shared.open(mapsUrl)
            AppController.shared?.showHUD("✓ Location Search")
            AppController.shared?.speak("ओए भाई, direct address API से नहीं मिला, पर मैंने Google Maps पर \(cleanPlace) open मार दिया है। दिल्ली से हूँ बहनचोद, रास्ता कभी नहीं भूलता!")
        }
    }
    
    @MainActor
    static func runLinkedIn(subcmd: String, arg: String? = nil) async {
        switch subcmd {
        case "feed":
            NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/feed/")!)
            AppController.shared?.showHUD("✓ LinkedIn Feed")
            AppController.shared?.speak("LinkedIn feed खोल रहा हूँ भाई, गजब सीन है।")
        case "messages":
            NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/messaging/")!)
            AppController.shared?.showHUD("✓ LinkedIn Messages")
            AppController.shared?.speak("LinkedIn messaging open कर दिया है भाई, बकचोदी शुरू करो!")
        case "profile":
            NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/in/")!)
            AppController.shared?.showHUD("✓ LinkedIn Profile")
            AppController.shared?.speak("LinkedIn profile खोल रहा हूँ भाई।")
        case "post":
            guard let topic = arg, !topic.isEmpty else { return }
            AppController.shared?.showHUD("📝 Writing post…")
            
            let prompt = """
            Write a professional, engaging, and high-impact LinkedIn post about: '\(topic)'.
            Include formatting, bullet points, a strong hook, takeaways, and hashtags. Output ONLY the post content.
            """
            let system = "You are an expert LinkedIn content creator and ghostwriter. Output only the post copy."
            
            guard let refiner = AppController.shared?.intelligenceEngine else {
                AppController.shared?.showHUD("⚠️ Local AI offline")
                AppController.shared?.speak("ओए भाई, local model loaded नहीं है, post नहीं बन पाया।")
                return
            }
            
            do {
                let postCopy = try await refiner.getCompletion(systemPrompt: system, userPrompt: prompt)
                let report = "# LinkedIn Draft Post\n\n\(postCopy)"
                let reportPath = writeResearchReport(name: "linkedin_post", content: report)
                
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(postCopy, forType: .string)
                
                NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/feed/?showComposer=true")!)
                NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
                
                AppController.shared?.showHUD("✓ Post Copied")
                AppController.shared?.speak("तेरे भाई ने LinkedIn post generate कर दिया है और clipboard पे copy मार दिया है। Feed open हो गया है, paste कर के share मारो! दिल्ली से हूँ भाई, भौकाल मचा दिया है।")
            } catch {
                AppController.shared?.showHUD("⚠️ Generation Error")
                AppController.shared?.speak("LinkedIn post बनाने में error आ गया भाई।")
            }
        default:
            print("[SWIFT-EXECUTOR] Unknown LinkedIn subcommand: \(subcmd)")
        }
    }
    
    @MainActor
    static func runGoogleAds(subcmd: String, arg: String? = nil) async {
        switch subcmd {
        case "dashboard":
            let urls = [
                "campaigns": "https://ads.google.com/aw/campaigns",
                "keyword-planner": "https://ads.google.com/aw/keywordplanner",
                "billing": "https://ads.google.com/aw/billing",
                "overview": "https://ads.google.com/aw/overview"
            ]
            let target = arg?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? "overview"
            let urlStr = urls[target] ?? "https://ads.google.com"
            NSWorkspace.shared.open(URL(string: urlStr)!)
            AppController.shared?.showHUD("✓ Google Ads \(target)")
            AppController.shared?.speak("ओए मिस्टर लॉर्ड, Google Ads \(target) डैशबोर्ड खोल रहा हूँ भाई।")
            
        case "ad-copy":
            guard let niche = arg, !niche.isEmpty else { return }
            AppController.shared?.showHUD("📝 Writing Ads Copy…")
            
            let prompt = """
            Generate Google Ads Search Ad copy suggestions for this business/niche: '\(niche)'.
            Return at least:
            - 3 Headlines (max 30 characters each)
            - 2 Descriptions (max 90 characters each)
            Format as clear text headlines and descriptions.
            """
            let system = "You are a professional Google Ads copywriter. Output clear headlines and descriptions."
            
            guard let refiner = AppController.shared?.intelligenceEngine else {
                AppController.shared?.showHUD("⚠️ Local AI offline")
                AppController.shared?.speak("ओए भाई, local model loaded नहीं है।")
                return
            }
            
            do {
                let copySuggestions = try await refiner.getCompletion(systemPrompt: system, userPrompt: prompt)
                let report = "# Google Ads Copy Suggestions for: \(niche)\n\n\(copySuggestions)"
                let reportPath = writeResearchReport(name: "ads_copy_\(niche)", content: report)
                
                NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
                AppController.shared?.showHUD("✓ Ad Copy Ready")
                AppController.shared?.speak("मिस्टर लॉर्ड, Google Ads copy suggestions बना दिए हैं भाई, गजब सीन है। File open कर दी है।")
            } catch {
                AppController.shared?.showHUD("⚠️ Generation Error")
                AppController.shared?.speak("Google Ads copy बनाने में error आ गया भाई।")
            }
            
        case "campaign-tips":
            guard let industry = arg, !industry.isEmpty else { return }
            AppController.shared?.showHUD("📈 Fetching Tips…")
            
            let prompt = """
            Provide 5 solid, actionable Google Ads campaign structure and optimization tips for this industry: '\(industry)'.
            Include budgeting and negative keyword strategy hints.
            """
            let system = "You are a senior Google Ads specialist. Give short, punchy, expert advice."
            
            guard let refiner = AppController.shared?.intelligenceEngine else {
                AppController.shared?.showHUD("⚠️ Local AI offline")
                AppController.shared?.speak("ओए भाई, local model loaded नहीं है।")
                return
            }
            
            do {
                let tips = try await refiner.getCompletion(systemPrompt: system, userPrompt: prompt)
                let report = "# Google Ads Campaign Tips: \(industry)\n\n\(tips)"
                let reportPath = writeResearchReport(name: "ads_tips_\(industry)", content: report)
                
                NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
                AppController.shared?.showHUD("✓ Tips Ready")
                AppController.shared?.speak("मिस्टर लॉर्ड, \(industry) के लिए Google Ads tips निकाल दिए हैं, चिल मारो भाई।")
            } catch {
                AppController.shared?.showHUD("⚠️ Generation Error")
                AppController.shared?.speak("Google Ads tips निकालने में error आ गया भाई।")
            }
        default:
            print("[SWIFT-EXECUTOR] Unknown Google Ads subcommand: \(subcmd)")
        }
    }
}
