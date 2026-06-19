import AppKit

/// Shows a prepared prompt in an editable window so the user can fix OCR mistakes
/// before it reaches Claude, then either copy it (paste manually) or hand it to
/// Jarvis to send. The review step is what makes OCR misreads safe.
@MainActor final class PromptReviewWindowController: NSObject {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var onSend: ((String) -> Void)?

    /// - Parameter onSend: called with the (possibly edited) prompt text when the
    ///   user taps "Send to Claude".
    func show(prompt: PreppedPrompt, onSend: @escaping (String) -> Void) {
        self.onSend = onSend
        window?.close()

        let width: CGFloat = 560
        let height: CGFloat = 460
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Review prompt — \(prompt.useCaseLabel)"
        window.isReleasedWhenClosed = false
        window.center()

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let subtitle = NSTextField(labelWithString:
            "Check the prompt — fix any OCR mistakes — then send to Claude or copy it.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSTextView.scrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // scrollableTextView() is documented to vend an NSTextView document view.
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.string = prompt.assembledText
        self.textView = textView

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyTapped))
        copyButton.bezelStyle = .rounded
        let sendButton = NSButton(title: "Send to Claude", target: self, action: #selector(sendTapped))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r" // Return triggers send

        let buttons = NSStackView(views: [copyButton, sendButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(subtitle)
        container.addSubview(scrollView)
        container.addSubview(buttons)

        NSLayoutConstraint.activate([
            subtitle.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func sendTapped() {
        let text = textView?.string ?? ""
        window?.close()
        window = nil
        onSend?(text)
    }

    @objc private func copyTapped() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView?.string ?? "", forType: .string)
    }
}
