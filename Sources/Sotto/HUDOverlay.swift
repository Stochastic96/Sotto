import AppKit
import SwiftUI

// MARK: - HUD State
//
// The HUD lives at the bottom-center of the screen — never in the way.
// It reads the existing text API from AppController and maps prefixes
// to visual states automatically, so no call sites need changing.
//
// Listening  "●  Listening…"  → animated waveform bars (blue)
// Thinking   "…" / "✨" / "⏳" → bouncing dots (indigo)
// Success    "✓ …"            → green dot + text
// Warning    "⚠️" / "🔋" / "⚡" → amber/red dot + text
// Info       anything else    → white dot + text

enum HUDDisplayState: Equatable {
    case listening
    case thinking(label: String)
    case result(text: String, style: ResultStyle)

    enum ResultStyle: Equatable { case success, warning, info }
}

// MARK: - Observable model bridging AppKit ↔ SwiftUI

final class HUDViewModel: ObservableObject {
    @Published var displayState: HUDDisplayState = .result(text: "", style: .info)
    @Published var visible: Bool = false
}

// MARK: - SwiftUI Root

struct HUDRootView: View {
    @ObservedObject var model: HUDViewModel

    var body: some View {
        Group {
            switch model.displayState {
            case .listening:
                ListeningCapsuleContent()
            case .thinking(let label):
                ThinkingCapsuleContent(label: label)
            case .result(let text, let style):
                ResultCapsuleContent(text: text, style: style)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 24, x: 0, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: model.displayState)
        .opacity(model.visible ? 1 : 0)
        .offset(y: model.visible ? 0 : 12)
        .animation(.spring(response: 0.32, dampingFraction: 0.75), value: model.visible)
    }
}

// MARK: - Listening: animated waveform bars

struct ListeningCapsuleContent: View {
    @State private var animate = false

    private let barHeights: [CGFloat] = [10, 18, 26, 18, 10, 22, 14]
    private let barDelays: [Double]   = [0.0, 0.1, 0.2, 0.15, 0.05, 0.2, 0.1]

    var body: some View {
        HStack(spacing: 10) {
            // Pulsing mic dot
            Circle()
                .fill(Color.blue)
                .frame(width: 9, height: 9)
                .overlay(
                    Circle()
                        .stroke(Color.blue.opacity(0.35), lineWidth: 4)
                        .scaleEffect(animate ? 2.2 : 1.0)
                        .opacity(animate ? 0 : 0.8)
                )
                .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: animate)

            // Waveform bars
            HStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(
                            LinearGradient(
                                colors: [.blue, Color(red: 0.4, green: 0.6, blue: 1.0)],
                                startPoint: .bottom, endPoint: .top
                            )
                        )
                        .frame(width: 4, height: animate ? barHeights[i] : 5)
                        .animation(
                            .easeInOut(duration: 0.42)
                                .repeatForever(autoreverses: true)
                                .delay(barDelays[i]),
                            value: animate
                        )
                }
            }
            .frame(height: 28)

            Text("Listening")
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .onAppear { animate = true }
        .onDisappear { animate = false }
    }
}

// MARK: - Thinking: bouncing dots

struct ThinkingCapsuleContent: View {
    let label: String
    @State private var animate = false

    var body: some View {
        HStack(spacing: 12) {
            // J avatar
            ZStack {
                Circle()
                    .fill(Color.indigo.opacity(0.15))
                    .frame(width: 30, height: 30)
                Text("J")
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(Color.indigo)
            }

            // Bouncing dots
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.indigo.opacity(0.85))
                        .frame(width: 7, height: 7)
                        .offset(y: animate ? -7 : 5)
                        .animation(
                            .easeInOut(duration: 0.48)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.16),
                            value: animate
                        )
                }
            }

            if !label.isEmpty {
                Text(label)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { animate = true }
        .onDisappear { animate = false }
    }
}

// MARK: - Result: text with status dot

struct ResultCapsuleContent: View {
    let text: String
    let style: HUDDisplayState.ResultStyle

    private var dotColor: Color {
        switch style {
        case .success: return .green
        case .warning: return Color(red: 1.0, green: 0.6, blue: 0.0)
        case .info:    return Color.primary.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            Text(text)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340, alignment: .leading)
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

// MARK: - AppKit wrapper (same public API as the original HUDOverlay)

@MainActor
final class HUDOverlay {
    private var panel: NSPanel?
    private let viewModel = HUDViewModel()
    private var hideTask: Task<Void, Never>?

    // ── Public API (unchanged from original) ────────────────────────────────

    func show(_ text: String) {
        hideTask?.cancel(); hideTask = nil
        viewModel.displayState = classify(text)
        revealPanel()
    }

    func showResult(_ text: String, autoHideAfter seconds: Double = 6) {
        show(text)
        scheduleHide(after: seconds)
    }

    func hide() {
        hideTask?.cancel(); hideTask = nil
        dismissPanel()
    }

    // ── State classification ─────────────────────────────────────────────────

    private func classify(_ text: String) -> HUDDisplayState {
        // Listening
        if text.hasPrefix("●") { return .listening }

        // Thinking
        if text.hasPrefix("…") { return .thinking(label: clean(text)) }
        if text.hasPrefix("✨") { return .thinking(label: "Polishing…") }
        if text.hasPrefix("⏳") { return .thinking(label: clean(text)) }

        // Success
        if text.hasPrefix("✓") || text.hasPrefix("✅") {
            return .result(text: clean(text), style: .success)
        }

        // Warning / alert
        let alertPrefixes = ["⚠️", "⚡", "🔋", "📅", "💡", "📦", "📄", "💿"]
        if alertPrefixes.contains(where: { text.hasPrefix($0) }) {
            return .result(text: text, style: .warning)
        }

        // Default info
        return .result(text: text, style: .info)
    }

    private func clean(_ text: String) -> String {
        // Strip leading emoji/symbol characters and trim
        let stripped = text.drop(while: { !$0.isLetter && !$0.isNumber && $0 != "(" })
        return String(stripped).trimmingCharacters(in: .whitespaces)
    }

    // ── Panel lifecycle ──────────────────────────────────────────────────────

    private func revealPanel() {
        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless()
        viewModel.visible = true
    }

    private func dismissPanel() {
        viewModel.visible = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            self?.panel?.orderOut(nil)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !(Task.isCancelled) else { return }
            self?.hide()
        }
    }

    // ── Panel construction ───────────────────────────────────────────────────

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: HUDRootView(model: viewModel))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // shadow comes from SwiftUI .shadow()
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.visibleFrame
        let pw: CGFloat = 440
        let ph: CGFloat = 60

        // Bottom-center, 80pt above the Dock / visible frame edge
        let x = sf.midX - pw / 2
        let y = sf.minY + 80
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: false)
    }
}
