import SwiftUI
import AVFoundation
import KeyboardShortcuts
import ServiceManagement

// MARK: - Settings (SwiftUI)
//
// The visual rewrite of the old 700-line AppKit card stack. Every value still
// lives under the exact same UserDefaults keys via `SettingsController`'s
// static accessors — other modules (SottoIntelligence, MorningBriefTool, …)
// read those keys cross-actor, so nothing about storage may change here.
//
// Bindings are explicit reads/writes instead of @AppStorage on purpose:
//   • `sotto_speechRate` is stored as Float (no @AppStorage overload), and
//   • three toggles use "absent means true" semantics that @AppStorage
//     defaults would silently break for existing users.
//
// Design language: text-only section headers (no decorative icons), native
// grouped form, one restrained gradient header band.

// MARK: Model

@MainActor
@Observable
final class SettingsModel {
    private let defaults = UserDefaults.standard
    private let testSynthesizer = AVSpeechSynthesizer()

    var pushToTalk: Bool { didSet { defaults.set(pushToTalk, forKey: SettingsController.pttKey) } }
    var dictationJarvisBridge: Bool { didSet { defaults.set(dictationJarvisBridge, forKey: SettingsController.dictationJarvisBridgeKey) } }
    var agentMode: Bool { didSet { defaults.set(agentMode, forKey: SettingsController.agentModeKey) } }
    var voiceFeedback: Bool { didSet { defaults.set(voiceFeedback, forKey: SettingsController.voiceFeedbackEnabledKey) } }
    var voiceIdentifier: String { didSet { defaults.set(voiceIdentifier, forKey: SettingsController.voiceIdentifierKey) } }
    var speechRate: Float { didSet { defaults.set(speechRate, forKey: SettingsController.speechRateKey) } }
    var directInsert: Bool { didSet { defaults.set(directInsert, forKey: SettingsController.directInsertKey) } }
    var workspacePath: String { didSet { defaults.set(workspacePath, forKey: SettingsController.workspacePathKey) } }
    var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: SettingsController.systemPromptKey) } }
    var vocabulary: String { didSet { defaults.set(vocabulary, forKey: SettingsController.vocabularyKey) } }

    /// Mirrors SMAppService; register/unregister on change, revert on failure.
    var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                } else {
                    if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
                }
            } catch {
                print("[SETTINGS] Failed to modify Launch at Login registration: \(error.localizedDescription)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    let voices: [AVSpeechSynthesisVoice]

    init() {
        pushToTalk = SettingsController.isPushToTalk
        dictationJarvisBridge = SettingsController.dictationJarvisBridge
        agentMode = SettingsController.isAgentMode
        voiceFeedback = SettingsController.isVoiceFeedbackEnabled
        voiceIdentifier = SettingsController.voiceIdentifier
        speechRate = SettingsController.speechRate
        directInsert = SettingsController.isDirectInsert
        workspacePath = SettingsController.workspacePath
        systemPrompt = SettingsController.customSystemPrompt
        vocabulary = SettingsController.customVocabulary
        launchAtLogin = SMAppService.mainApp.status == .enabled
        voices = Self.englishVoices()
    }

    /// English voices with the novelty set filtered out — same exclusion list
    /// the `SettingsController.voiceIdentifier` accessor enforces.
    static func englishVoices() -> [AVSpeechSynthesisVoice] {
        let excluded = ["cello", "novelty", "bell", "organ", "zarvox", "bubbles", "hysterical",
                        "whisper", "bad_news", "trinoids", "deranged", "pipe", "reed"]
        return AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let id = voice.identifier.lowercased()
            let name = voice.name.lowercased()
            return voice.language.lowercased().hasPrefix("en")
                && !excluded.contains { id.contains($0) || name.contains($0) }
        }
    }

    static func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = voice.quality == .premium ? " (Premium)"
                    : voice.quality == .enhanced ? " (Enhanced)" : ""
        return "\(voice.name)\(quality) [\(voice.language)]"
    }

    func testVoice() {
        let testText = "System online. Jarvis voice synthesis configured."
        if let controller = AppController.shared {
            controller.speak(testText)
            return
        }
        if testSynthesizer.isSpeaking { testSynthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: testText)
        if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else if let fallback = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US") {
            utterance.voice = fallback
        }
        utterance.rate = speechRate
        utterance.pitchMultiplier = SettingsController.speechPitch
        testSynthesizer.speak(utterance)
    }

    func resetLearnedData() {
        defaults.removeObject(forKey: "sotto_style_examples")
        defaults.removeObject(forKey: "sotto_learned_vocabulary")
        print("[SETTINGS] Reset learned style examples and vocabulary")
    }

    func browseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (workspacePath as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
        }
    }
}

// MARK: View

struct SettingsView: View {
    @State private var model = SettingsModel()
    @State private var showResetConfirmation = false
    @State private var showResetDone = false

    var body: some View {
        VStack(spacing: 0) {
            header
            form
        }
        .frame(minWidth: 500, minHeight: 560)
    }

    // One restrained gradient band — the only decorative element in Settings.
    private var header: some View {
        ZStack {
            // Same brand mesh as the Jarvis orb, at rest — shared grid + colors.
            MeshGradient(
                width: 3,
                height: 3,
                points: SottoDesign.Mesh.grid,
                colors: SottoDesign.Mesh.colors(for: .dictation)
            )
            .opacity(SottoDesign.Opacity.decorative)
            VStack(spacing: 2) {
                Text("Sotto")
                    .font(SottoDesign.Typography.sectionTitle)
                Text("On-device dictation and Jarvis")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 18)
        }
        .frame(height: 84)
        .glassEffect(in: .rect(cornerRadius: SottoDesign.Metrics.windowCorner))
    }

    private var form: some View {
        Form {
            Section("Hotkeys & Mode") {
                KeyboardShortcuts.Recorder("Dictation shortcut", name: .toggleDictation)
                KeyboardShortcuts.Recorder("Jarvis shortcut", name: .toggleJarvis)
                Toggle("Push-to-talk", isOn: $model.pushToTalk)
                Text("Hold the hotkey while speaking, release to stop. Off = press once to start, again to stop.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("“Jarvis, …” while dictating runs a command", isOn: $model.dictationJarvisBridge)
                Text("When on, a dictation that opens with the wake word (“Jarvis, open Xcode”) is handed to Jarvis and executed instead of typed. Off = every dictation is typed verbatim.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Launch Sotto at login", isOn: $model.launchAtLogin)
            }

            Section("On-Device Brain") {
                Text("Sotto runs entirely on Apple Foundation Models — no servers, no network at inference time. Dictation polish uses a dedicated prewarmed session; Jarvis tool-calling runs through the same on-device model.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("System Control") {
                Toggle("Enable AppleScript system control", isOn: $model.agentMode)
                Text("Lets Jarvis translate spoken commands into local AppleScript (set volume, open apps, Finder actions).")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Jarvis Voice") {
                Toggle("Voice feedback", isOn: $model.voiceFeedback)
                Picker("Voice", selection: $model.voiceIdentifier) {
                    ForEach(model.voices, id: \.identifier) { voice in
                        Text(SettingsModel.voiceLabel(voice)).tag(voice.identifier)
                    }
                }
                HStack {
                    Slider(value: $model.speechRate,
                           in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate) {
                        Text("Speech speed")
                    }
                    Button("Test Voice") { model.testVoice() }
                }
            }

            Section("Workspace & Text Insertion") {
                HStack {
                    TextField("Workspace folder", text: $model.workspacePath, prompt: Text("e.g. ~/projects"))
                    Button("Browse…") { model.browseWorkspace() }
                }
                Text("Sotto searches inside this folder when tagging or pasting code files.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Direct text insertion", isOn: $model.directInsert)
                Text("Inserts text at the cursor via Accessibility. Off = simulated ⌘V paste (safest for most apps).")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("AI Polish Prompt") {
                TextField("Polish instructions", text: $model.systemPrompt,
                          prompt: Text("e.g. Make my text sound highly professional"), axis: .vertical)
                    .lineLimit(2...4)
                Text("Optional instructions for polishing your dictation. Leave empty for the default behaviour.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Custom Vocabulary") {
                TextField("Vocabulary", text: $model.vocabulary,
                          prompt: Text("e.g. Sotto, macOS, Prashant, Xcode"), axis: .vertical)
                    .lineLimit(2...4)
                Text("Comma-separated names and jargon so Sotto spells them correctly.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Data") {
                Button("Reset Learned Style & Vocabulary…", role: .destructive) {
                    showResetConfirmation = true
                }
                Text("Clears the style context and words Sotto learned from your past dictation sessions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset learned data?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                model.resetLearnedData()
                showResetDone = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Learned dictation style examples and custom vocabulary will be cleared.")
        }
        .alert("Reset complete", isPresented: $showResetDone) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Learned style examples and custom vocabulary have been cleared.")
        }
    }
}
