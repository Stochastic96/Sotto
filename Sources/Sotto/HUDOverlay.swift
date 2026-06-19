import AppKit

/// A glassy card that drops down from the top-center of the screen — the same
/// "liquid glass" material macOS uses for Spotlight and Apple Intelligence
/// (`NSVisualEffectView`). Non-activating, so focus stays in the user's app.
///
/// Jarvis shows detail HERE — instantly, GPU-composited, no OCR, no runtime cost —
/// and only *speaks* a one-line headline, so you read the rest on screen instead of
/// waiting for it to be read aloud.
@MainActor
final class HUDOverlay {
    private var panel: NSPanel?
    private var effect: NSVisualEffectView?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    private let cardWidth: CGFloat = 380
    private let pad: CGFloat = 18

    /// Transient status line (e.g. "Listening…") — stays until replaced or hidden.
    func show(_ text: String) { present(text, autoHideAfter: nil) }

    /// A result card that auto-dismisses after `seconds`.
    func showResult(_ text: String, autoHideAfter seconds: Double = 6) {
        present(text, autoHideAfter: seconds)
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            var f = panel.frame; f.origin.y += 26
            panel.animator().setFrame(f, display: true)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            panel.orderOut(nil)
        }
    }

    private func present(_ text: String, autoHideAfter seconds: Double?) {
        if panel == nil { build() }
        guard let panel, let label, let effect, let screen = NSScreen.main else { return }
        hideWork?.cancel(); hideWork = nil

        label.stringValue = text

        // Size the card to its content.
        let textWidth = cardWidth - pad * 2
        let textHeight = ceil((text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: label.font as Any]).height)
        let size = NSSize(width: cardWidth, height: textHeight + pad * 2)

        effect.frame = NSRect(origin: .zero, size: size)
        label.frame = NSRect(x: pad, y: pad, width: textWidth, height: textHeight)

        // Drop-down: start a touch higher and transparent, then spring down into place.
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let finalY = frame.maxY - size.height - 12
        panel.setFrame(NSRect(x: x, y: finalY + 26, width: size.width, height: size.height), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(x: x, y: finalY, width: size.width, height: size.height), display: true)
        }

        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func build() {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow          // the macOS "liquid glass" blur
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        let label = NSTextField(wrappingLabelWithString: "")
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .left
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBordered = false
        effect.addSubview(label)

        panel.contentView = effect
        self.panel = panel; self.effect = effect; self.label = label
    }
}
