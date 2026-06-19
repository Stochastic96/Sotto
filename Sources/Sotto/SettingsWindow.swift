import AppKit
import KeyboardShortcuts
import ServiceManagement
import AVFoundation

enum TranscriptionEngine: String, CaseIterable {
    case offlineAI = "offlineAI"
    case appleSpeech = "appleSpeech"
    
    var displayName: String {
        switch self {
        case .offlineAI: return "Offline AI (Parakeet ANE)"
        case .appleSpeech: return "Apple Native Dictation (Siri)"
        }
    }
}

final class SettingsController: NSObject, NSTextFieldDelegate {
    private var window: NSWindow?
    private var workspaceField: NSTextField?
    var onEngineChanged: (() -> Void)?
    private let testSynthesizer = AVSpeechSynthesizer()
    
    // UserDefaults keys
    static let pttKey = "sotto_pushToTalk"
    static let directInsertKey = "sotto_directInsert"
    static let systemPromptKey = "sotto_systemPrompt"
    static let vocabularyKey = "sotto_vocabulary"
    static let workspacePathKey = "sotto_workspacePath"
    static let engineKey = "sotto_transcriptionEngine"
    static let agentModeKey = "sotto_agentMode"
    static let voiceFeedbackEnabledKey = "sotto_voiceFeedbackEnabled"
    static let voiceIdentifierKey = "sotto_voiceIdentifier"
    static let speechRateKey = "sotto_speechRate"
    static let speechPitchKey = "sotto_speechPitch"
    static let modelIdentifierKey = "sotto_modelIdentifier"

    /// Sotto's brain is always on-device Apple Intelligence (+ in-process MLX Qwen).
    /// Kept as a constant so existing call sites keep working without a provider picker.
    static let apiProvider = "apple"

    static var isPushToTalk: Bool {
        UserDefaults.standard.object(forKey: pttKey) as? Bool ?? true
    }
    
    static var isDirectInsert: Bool {
        UserDefaults.standard.bool(forKey: directInsertKey)
    }
    
    static var customSystemPrompt: String {
        UserDefaults.standard.string(forKey: systemPromptKey) ?? ""
    }
    
    static var customVocabulary: String {
        UserDefaults.standard.string(forKey: vocabularyKey) ?? ""
    }
    
    static var workspacePath: String {
        UserDefaults.standard.string(forKey: workspacePathKey) ?? "~/projects"
    }
    
    static var transcriptionEngine: TranscriptionEngine {
        let raw = UserDefaults.standard.string(forKey: engineKey) ?? TranscriptionEngine.offlineAI.rawValue
        return TranscriptionEngine(rawValue: raw) ?? .offlineAI
    }
    
    static var isAgentMode: Bool {
        UserDefaults.standard.object(forKey: agentModeKey) as? Bool ?? true
    }
    
    static var isVoiceFeedbackEnabled: Bool {
        UserDefaults.standard.object(forKey: voiceFeedbackEnabledKey) as? Bool ?? true
    }
    
    static var voiceIdentifier: String {
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
    
    static var speechRate: Float {
        UserDefaults.standard.object(forKey: speechRateKey) as? Float ?? AVSpeechUtteranceDefaultSpeechRate
    }
    
    static var speechPitch: Float {
        UserDefaults.standard.object(forKey: speechPitchKey) as? Float ?? 1.0
    }
    
    /// The in-process MLX Qwen model used for heavier / long-form generation.
    /// Small 4-bit default chosen to fit alongside Apple Intelligence on an 8 GB Mac.
    static var modelIdentifier: String {
        UserDefaults.standard.string(forKey: modelIdentifierKey) ?? "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    }

    func showSettings() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        let width: CGFloat = 480
        let height: CGFloat = 600
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sotto Settings"
        window.isReleasedWhenClosed = false
        window.center()
        
        // Use scroll view to ensure everything fits perfectly on all screen resolutions
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.windowBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        
        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        
        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        documentView.addSubview(stack)
        
        window.contentView = scrollView
        
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            
            documentView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor)
        ])
        
        // --- 1. Global Dictation Hotkey Card ---
        let hotkeyStack = NSStackView()
        hotkeyStack.orientation = .vertical
        hotkeyStack.alignment = .leading
        hotkeyStack.spacing = 10
        hotkeyStack.translatesAutoresizingMaskIntoConstraints = false
        
        let dictationLabel = NSTextField(labelWithString: "Whisper Dictation Shortcut (Default: ⌘ShiftK)")
        dictationLabel.font = .systemFont(ofSize: 11, weight: .bold)
        dictationLabel.textColor = NSColor.secondaryLabelColor
        hotkeyStack.addArrangedSubview(dictationLabel)
        
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleDictation)
        hotkeyStack.addArrangedSubview(recorder)
        
        let jarvisLabel = NSTextField(labelWithString: "Jarvis OS Agent Shortcut (Default: ⌘ShiftJ)")
        jarvisLabel.font = .systemFont(ofSize: 11, weight: .bold)
        jarvisLabel.textColor = NSColor.secondaryLabelColor
        hotkeyStack.addArrangedSubview(jarvisLabel)
        
        let jarvisRecorder = KeyboardShortcuts.RecorderCocoa(for: .toggleJarvis)
        hotkeyStack.addArrangedSubview(jarvisRecorder)
        
        let pttCheckbox = NSButton(checkboxWithTitle: "Push-To-Talk Mode", target: self, action: #selector(togglePTT(_:)))
        pttCheckbox.state = Self.isPushToTalk ? .on : .off
        pttCheckbox.font = .systemFont(ofSize: 12, weight: .medium)
        hotkeyStack.addArrangedSubview(pttCheckbox)
        
        let pttDesc = createDescriptionLabel("Hold the hotkey down to dictate, release to stop recording. Uncheck for standard click-to-start, click-to-stop toggle.")
        hotkeyStack.addArrangedSubview(pttDesc)
        
        let hotkeyDivider = NSBox()
        hotkeyDivider.boxType = .separator
        hotkeyDivider.translatesAutoresizingMaskIntoConstraints = false
        hotkeyStack.addArrangedSubview(hotkeyDivider)
        hotkeyDivider.leadingAnchor.constraint(equalTo: hotkeyStack.leadingAnchor).isActive = true
        hotkeyDivider.trailingAnchor.constraint(equalTo: hotkeyStack.trailingAnchor).isActive = true

        let loginCheckbox = NSButton(checkboxWithTitle: "Launch Sotto at Login", target: self, action: #selector(toggleLaunchAtLogin(_:)))
        loginCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginCheckbox.font = .systemFont(ofSize: 12, weight: .medium)
        hotkeyStack.addArrangedSubview(loginCheckbox)

        let loginDesc = createDescriptionLabel("Automatically start Sotto in the menu bar when you log in to your Mac.")
        hotkeyStack.addArrangedSubview(loginDesc)
        
        let hotkeyCard = createCard(title: "Dictation Hotkey & Mode", iconName: "keyboard", subview: hotkeyStack)
        stack.addArrangedSubview(hotkeyCard)
        
        // --- 1b. Speech Recognition Engine Card ---
        let engineStack = NSStackView()
        engineStack.orientation = .vertical
        engineStack.alignment = .leading
        engineStack.spacing = 10
        engineStack.translatesAutoresizingMaskIntoConstraints = false
        
        let enginePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        enginePopUp.bezelStyle = .rounded
        enginePopUp.font = .systemFont(ofSize: 12)
        enginePopUp.translatesAutoresizingMaskIntoConstraints = false
        for engine in TranscriptionEngine.allCases {
            enginePopUp.addItem(withTitle: engine.displayName)
        }
        let currentEngine = Self.transcriptionEngine
        if let index = TranscriptionEngine.allCases.firstIndex(of: currentEngine) {
            enginePopUp.selectItem(at: index)
        }
        enginePopUp.target = self
        enginePopUp.action = #selector(enginePopUpChanged(_:))
        engineStack.addArrangedSubview(enginePopUp)
        
        let engineDesc = createDescriptionLabel("Choose the speech recognition technology. Offline AI runs a local private ANE model (requires model download). Apple Native Dictation uses macOS Siri engine for instant setup.")
        engineStack.addArrangedSubview(engineDesc)
        
        let engineCard = createCard(title: "Speech Recognition Engine", iconName: "waveform", subview: engineStack)
        stack.addArrangedSubview(engineCard)
        
        // --- 1c. LLM API Settings Card ---
        let llmStack = NSStackView()
        llmStack.orientation = .vertical
        llmStack.alignment = .leading
        llmStack.spacing = 10
        llmStack.translatesAutoresizingMaskIntoConstraints = false
        
        let modelLabel = NSTextField(labelWithString: "MLX Qwen Model ID (heavy / long-form tasks)")
        modelLabel.font = .systemFont(ofSize: 11, weight: .bold)
        modelLabel.textColor = NSColor.secondaryLabelColor
        llmStack.addArrangedSubview(modelLabel)

        let modelField = createTextField(placeholder: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", value: Self.modelIdentifier)
        modelField.delegate = self
        modelField.target = self
        modelField.action = #selector(modelChanged(_:))
        llmStack.addArrangedSubview(modelField)
        modelField.leadingAnchor.constraint(equalTo: llmStack.leadingAnchor).isActive = true
        modelField.trailingAnchor.constraint(equalTo: llmStack.trailingAnchor).isActive = true

        let llmDesc = createDescriptionLabel("Sotto's brain is fully on-device and native. Apple Intelligence (Foundation Models) handles dictation polish and the Jarvis agent; the in-process MLX Qwen model above handles heavier/long-form generation, kept warm in memory. No Python, no servers, no network. On 8 GB Macs keep a small 4-bit model (e.g. Qwen2.5-1.5B-Instruct-4bit).")
        llmStack.addArrangedSubview(llmDesc)

        let llmCard = createCard(title: "On-Device Brain", iconName: "cpu", subview: llmStack)
        stack.addArrangedSubview(llmCard)
        
        // --- 1c. AI Agent Mode Card ---
        let agentStack = NSStackView()
        agentStack.orientation = .vertical
        agentStack.alignment = .leading
        agentStack.spacing = 10
        agentStack.translatesAutoresizingMaskIntoConstraints = false
        
        let agentCheckbox = NSButton(checkboxWithTitle: "Enable AppleScript System Control", target: self, action: #selector(toggleAgentMode(_:)))
        agentCheckbox.state = Self.isAgentMode ? .on : .off
        agentCheckbox.font = .systemFont(ofSize: 12, weight: .medium)
        agentStack.addArrangedSubview(agentCheckbox)
        
        let agentDesc = createDescriptionLabel("Allows Sotto to translate spoken commands into native AppleScript code and execute them locally to control your Mac (e.g., set volume, open apps, Finder commands).")
        agentStack.addArrangedSubview(agentDesc)
        
        let agentCard = createCard(title: "AI Agent System Control", iconName: "bolt.fill", subview: agentStack)
        stack.addArrangedSubview(agentCard)
        
        // --- 1d. Jarvis Voice Card ---
        let voiceStack = NSStackView()
        voiceStack.orientation = .vertical
        voiceStack.alignment = .leading
        voiceStack.spacing = 10
        voiceStack.translatesAutoresizingMaskIntoConstraints = false
        
        let voiceCheckbox = NSButton(checkboxWithTitle: "Enable Jarvis Voice Feedback", target: self, action: #selector(toggleVoiceFeedback(_:)))
        voiceCheckbox.state = Self.isVoiceFeedbackEnabled ? .on : .off
        voiceCheckbox.font = .systemFont(ofSize: 12, weight: .medium)
        voiceStack.addArrangedSubview(voiceCheckbox)
        
        let voiceDesc = createDescriptionLabel("Have Jarvis talk back to report the plan execution status and outcomes (native AVSpeechSynthesizer).")
        voiceStack.addArrangedSubview(voiceDesc)

        // Voice Selection Dropdown & Test Button horizontal stack
        let dropdownStack = NSStackView()
        dropdownStack.orientation = .horizontal
        dropdownStack.spacing = 8
        dropdownStack.translatesAutoresizingMaskIntoConstraints = false
        
        let voicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        voicePopUp.bezelStyle = .rounded
        voicePopUp.font = .systemFont(ofSize: 12)
        voicePopUp.translatesAutoresizingMaskIntoConstraints = false
        
        let excludedKeywords = ["cello", "novelty", "bell", "organ", "zarvox", "bubbles", "hysterical", "whisper", "bad_news", "trinoids", "deranged", "pipe", "reed"]
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let lang = voice.language.lowercased()
            let id = voice.identifier.lowercased()
            let name = voice.name.lowercased()
            let isEnglish = lang.hasPrefix("en")
            let isExcluded = excludedKeywords.contains { kw in id.contains(kw) || name.contains(kw) }
            return isEnglish && !isExcluded
        }
        for voice in englishVoices {
            let qualityStr = voice.quality == .premium ? " (Premium)" : (voice.quality == .enhanced ? " (Enhanced)" : "")
            voicePopUp.addItem(withTitle: "\(voice.name)\(qualityStr) [\(voice.language)]")
        }
        
        let currentVoiceId = Self.voiceIdentifier
        if let idx = englishVoices.firstIndex(where: { $0.identifier == currentVoiceId }) {
            voicePopUp.selectItem(at: idx)
        } else if let defaultIdx = englishVoices.firstIndex(where: { $0.identifier.contains("Daniel") }) {
            voicePopUp.selectItem(at: defaultIdx)
        } else if !englishVoices.isEmpty {
            voicePopUp.selectItem(at: 0)
        }
        voicePopUp.target = self
        voicePopUp.action = #selector(voicePopUpChanged(_:))
        dropdownStack.addArrangedSubview(voicePopUp)
        
        let testBtn = NSButton(title: "Test Voice", target: self, action: #selector(testVoicePress(_:)))
        testBtn.bezelStyle = .rounded
        testBtn.font = .systemFont(ofSize: 12)
        dropdownStack.addArrangedSubview(testBtn)
        
        voiceStack.addArrangedSubview(dropdownStack)
        
        // Rate Slider
        let rateLabel = NSTextField(labelWithString: "Speech Speed (Rate)")
        rateLabel.font = .systemFont(ofSize: 11, weight: .bold)
        rateLabel.textColor = NSColor.secondaryLabelColor
        voiceStack.addArrangedSubview(rateLabel)
        
        let rateSlider = NSSlider(value: Double(Self.speechRate), minValue: Double(AVSpeechUtteranceMinimumSpeechRate), maxValue: Double(AVSpeechUtteranceMaximumSpeechRate), target: self, action: #selector(rateSliderChanged(_:)))
        rateSlider.translatesAutoresizingMaskIntoConstraints = false
        rateSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        voiceStack.addArrangedSubview(rateSlider)
        
        let voiceCard = createCard(title: "Jarvis Voice Feedback", iconName: "speaker.wave.2.bubble.left.fill", subview: voiceStack)
        stack.addArrangedSubview(voiceCard)
        
        // --- 2. Workspace Search Path & Insertion Card ---
        let scopingStack = NSStackView()
        scopingStack.orientation = .vertical
        scopingStack.alignment = .leading
        scopingStack.spacing = 10
        scopingStack.translatesAutoresizingMaskIntoConstraints = false
        
        let browseStack = NSStackView()
        browseStack.orientation = .horizontal
        browseStack.spacing = 8
        browseStack.translatesAutoresizingMaskIntoConstraints = false
        
        let workspaceField = createTextField(placeholder: "e.g., ~/projects", value: Self.workspacePath)
        self.workspaceField = workspaceField
        workspaceField.delegate = self
        workspaceField.target = self
        workspaceField.action = #selector(workspaceChanged(_:))
        workspaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        
        let browseBtn = NSButton(title: "Browse…", target: self, action: #selector(browseWorkspacePath(_:)))
        browseBtn.bezelStyle = .rounded
        browseBtn.font = .systemFont(ofSize: 12)
        browseBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        
        browseStack.addArrangedSubview(workspaceField)
        browseStack.addArrangedSubview(browseBtn)
        scopingStack.addArrangedSubview(browseStack)
        
        browseStack.leadingAnchor.constraint(equalTo: scopingStack.leadingAnchor).isActive = true
        browseStack.trailingAnchor.constraint(equalTo: scopingStack.trailingAnchor).isActive = true
        
        let scopingDesc = createDescriptionLabel("The active search path. Sotto searches inside this folder when tagging or pasting code files.")
        scopingStack.addArrangedSubview(scopingDesc)
        
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        scopingStack.addArrangedSubview(divider)
        divider.leadingAnchor.constraint(equalTo: scopingStack.leadingAnchor).isActive = true
        divider.trailingAnchor.constraint(equalTo: scopingStack.trailingAnchor).isActive = true
        
        let insertCheckbox = NSButton(checkboxWithTitle: "Direct Text Insertion", target: self, action: #selector(toggleInsert(_:)))
        insertCheckbox.state = Self.isDirectInsert ? .on : .off
        insertCheckbox.font = .systemFont(ofSize: 12, weight: .medium)
        scopingStack.addArrangedSubview(insertCheckbox)
        
        let insertDesc = createDescriptionLabel("Directly inputs text at active cursor location. If unchecked, Sotto uses simulated Command+V paste (safest for most browsers/apps).")
        scopingStack.addArrangedSubview(insertDesc)
        
        let scopingCard = createCard(title: "Workspace & Text Insertion", iconName: "folder.fill", subview: scopingStack)
        stack.addArrangedSubview(scopingCard)
        
        // --- 3. Custom AI Polish Prompt Card ---
        let promptStack = NSStackView()
        promptStack.orientation = .vertical
        promptStack.alignment = .leading
        promptStack.spacing = 8
        promptStack.translatesAutoresizingMaskIntoConstraints = false
        
        let promptField = createTextField(placeholder: "e.g., Make my text sound highly professional...", value: Self.customSystemPrompt)
        promptField.delegate = self
        promptField.target = self
        promptField.action = #selector(promptChanged(_:))
        promptStack.addArrangedSubview(promptField)
        promptField.leadingAnchor.constraint(equalTo: promptStack.leadingAnchor).isActive = true
        promptField.trailingAnchor.constraint(equalTo: promptStack.trailingAnchor).isActive = true
        
        let promptDesc = createDescriptionLabel("Optional instructions sent to Qwen AI to polish/rewrite your voice dictation (leave empty for default transcription cleaning).")
        promptStack.addArrangedSubview(promptDesc)
        
        let promptCard = createCard(title: "AI Polish Refiner Prompt", iconName: "sparkles", subview: promptStack)
        stack.addArrangedSubview(promptCard)
        
        // --- 4. Custom Vocabulary Card ---
        let vocabStack = NSStackView()
        vocabStack.orientation = .vertical
        vocabStack.alignment = .leading
        vocabStack.spacing = 8
        vocabStack.translatesAutoresizingMaskIntoConstraints = false
        
        let vocabField = createTextField(placeholder: "e.g., Sotto, macOS, Prashant, Xcode", value: Self.customVocabulary)
        vocabField.delegate = self
        vocabField.target = self
        vocabField.action = #selector(vocabChanged(_:))
        vocabStack.addArrangedSubview(vocabField)
        vocabField.leadingAnchor.constraint(equalTo: vocabStack.leadingAnchor).isActive = true
        vocabField.trailingAnchor.constraint(equalTo: vocabStack.trailingAnchor).isActive = true
        
        let vocabDesc = createDescriptionLabel("Comma-separated list of jargon, technical terms, or custom names to help Sotto spell technical vocabulary correctly.")
        vocabStack.addArrangedSubview(vocabDesc)
        
        let vocabCard = createCard(title: "Custom Vocabulary & Jargon", iconName: "text.book.closed.fill", subview: vocabStack)
        stack.addArrangedSubview(vocabCard)
        
        // --- 5. Reset & Data Card ---
        let resetStack = NSStackView()
        resetStack.orientation = .vertical
        resetStack.alignment = .leading
        resetStack.spacing = 8
        resetStack.translatesAutoresizingMaskIntoConstraints = false
        
        let resetBtn = NSButton(title: "Reset Learned Style & Vocabulary Data", target: self, action: #selector(resetLearnedData(_:)))
        resetBtn.bezelStyle = .rounded
        resetBtn.font = .systemFont(ofSize: 12)
        resetStack.addArrangedSubview(resetBtn)
        
        let resetDesc = createDescriptionLabel("Clears style context and customized words dynamically learned from your previous dictation refinement sessions.")
        resetStack.addArrangedSubview(resetDesc)
        
        let resetCard = createCard(title: "Advanced Data Reset", iconName: "gearshape.2.fill", subview: resetStack)
        stack.addArrangedSubview(resetCard)
        
        // Setup card constraints to stretch horizontally to match the stack view
        for card in [hotkeyCard, engineCard, llmCard, agentCard, voiceCard, scopingCard, promptCard, vocabCard, resetCard] {
            card.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 16).isActive = true
            card.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -16).isActive = true
        }
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        self.window = window
    }
    
    private func createCard(title: String, iconName: String, subview: NSView) -> NSView {
        let container = NSBox()
        container.boxType = .custom
        container.cornerRadius = 10
        container.borderWidth = 1
        container.borderColor = NSColor.separatorColor
        container.fillColor = NSColor.controlBackgroundColor
        container.translatesAutoresizingMaskIntoConstraints = false
        
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        
        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 8
        headerStack.alignment = .centerY
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: title) {
            let iv = NSImageView(image: image)
            iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            iv.contentTintColor = NSColor.controlAccentColor
            headerStack.addArrangedSubview(iv)
        }
        
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = NSColor.labelColor
        headerStack.addArrangedSubview(titleLabel)
        
        stack.addArrangedSubview(headerStack)
        stack.addArrangedSubview(subview)
        
        subview.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        subview.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        
        return container
    }
    
    private func createTextField(placeholder: String, value: String) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.stringValue = value
        tf.font = .systemFont(ofSize: 12)
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }
    
    private func createDescriptionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
    
    @objc private func resetLearnedData(_ sender: NSButton) {
        UserDefaults.standard.removeObject(forKey: "sotto_style_examples")
        UserDefaults.standard.removeObject(forKey: "sotto_learned_vocabulary")
        print("[SETTINGS] Reset learned style examples and vocabulary")
        
        let alert = NSAlert()
        alert.messageText = "Reset Complete"
        alert.informativeText = "Learned dictation style examples and custom vocabulary have been cleared."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc private func enginePopUpChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < TranscriptionEngine.allCases.count else { return }
        let selectedEngine = TranscriptionEngine.allCases[index]
        UserDefaults.standard.set(selectedEngine.rawValue, forKey: Self.engineKey)
        print("[SETTINGS] Transcription engine updated: \(selectedEngine.rawValue)")
        onEngineChanged?()
    }
    
    @objc private func toggleAgentMode(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: Self.agentModeKey)
        print("[SETTINGS] AI Agent Mode toggled: \(enabled)")
    }
    
    @objc private func modelChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelIdentifierKey)
        print("[SETTINGS] MLX Qwen model identifier updated: \(sender.stringValue)")
        onEngineChanged?()
    }

    @objc private func toggleVoiceFeedback(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: Self.voiceFeedbackEnabledKey)
        print("[SETTINGS] Voice feedback enabled: \(enabled)")
    }

    @objc private func voicePopUpChanged(_ sender: NSPopUpButton) {
        let excludedKeywords = ["cello", "novelty", "bell", "organ", "zarvox", "bubbles", "hysterical", "whisper", "bad_news", "trinoids", "deranged", "pipe", "reed"]
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let lang = voice.language.lowercased()
            let id = voice.identifier.lowercased()
            let name = voice.name.lowercased()
            let isEnglish = lang.hasPrefix("en")
            let isExcluded = excludedKeywords.contains { kw in id.contains(kw) || name.contains(kw) }
            return isEnglish && !isExcluded
        }
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < englishVoices.count else { return }
        let selectedVoice = englishVoices[index]
        UserDefaults.standard.set(selectedVoice.identifier, forKey: Self.voiceIdentifierKey)
        print("[SETTINGS] Voice identifier updated: \(selectedVoice.identifier)")
    }
    
    @objc private func rateSliderChanged(_ sender: NSSlider) {
        UserDefaults.standard.set(sender.floatValue, forKey: Self.speechRateKey)
        print("[SETTINGS] Speech rate updated: \(sender.floatValue)")
    }
    
    @MainActor @objc private func testVoicePress(_ sender: NSButton) {
        let testText = "System online. Jarvis voice synthesis configured."
        if let sharedController = AppController.shared {
            Task { @MainActor in
                sharedController.speak(testText)
            }
        } else {
            if testSynthesizer.isSpeaking {
                testSynthesizer.stopSpeaking(at: .immediate)
            }
            let utterance = AVSpeechUtterance(string: testText)
            let voiceId = Self.voiceIdentifier
            if let voice = AVSpeechSynthesisVoice(identifier: voiceId) {
                utterance.voice = voice
            } else if let fallbackVoice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US") {
                utterance.voice = fallbackVoice
            }
            utterance.rate = Self.speechRate
            utterance.pitchMultiplier = Self.speechPitch
            testSynthesizer.speak(utterance)
        }
    }
    
    @objc private func togglePTT(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: Self.pttKey)
        print("[SETTINGS] Push-To-Talk toggled: \(enabled)")
    }
    
    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                    print("[SETTINGS] Launch at Login registered successfully")
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                    print("[SETTINGS] Launch at Login unregistered successfully")
                }
            }
        } catch {
            print("[SETTINGS] Failed to modify Launch at Login registration: \(error.localizedDescription)")
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }
    
    @objc private func toggleInsert(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: Self.directInsertKey)
        print("[SETTINGS] Direct Text Insertion toggled: \(enabled)")
    }
    
    @objc private func promptChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue, forKey: Self.systemPromptKey)
        print("[SETTINGS] Custom prompt updated: \(sender.stringValue)")
    }
    
    @objc private func vocabChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue, forKey: Self.vocabularyKey)
        print("[SETTINGS] Custom vocabulary updated: \(sender.stringValue)")
    }
    
    @objc private func workspaceChanged(_ sender: NSTextField) {
        UserDefaults.standard.set(sender.stringValue, forKey: Self.workspacePathKey)
        print("[SETTINGS] Workspace path updated: \(sender.stringValue)")
    }
    
    @objc private func browseWorkspacePath(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: (Self.workspacePath as NSString).expandingTildeInPath)
        
        panel.beginSheetModal(for: window!) { [weak self] response in
            if response == .OK, let url = panel.url {
                let path = url.path
                UserDefaults.standard.set(path, forKey: Self.workspacePathKey)
                self?.workspaceField?.stringValue = path
                print("[SETTINGS] Workspace path updated via folder picker: \(path)")
            }
        }
    }
    
    func controlTextDidChange(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        if textField.placeholderString?.contains("Prompt") == true {
            UserDefaults.standard.set(textField.stringValue, forKey: Self.systemPromptKey)
        } else if textField.placeholderString?.contains("projects") == true {
            UserDefaults.standard.set(textField.stringValue, forKey: Self.workspacePathKey)
        } else if textField.placeholderString?.contains("Qwen") == true || textField.placeholderString?.contains("mlx-community") == true {
            UserDefaults.standard.set(textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.modelIdentifierKey)
        } else {
            UserDefaults.standard.set(textField.stringValue, forKey: Self.vocabularyKey)
        }
    }
}
