import Foundation
import AppKit

struct JarvisSwiftExecutor {
    
    static func writeResearchReport(name: String, content: String) -> String {
        let researchDir = SettingsController.sottoDataURL.appendingPathComponent("research")
        let safeName = name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let fileURL = researchDir.appendingPathComponent("\(safeName).md")
        do {
            try FileManager.default.createDirectory(at: researchDir, withIntermediateDirectories: true)
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("[SWIFT-EXECUTOR] Failed to write research report '\(safeName)' (\(error.localizedDescription)); the opened file may be missing.")
        }
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
            AppController.shared?.speak("Knowledge is power! Cached Wikipedia details for \(cleanQuery) retrieved and report opened.")
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
            AppController.shared?.speak("Research complete. Wikipedia results for \(cleanQuery) cached and report opened.")
        } else {
            // Wikipedia failed, open browser Google Search as fallback
            if let encoded = cleanQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchUrl = URL(string: "https://www.google.com/search?q=\(encoded)") {
                NSWorkspace.shared.open(searchUrl)
            }
            AppController.shared?.showHUD("⚠️ Wiki Search Failed")
            AppController.shared?.speak("No match found. Wikipedia failed, launching Google search.")
        }
    }
    
    @MainActor
    static func runWikiSet(key: String, value: String) async {
        SystemMemoryStore.set(key: "wiki:\(key.lowercased())", value: value, category: "wikipedia")
        AppController.shared?.showHUD("✓ Wiki Memory Saved")
        AppController.shared?.speak("Memory saved for Wikipedia key \(key).")
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
            AppController.shared?.speak("Maps open for \(cleanPlace) at \(addressFirstPart).")
        } else {
            NSWorkspace.shared.open(mapsUrl)
            AppController.shared?.showHUD("✓ Location Search")
            AppController.shared?.speak("Address not resolved natively. Redirecting to Google Maps search for \(cleanPlace).")
        }
    }
    
    @MainActor
    static func runLinkedIn(subcmd: String, arg: String? = nil) async {
        switch subcmd {
        case "feed":
            NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/feed/")!)
            AppController.shared?.showHUD("✓ LinkedIn Feed")
            AppController.shared?.speak("LinkedIn feed launched.")
        case "messages":
            NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/messaging/")!)
            AppController.shared?.showHUD("✓ LinkedIn Messages")
            AppController.shared?.speak("LinkedIn messages open and ready.")
        case "profile":
            NSWorkspace.shared.open(URL(string: "https://www.linkedin.com/in/")!)
            AppController.shared?.showHUD("✓ LinkedIn Profile")
            AppController.shared?.speak("LinkedIn profile open.")
        case "post":
            guard let topic = arg, !topic.isEmpty else { return }
            AppController.shared?.showHUD("📝 Writing post…")
            
            let prompt = """
            Write a professional, engaging, and high-impact LinkedIn post about: '\(topic)'.
            Include formatting, bullet points, a strong hook, takeaways, and hashtags. Output ONLY the post content.
            """
            let system = "You are an expert LinkedIn content creator and ghostwriter. Output only the post copy."
            
            guard let refiner = AppController.shared?.intelligence else {
                AppController.shared?.showHUD("⚠️ Local AI offline")
                AppController.shared?.speak("Local model not loaded. Post generation aborted.")
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
                AppController.shared?.speak("LinkedIn post generated and copied to clipboard. Feed open.")
            } catch {
                AppController.shared?.showHUD("⚠️ Generation Error")
                AppController.shared?.speak("Error creating LinkedIn post.")
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
            AppController.shared?.speak("Launching Google Ads \(target) dashboard.")
            
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
            
            guard let refiner = AppController.shared?.intelligence else {
                AppController.shared?.showHUD("⚠️ Local AI offline")
                AppController.shared?.speak("Local model offline. Command aborted.")
                return
            }
            
            do {
                let copySuggestions = try await refiner.getCompletion(systemPrompt: system, userPrompt: prompt)
                let report = "# Google Ads Copy Suggestions for: \(niche)\n\n\(copySuggestions)"
                let reportPath = writeResearchReport(name: "ads_copy_\(niche)", content: report)
                
                NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
                AppController.shared?.showHUD("✓ Ad Copy Ready")
                AppController.shared?.speak("Google Ads copy suggestions ready and file opened.")
            } catch {
                AppController.shared?.showHUD("⚠️ Generation Error")
                AppController.shared?.speak("Failed to generate Google Ads copy.")
            }
            
        case "campaign-tips":
            guard let industry = arg, !industry.isEmpty else { return }
            AppController.shared?.showHUD("📈 Fetching Tips…")
            
            let prompt = """
            Provide 5 solid, actionable Google Ads campaign structure and optimization tips for this industry: '\(industry)'.
            Include budgeting and negative keyword strategy hints.
            """
            let system = "You are a senior Google Ads specialist. Give short, punchy, expert advice."
            
            guard let refiner = AppController.shared?.intelligence else {
                AppController.shared?.showHUD("⚠️ Local AI offline")
                AppController.shared?.speak("Local model offline. Command aborted.")
                return
            }
            
            do {
                let tips = try await refiner.getCompletion(systemPrompt: system, userPrompt: prompt)
                let report = "# Google Ads Campaign Tips: \(industry)\n\n\(tips)"
                let reportPath = writeResearchReport(name: "ads_tips_\(industry)", content: report)
                
                NSWorkspace.shared.open(URL(fileURLWithPath: reportPath))
                AppController.shared?.showHUD("✓ Tips Ready")
                AppController.shared?.speak("Campaign structure tips for \(industry) generated and opened.")
            } catch {
                AppController.shared?.showHUD("⚠️ Generation Error")
                AppController.shared?.speak("Error generating Google Ads tips.")
            }
        default:
            print("[SWIFT-EXECUTOR] Unknown Google Ads subcommand: \(subcmd)")
        }
    }
}
