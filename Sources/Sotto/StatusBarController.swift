import AppKit

// MARK: - Floating Sotto indicator pill

/// Permanent floating pill anchored just below the menu bar, right side.
/// Uses NSVisualEffectView (system material) so it looks native on light and dark.
/// Draggable — position is remembered across launches.
/// Click → same NSMenu as the status item (Quit, Settings, etc.)
@MainActor
final class MenuBarPill: NSObject {
    private var panel: NSPanel?
    private weak var sharedMenu: NSMenu?
    private var iconButton: NSButton?
    private let positionKey = "SottoPillOrigin"

    func show(attachedTo menu: NSMenu) {
        sharedMenu = menu
        guard panel == nil else { panel?.orderFrontRegardless(); return }
        buildPanel()
    }

    func update(icon: String, label: String = "") {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let description = label.isEmpty ? "Sotto" : "Sotto — \(label)"
        iconButton?.image = NSImage(systemSymbolName: icon, accessibilityDescription: description)?
            .withSymbolConfiguration(cfg)
    }

    private func buildPanel() {
        let w: CGFloat = 36, h: CGFloat = 26
        let origin = defaultOrSaved(w: w, h: h)

        let p = NSPanel(
            contentRect: NSRect(x: origin.x, y: origin.y, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar          // level 25: above all app windows, below system chrome
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Material background — adapts to light/dark automatically
        let vfx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        vfx.material = .hudWindow
        vfx.blendingMode = .behindWindow
        vfx.state = .active
        vfx.wantsLayer = true
        vfx.layer?.cornerRadius = h / 2
        vfx.layer?.masksToBounds = true

        // Icon button — NSButton renders SF Symbols correctly; no custom draw needed
        let btn = NSButton(frame: vfx.bounds)
        btn.isBordered = false
        btn.title = ""
        btn.imageScaling = .scaleProportionallyDown
        btn.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        btn.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sotto")?
            .withSymbolConfiguration(cfg)
        btn.contentTintColor = .white
        btn.target = self
        btn.action = #selector(pillTapped(_:))
        btn.autoresizingMask = [.width, .height]
        vfx.addSubview(btn)

        p.contentView = vfx
        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: p)

        p.orderFrontRegardless()
        panel = p
        iconButton = btn
    }

    @objc private func pillTapped(_ sender: NSButton) {
        guard let sharedMenu, let p = panel else { return }
        // Pop menu upward from the pill
        sharedMenu.popUp(positioning: nil,
                         at: NSPoint(x: 0, y: p.frame.height + 4),
                         in: p.contentView)
    }

    @objc private func didMove() {
        guard let o = panel?.frame.origin else { return }
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: positionKey)
    }

    private func defaultOrSaved(w: CGFloat, h: CGFloat) -> NSPoint {
        if let arr = UserDefaults.standard.array(forKey: positionKey) as? [Double], arr.count == 2 {
            return NSPoint(x: arr[0], y: arr[1])
        }
        guard let screen = NSScreen.main else { return .zero }
        // Place just below the menu bar, near the right edge
        let menuBarH = CGFloat(NSApplication.shared.mainMenu?.menuBarHeight ?? 24)
        return NSPoint(x: screen.frame.maxX - w - 8,
                       y: screen.frame.maxY - menuBarH - h - 4)
    }
}

// MARK: - StatusBarController

@MainActor final class StatusBarController: NSObject, NSMenuDelegate {
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

    // Guaranteed-visible fallback pill (shown when NSStatusItem is hidden by overflow)
    private let pill = MenuBarPill()

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
        dictateMenuItem = NSMenuItem(title: String(localized: "menu.startDictation", defaultValue: "🎤 Start Dictation", bundle: .module), action: #selector(startDictate), keyEquivalent: "d")
        super.init()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = nil
            statusItem.button?.title = "J"
            statusItem.button?.font = .systemFont(ofSize: 14, weight: .bold)

            let menu = NSMenu()
            menu.delegate = self
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

            print("[STATUSBAR-DEBUG] Created item: \(statusItem)")
            print("[STATUSBAR-DEBUG] Item button: \(String(describing: statusItem.button))")
            print("[STATUSBAR-DEBUG] Item button frame: \(String(describing: statusItem.button?.frame))")
            print("[STATUSBAR-DEBUG] Item button window: \(String(describing: statusItem.button?.window))")
            print("[STATUSBAR-DEBUG] Item button window isVisible: \(String(describing: statusItem.button?.window?.isVisible))")

            // Re-apply latest state once registered
            if let lastState = self.lastState {
                self.update(for: lastState)
            }
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
        guard let _ = self.item else { return }
        switch state {
        case .loadingModel:
            set(title: "J", text: String(localized: "status.loadingModel", defaultValue: "Loading model… (first run downloads ~600 MB)", bundle: .module))
        case .idle:
            set(title: "J", text: String(localized: "status.ready", defaultValue: "Ready", bundle: .module))
        case .recording:
            set(title: "J", text: String(localized: "status.listening", defaultValue: "Listening…", bundle: .module))
        case .transcribing:
            set(title: "J", text: String(localized: "status.transcribing", defaultValue: "Transcribing…", bundle: .module))
        case .polishing:
            set(title: "J", text: String(localized: "status.polishing", defaultValue: "Polishing…", bundle: .module))
        case .error(let message):
            set(title: "J", text: message)
        }
    }

    private func set(title: String, text: String) {
        guard let item = self.item else { return }
        item.button?.image = nil
        item.button?.title = title
        item.button?.font = .systemFont(ofSize: 14, weight: .bold)
        statusMenuItem.title = text
        // pill.update(icon: "sparkles", label: text)
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
