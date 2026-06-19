import AppKit

/// Small floating "Listening…" pill near the bottom of the screen while
/// recording/transcribing. Non-activating, so focus stays in the target app.
final class HUDOverlay {
    private var panel: NSPanel?
    private var label: NSTextField?

    func show(_ text: String) {
        if panel == nil { build() }
        label?.stringValue = text
        position()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func build() {
        let size = NSSize(width: 200, height: 40)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        background.layer?.cornerRadius = 12

        let label = NSTextField(labelWithString: "")
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 8, y: 10, width: size.width - 16, height: 20)
        label.autoresizingMask = [.width]
        background.addSubview(label)

        panel.contentView = background
        self.panel = panel
        self.label = label
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
