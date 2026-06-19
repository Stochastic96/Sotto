import AppKit

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let transcriptMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let qwenStatusMenuItem = NSMenuItem(title: "Qwen: not loaded", action: nil, keyEquivalent: "")
    private let polishMenuItem: NSMenuItem
    private let dictateMenuItem: NSMenuItem
    private var polishToggleHandler: ((Bool) -> Void)?
    private var dictateHandler: (() -> Void)?
    private var settingsHandler: (() -> Void)?

    private var history: [String] = []
    private let historyMenu = NSMenu()
    private let historyMenuItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")

    var lastTranscript: String = "" {
        didSet {
            let preview = lastTranscript.prefix(60)
            transcriptMenuItem.title = "Last: \(preview)\(lastTranscript.count > 60 ? "…" : "")"
            transcriptMenuItem.toolTip = "Click to copy full transcript to clipboard"
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

    var qwenStatus: String = "" {
        didSet { qwenStatusMenuItem.title = "Qwen: \(qwenStatus)" }
    }

    init(polishEnabled: Bool) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        polishMenuItem = NSMenuItem(title: "AI Polish (Qwen)", action: nil, keyEquivalent: "")
        dictateMenuItem = NSMenuItem(title: "🎤 Start Dictation", action: #selector(startDictate), keyEquivalent: "d")
        super.init()

        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Sotto")

        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        transcriptMenuItem.isEnabled = true
        transcriptMenuItem.target = self
        transcriptMenuItem.action = #selector(copyLastTranscript)
        transcriptMenuItem.isHidden = true
        menu.addItem(transcriptMenuItem)

        historyMenuItem.submenu = historyMenu
        historyMenuItem.isHidden = true
        menu.addItem(historyMenuItem)
        menu.addItem(.separator())



        dictateMenuItem.target = self
        menu.addItem(dictateMenuItem)
        menu.addItem(.separator())

        polishMenuItem.target = self
        polishMenuItem.action = #selector(togglePolish(_:))
        polishMenuItem.state = polishEnabled ? .on : .off
        menu.addItem(polishMenuItem)

        qwenStatusMenuItem.isEnabled = false
        menu.addItem(qwenStatusMenuItem)
        menu.addItem(.separator())

        // Settings Menu Item
        let settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        let logMenuItem = NSMenuItem(title: "Open Log File", action: #selector(openLogFile), keyEquivalent: "")
        logMenuItem.target = self
        menu.addItem(logMenuItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        qwenStatus = "not loaded (loads on first use)"
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

    @objc private func openLogFile(_ sender: NSMenuItem) {
        let logPath = "/Users/prashantsharma/Projects/Sotto/sotto.log"
        let url = URL(fileURLWithPath: logPath)
        NSWorkspace.shared.open(url)
    }

    func update(for state: AppController.State) {
        switch state {
        case .loadingModel:
            set(icon: "arrow.down.circle", text: "Loading model… (first run downloads ~600 MB)")
        case .idle:
            set(icon: "mic", text: "Ready")
        case .recording:
            set(icon: "mic.fill", text: "Listening…")
        case .transcribing:
            set(icon: "waveform", text: "Transcribing…")
        case .polishing:
            set(icon: "sparkles", text: "Polishing with Qwen…")
        case .error(let message):
            set(icon: "exclamationmark.triangle", text: message)
        }
    }

    private func set(icon: String, text: String) {
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: "Sotto")
        item.button?.image = image
        statusMenuItem.title = text

        if #available(macOS 14.0, *) {
            let imageView = item.button?.subviews.compactMap { $0 as? NSImageView }.first
            imageView?.removeAllSymbolEffects()
            if icon == "mic.fill" || icon == "waveform" || icon == "sparkles" {
                imageView?.addSymbolEffect(.pulse, options: .repeating)
            }
        }
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
