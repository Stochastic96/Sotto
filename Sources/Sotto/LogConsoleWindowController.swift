import AppKit

/// In-app live log console — the "click the menu bar → see what Jarvis is doing" window.
/// Loads `sotto.log` and tails it in real time (the app writes to that file unbuffered), so
/// every `[COORDINATOR]`/`[TOOL]`/`[MEMORY]`/… line appears as it happens.
@MainActor final class LogConsoleWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var tailingTask: Task<Void, Never>?
    private var fileOffset: UInt64 = 0

    private var logURL: URL { SettingsController.sottoLogURL }

    func show() {
        if window == nil { build() }
        loadInitial()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startTailing()
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        w.title = "Sotto Console"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.center()
        w.delegate = self

        // Material backdrop so the console matches the rest of the app's glass look.
        let backdrop = NSVisualEffectView(frame: w.contentView!.bounds)
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(backdrop)

        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.autoresizingMask = [.width]
        scroll.documentView = tv

        w.contentView?.addSubview(scroll)
        self.window = w
        self.textView = tv
    }

    private func loadInitial() {
        let data = (try? Data(contentsOf: logURL)) ?? Data()
        fileOffset = UInt64(data.count)
        textView?.string = String(data: data, encoding: .utf8) ?? ""
        scrollToBottom()
    }

    private func startTailing() {
        tailingTask?.cancel()
        tailingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let tv = textView, let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size <= fileOffset { return }            // nothing new (or file rotated)
        try? handle.seek(toOffset: fileOffset)
        let newData = handle.readDataToEndOfFile()
        fileOffset = size
        guard let chunk = String(data: newData, encoding: .utf8), !chunk.isEmpty else { return }
        tv.textStorage?.append(NSAttributedString(
            string: chunk,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.textColor]))
        scrollToBottom()
    }

    private func scrollToBottom() {
        textView?.scrollToEndOfDocument(nil)
    }

    func windowWillClose(_ notification: Notification) {
        tailingTask?.cancel()
        tailingTask = nil
    }
}
