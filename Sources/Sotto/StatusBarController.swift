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
        iconButton?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "Sotto")?
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
    private let item: NSStatusItem
    private let statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
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

    var intelligenceStatus: String = "" {
        didSet { intelligenceStatusMenuItem.title = "Apple Intelligence: \(intelligenceStatus)" }
    }

    init(polishEnabled: Bool) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        polishMenuItem = NSMenuItem(title: "AI Polish", action: nil, keyEquivalent: "")
        dictateMenuItem = NSMenuItem(title: "🎤 Start Dictation", action: #selector(startDictate), keyEquivalent: "d")
        super.init()

        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sotto / Jarvis")
        item.button?.image?.isTemplate = true

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

        intelligenceStatusMenuItem.isEnabled = false
        menu.addItem(intelligenceStatusMenuItem)
        menu.addItem(.separator())

        // Settings Menu Item
        let settingsMenuItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsMenuItem.target = self
        menu.addItem(settingsMenuItem)

        // Jarvis Help & Guide Menu Item
        let guideMenuItem = NSMenuItem(title: "Jarvis Help & Guide…", action: #selector(openGuide), keyEquivalent: "?")
        guideMenuItem.target = self
        menu.addItem(guideMenuItem)

        let consoleMenuItem = NSMenuItem(title: "Show Console", action: #selector(showConsole), keyEquivalent: "l")
        consoleMenuItem.target = self
        menu.addItem(consoleMenuItem)

        let logMenuItem = NSMenuItem(title: "Open Log File", action: #selector(openLogFile), keyEquivalent: "")
        logMenuItem.target = self
        menu.addItem(logMenuItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Sotto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        intelligenceStatus = "ready"

        // Always show the floating pill so Sotto is visible regardless of menu bar space.
        // It shares the same NSMenu, so clicking it gives the same Quit / Settings / etc.
        pill.show(attachedTo: menu)
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
            set(icon: "sparkles", text: "Polishing…")
        case .error(let message):
            set(icon: "exclamationmark.triangle", text: message)
        }
    }

    private func set(icon: String, text: String) {
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: "Sotto")
        image?.isTemplate = true
        item.button?.image = image
        statusMenuItem.title = text
        pill.update(icon: icon, label: "")

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
