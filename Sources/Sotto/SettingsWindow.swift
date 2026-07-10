import AppKit
import SwiftUI
import KeyboardShortcuts
import ServiceManagement
import AVFoundation

// UI-building/window-management side is MainActor (all AppKit calls belong there);
// the UserDefaults-backed static accessors below are marked `nonisolated` since
// they're plain, thread-safe reads/writes with no shared mutable class state, and
// are read from actor contexts elsewhere (SottoIntelligence, MorningBriefTool, etc.).
@MainActor
final class SettingsController: NSObject {
    private var window: NSWindow?
    
    // UserDefaults keys
    nonisolated static let pttKey = "sotto_pushToTalk"
    nonisolated static let directInsertKey = "sotto_directInsert"
    nonisolated static let systemPromptKey = "sotto_systemPrompt"
    nonisolated static let vocabularyKey = "sotto_vocabulary"
    nonisolated static let workspacePathKey = "sotto_workspacePath"
    nonisolated static let agentModeKey = "sotto_agentMode"
    nonisolated static let memoryLedgerKey = "sotto_showMemoryLedger"
    nonisolated static let voiceFeedbackEnabledKey = "sotto_voiceFeedbackEnabled"
    nonisolated static let voiceIdentifierKey = "sotto_voiceIdentifier"
    nonisolated static let speechRateKey = "sotto_speechRate"
    nonisolated static let speechPitchKey = "sotto_speechPitch"
    /// Sotto's brain is Apple Foundation Models (on-device, no network).
    /// Kept as a constant so existing call sites keep working without a provider picker.
    nonisolated static let apiProvider = "apple"

    nonisolated static var sottoDataURL: URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        
        // 1. Check if we're running from local git checkout by tracing up from the app bundle/executable.
        var currentURL = Bundle.main.bundleURL
        for _ in 0..<5 {
            let dataURL = currentURL.appendingPathComponent("sotto-data")
            if fm.fileExists(atPath: dataURL.path) {
                return dataURL
            }
            currentURL = currentURL.deletingLastPathComponent()
        }
        
        // 2. Fallback to ~/Projects/Sotto/sotto-data
        let projectsDir = home.appendingPathComponent("Projects/Sotto/sotto-data")
        if fm.fileExists(atPath: projectsDir.path) {
            return projectsDir
        }
        
        // 3. Application Support fallback for packaged app run
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sotto/sotto-data")
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    nonisolated static var sottoLogURL: URL {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        
        // 1. Check if we're running from local git checkout by tracing up from the app bundle/executable.
        var currentURL = Bundle.main.bundleURL
        for _ in 0..<5 {
            let logURL = currentURL.appendingPathComponent("sotto.log")
            let packageURL = currentURL.appendingPathComponent("Package.swift")
            if fm.fileExists(atPath: packageURL.path) {
                return logURL
            }
            currentURL = currentURL.deletingLastPathComponent()
        }
        
        // 2. Fallback to ~/Projects/Sotto/sotto.log
        let projectsDir = home.appendingPathComponent("Projects/Sotto")
        if fm.fileExists(atPath: projectsDir.path) {
            return projectsDir.appendingPathComponent("sotto.log")
        }
        
        // 3. Application Support fallback
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sotto")
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("sotto.log")
    }

    nonisolated static var isPushToTalk: Bool {
        UserDefaults.standard.object(forKey: pttKey) as? Bool ?? true
    }

    nonisolated static var isDirectInsert: Bool {
        UserDefaults.standard.bool(forKey: directInsertKey)
    }

    /// Debug-only HUD line showing warm model sessions and eviction count.
    /// Off by default; enable with `defaults write` on this key.
    nonisolated static var showMemoryLedger: Bool {
        UserDefaults.standard.bool(forKey: memoryLedgerKey)
    }

    nonisolated static var customSystemPrompt: String {
        UserDefaults.standard.string(forKey: systemPromptKey) ?? ""
    }
    
    nonisolated static var customVocabulary: String {
        UserDefaults.standard.string(forKey: vocabularyKey) ?? ""
    }
    
    nonisolated static var workspacePath: String {
        UserDefaults.standard.string(forKey: workspacePathKey) ?? "~/projects"
    }
    
    nonisolated static var homeCity: String {
        UserDefaults.standard.string(forKey: "sotto_home_city") ?? ""
    }
    
    nonisolated static var isAgentMode: Bool {
        UserDefaults.standard.object(forKey: agentModeKey) as? Bool ?? true
    }
    
    nonisolated static var isVoiceFeedbackEnabled: Bool {
        UserDefaults.standard.object(forKey: voiceFeedbackEnabledKey) as? Bool ?? true
    }
    
    nonisolated static var voiceIdentifier: String {
        let stored = UserDefaults.standard.string(forKey: voiceIdentifierKey)
        let excludedKeywords = ["cello", "novelty", "bell", "organ", "zarvox", "bubbles", "hysterical", "whisper", "bad_news", "trinoids", "deranged", "pipe", "reed"]
        if let st = stored {
            let lower = st.lowercased()
            let isExcluded = excludedKeywords.contains { kw in lower.contains(kw) }
            if !isExcluded {
                return st
            }
        }
        return "com.apple.voice.super-compact.en-GB.Daniel"
    }
    
    nonisolated static var speechRate: Float {
        UserDefaults.standard.object(forKey: speechRateKey) as? Float ?? AVSpeechUtteranceDefaultSpeechRate
    }
    
    nonisolated static var speechPitch: Float {
        UserDefaults.standard.object(forKey: speechPitchKey) as? Float ?? 1.0
    }
    

    func showSettings() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sotto Settings"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
