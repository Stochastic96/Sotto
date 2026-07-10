import AppKit

// MARK: - StatusBarController

@MainActor final class StatusBarController: NSObject {
    private var item: NSStatusItem?
    private var lastState: AppController.State?
    private let statusMenuItem = NSMenuItem(title: String(localized: "menu.starting", defaultValue: "Starting…", bundle: .module), action: nil, keyEquivalent: "")
    private let transcriptMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let intelligenceStatusMenuItem = NSMenuItem(title: "Apple Intelligence: ready", action: nil, keyEquivalent: "")
    private let polishMenuItem: NSMenuItem
    private let dictateMenuItem: NSMenuItem
    private var polishToggleHandler: ((Bool) -> Void)?
    private var dictateHandler: (() -> Void)?
    private var settingsHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private let cancelMenuItem: NSMenuItem

    private var history: [String] = []
    private let historyMenu = NSMenu()
    private let historyMenuItem = NSMenuItem(title: String(localized: "menu.recentTranscripts", defaultValue: "Recent Transcripts", bundle: .module), action: nil, keyEquivalent: "")

    var lastTranscript: String = "" {
        didSet {
            let preview = lastTranscript.prefix(60)
            let lastPrefix = String(localized: "status.lastTranscriptPrefix", defaultValue: "Last:", bundle: .module)
            transcriptMenuItem.title = "\(lastPrefix) \(preview)\(lastTranscript.count > 60 ? "…" : "")"
            transcriptMenuItem.toolTip = String(localized: "menu.copyTooltip", defaultValue: "Click to copy full transcript to clipboard", bundle: .module)
            transcriptMenuItem.isHidden = lastTranscript.isEmpty

            if !lastTranscript.isEmpty {
                if history.isEmpty || history.first != lastTranscript {
                    history.insert(lastTranscript, at: 0)
                    if history.count > 5 {
                        history.removeLast()
                    }
                    rebuildHistoryMenu()
                }
            }
        }
    }

    var intelligenceStatus: String = "" {
        didSet {
            let prefix = String(localized: "status.appleIntelligencePrefix", defaultValue: "Apple Intelligence:", bundle: .module)
            intelligenceStatusMenuItem.title = "\(prefix) \(intelligenceStatus)"
        }
    }

    init(polishEnabled: Bool) {
        polishMenuItem = NSMenuItem(title: String(localized: "menu.aiPolish", defaultValue: "AI Polish", bundle: .module), action: nil, keyEquivalent: "")
        dictateMenuItem = NSMenuItem(title: String(localized: "menu.startDictation", defaultValue: "Start Dictation", bundle: .module), action: #selector(startDictate), keyEquivalent: "d")
        cancelMenuItem = NSMenuItem(title: String(localized: "menu.cancel", defaultValue: "Cancel / Reset", bundle: .module), action: #selector(cancelSession), keyEquivalent: ".")
        cancelMenuItem.keyEquivalentModifierMask = [.command]
        super.init()

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let glyph = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sotto")?
            .withSymbolConfiguration(cfg)
        glyph?.isTemplate = true
        statusItem.button?.image = glyph

        let menu = NSMenu()
        self.statusMenuItem.isEnabled = false
        menu.addItem(self.statusMenuItem)
        self.transcriptMenuItem.isEnabled = true
        self.transcriptMenuItem.target = self
        self.transcriptMenuItem.action = #selector(self.copyLastTranscript)
        self.transcriptMenuItem.isHidden = true
        menu.addItem(self.transcriptMenuItem)

        self.historyMenuItem.submenu = self.historyMenu
        self.historyMenuItem.isHidden = true
        menu.addItem(self.historyMenuItem)
        menu.addItem(.separator())

        self.dictateMenuItem.target = self
        menu.addItem(self.dictateMenuItem)

        // Always-available abort for a stuck/unwanted session. Enabled only while
        // something is in flight (see update(for:)).
        self.cancelMenuItem.target = self
        self.cancelMenuItem.isEnabled = false
        menu.addItem(self.cancelMenuItem)
        menu.addItem(.separator())

        self.polishMenuItem.target = self
        self.polishMenuItem.action = #selector(self.togglePolish(_:))
        self.polishMenuItem.state = polishEnabled ? .on : .off
        menu.addItem(self.polishMenuItem)

        self.intelligenceStatusMenuItem.isEnabled = false
        menu.addItem(self.intelligenceStatusMenuItem)
        menu.addItem(.separator())

        // Settings Menu Item
        let settingsMenuItem = NSMenuItem(title: String(localized: "menu.settings", defaultValue: "Settings…", bundle: .module), action: #selector(self.openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        // Jarvis Help & Guide Menu Item
        let guideMenuItem = NSMenuItem(title: String(localized: "menu.jarvisHelp", defaultValue: "Jarvis Help & Guide…", bundle: .module), action: #selector(self.openGuide), keyEquivalent: "?")
        guideMenuItem.target = self
        menu.addItem(guideMenuItem)

        let consoleMenuItem = NSMenuItem(title: String(localized: "menu.showConsole", defaultValue: "Show Console", bundle: .module), action: #selector(self.showConsole), keyEquivalent: "l")
        consoleMenuItem.target = self
        menu.addItem(consoleMenuItem)

        let logMenuItem = NSMenuItem(title: String(localized: "menu.openLog", defaultValue: "Open Log File", bundle: .module), action: #selector(self.openLogFile), keyEquivalent: "")
        logMenuItem.target = self
        menu.addItem(logMenuItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: String(localized: "menu.quit", defaultValue: "Quit Sotto", bundle: .module), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
        self.item = statusItem

        // Re-apply latest state once registered
        if let lastState = self.lastState {
            self.update(for: lastState)
        }
        intelligenceStatus = "ready"
    }

    func onPolishToggle(_ handler: @escaping (Bool) -> Void) {
        polishToggleHandler = handler
    }

    func onDictate(_ handler: @escaping () -> Void) {
        dictateHandler = handler
    }

    func onSettings(_ handler: @escaping () -> Void) {
        settingsHandler = handler
    }

    func onCancel(_ handler: @escaping () -> Void) {
        cancelHandler = handler
    }

    @objc private func cancelSession(_ sender: NSMenuItem) {
        cancelHandler?()
    }

    @objc private func startDictate(_ sender: NSMenuItem) {
        dictateHandler?()
    }

    @objc private func togglePolish(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        polishToggleHandler?(sender.state == .on)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        settingsHandler?()
    }

    @objc private func openGuide(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: NSNotification.Name("SottoOpenGuide"), object: nil)
    }

    private let console = LogConsoleWindowController()

    @objc private func showConsole(_ sender: NSMenuItem) {
        console.show()
    }

    @objc private func openLogFile(_ sender: NSMenuItem) {
        let url = SettingsController.sottoLogURL
        NSWorkspace.shared.open(url)
    }

    func update(for state: AppController.State) {
        lastState = state
        guard self.item != nil else { return }
        // "Cancel / Reset" is meaningful only while a session is in flight.
        switch state {
        case .recording, .transcribing, .polishing: cancelMenuItem.isEnabled = true
        default: cancelMenuItem.isEnabled = false
        }
        let accent = SottoDesign.Accent.nsColors(for: .jarvis)
        switch state {
        case .loadingModel:
            set(tint: nil, text: String(localized: "status.loadingModel", defaultValue: "Loading model… (first run downloads ~600 MB)", bundle: .module), dimmed: true)
        case .idle:
            set(tint: nil, text: String(localized: "status.ready", defaultValue: "Ready", bundle: .module))
        case .recording:
            set(tint: accent[1], text: String(localized: "status.listening", defaultValue: "Listening…", bundle: .module))
        case .transcribing:
            set(tint: accent[0], text: String(localized: "status.transcribing", defaultValue: "Transcribing…", bundle: .module))
        case .polishing:
            set(tint: accent[0], text: String(localized: "status.polishing", defaultValue: "Polishing…", bundle: .module))
        case .error(let message):
            set(tint: .systemRed, text: message)
        }
    }

    /// One clean template glyph, always the same symbol — state shows through
    /// tint only (no badge variants, no icon swapping). Template rendering
    /// keeps it native in light, dark, and tinted menu bars.
    private func set(tint: NSColor?, text: String, dimmed: Bool = false) {
        guard let item = self.item else { return }
        if item.button?.image == nil {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sotto")?
                .withSymbolConfiguration(cfg)
            image?.isTemplate = true
            item.button?.title = ""
            item.button?.image = image
        }
        item.button?.contentTintColor = tint
        item.button?.appearsDisabled = dimmed
        statusMenuItem.title = text
    }

    private func rebuildHistoryMenu() {
        historyMenu.removeAllItems()
        historyMenuItem.isHidden = history.isEmpty

        for (index, text) in history.enumerated() {
            let cleanText = text.replacingOccurrences(of: "\n", with: " ")
            let preview = cleanText.prefix(45)
            let title = "\(index + 1): \(preview)\(text.count > 45 ? "…" : "")"
            let item = NSMenuItem(title: title, action: #selector(historyItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = text
            historyMenu.addItem(item)
        }
    }

    @objc private func historyItemClicked(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            NSSound(named: "Tink")?.play()
        }
    }

    @objc private func copyLastTranscript(_ sender: NSMenuItem) {
        if !lastTranscript.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lastTranscript, forType: .string)
            NSSound(named: "Tink")?.play()
        }
    }


}
