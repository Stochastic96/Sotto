import AppKit
import SwiftUI

// MARK: - HUD State
//
// The HUD lives at the bottom-center of the screen — never in the way of notifications or menu items.
// It reads the existing text API from AppController and maps prefixes to visual states automatically.
//
// Listening  "●  Listening…"  → animated multicolor Siri-style waveform + pulsing glow mic
// Thinking   "…" / "✨" / "⏳" → rotating Siri-style orb + bouncing gradient dots
// Success    "✓ …"            → glowing green dot + text
// Warning    "⚠️" / "🔋" / "⚡" → glowing amber dot + text
// Info       anything else    → glowing blue/cyan dot + text

enum HUDDisplayState: Equatable {
    case listening
    case thinking(label: String)
    case result(text: String, style: ResultStyle)

    enum ResultStyle: Equatable { case success, warning, info }
}

// MARK: - Observable model bridging AppKit ↔ SwiftUI

@Observable final class HUDViewModel {
    var displayState: HUDDisplayState = .result(text: "", style: .info)
    var visible: Bool = false
    var memoryLedgerText: String = ""
}

// MARK: - SwiftUI Root

struct HUDRootView: View {
    var model: HUDViewModel

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
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
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(Color(NSColor.windowBackgroundColor).opacity(0.72))
                )
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.28), .white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .compositingGroup()
                .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 6)
                Spacer()
            }
            
            if !model.memoryLedgerText.isEmpty {
                Text(model.memoryLedgerText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
                    .padding(.top, 4)
            }
            Spacer()
        }
        .frame(width: 600, height: 140)
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1.0 : 0.94)
        .offset(y: model.visible ? 0 : 15)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.visible)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.displayState)
    }
}

// MARK: - Glow Mic Indicator

struct GlowMic: View {
    @State private var animateGlow = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.38, green: 0.11, blue: 0.81), Color(red: 0.18, green: 0.50, blue: 0.93), Color(red: 0.96, green: 0.23, blue: 0.47)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 12, height: 12)
                .shadow(color: .purple.opacity(0.6), radius: 6)
                .scaleEffect(animateGlow ? 1.25 : 0.95)
                .blur(radius: animateGlow ? 1.5 : 0.2)
            
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.cyan, .purple, .pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 18, height: 18)
                .scaleEffect(animateGlow ? 1.4 : 1.0)
                .opacity(animateGlow ? 0 : 0.8)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                animateGlow = true
            }
        }
    }
}

// MARK: - Waveform

struct Waveform: View {
    @State private var animate = false
    
    private let barHeights: [CGFloat] = [12, 22, 32, 26, 14, 28, 18, 24, 10]
    private let barDelays: [Double]   = [0.0, 0.1, 0.2, 0.15, 0.05, 0.2, 0.1, 0.25, 0.05]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<9, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.18, green: 0.50, blue: 0.93), Color(red: 0.38, green: 0.11, blue: 0.81), Color(red: 0.96, green: 0.23, blue: 0.47)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: animate ? barHeights[i] : 6)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(barDelays[i]),
                        value: animate
                    )
            }
        }
        .frame(height: 36)
        .onAppear { animate = true }
    }
}

// MARK: - Listening: animated waveform

struct ListeningCapsuleContent: View {
    var body: some View {
        HStack(spacing: 14) {
            GlowMic()
            Waveform()
            Text(String(localized: "hud.listening", defaultValue: "Listening", bundle: .module))
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Thinking Orb

struct ThinkingOrb: View {
    @State private var rotate = false
    @State private var pulse = false
    
    var body: some View {
        ZStack {
            // Background blur/glow
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.38, green: 0.11, blue: 0.81).opacity(0.5), Color(red: 0.96, green: 0.23, blue: 0.47).opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 22, height: 22)
                .blur(radius: 4)
                .scaleEffect(pulse ? 1.3 : 0.9)
            
            // Rotating gradient border
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [Color(red: 0.18, green: 0.50, blue: 0.93), Color(red: 0.38, green: 0.11, blue: 0.81), Color(red: 0.96, green: 0.23, blue: 0.47), Color(red: 0.18, green: 0.50, blue: 0.93)],
                        center: .center
                    ),
                    lineWidth: 3
                )
                .frame(width: 20, height: 20)
                .rotationEffect(.degrees(rotate ? 360 : 0))
            
            // Inner core
            Circle()
                .fill(Color(NSColor.windowBackgroundColor))
                .frame(width: 14, height: 14)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                rotate = true
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Thinking: rotating orb + bouncing dots

struct ThinkingCapsuleContent: View {
    let label: String
    @State private var animateDots = false

    var body: some View {
        HStack(spacing: 14) {
            ThinkingOrb()
            
            // Bouncing dots
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.38, green: 0.11, blue: 0.81), Color(red: 0.96, green: 0.23, blue: 0.47)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: 6, height: 6)
                        .offset(y: animateDots ? -5 : 3)
                        .animation(
                            .easeInOut(duration: 0.5)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.15),
                            value: animateDots
                        )
                }
            }
            .onAppear { animateDots = true }

            if !label.isEmpty {
                Text(label)
                    .font(.system(.callout, design: .rounded, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Result: text with status dot

struct ResultCapsuleContent: View {
    let text: String
    let style: HUDDisplayState.ResultStyle

    private var dotColors: [Color] {
        switch style {
        case .success: return [.green, Color(red: 0.2, green: 0.8, blue: 0.4)]
        case .warning: return [Color(red: 1.0, green: 0.6, blue: 0.0), .orange]
        case .info:    return [Color(red: 0.18, green: 0.50, blue: 0.93), .cyan]
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: dotColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: dotColors[0].opacity(0.6), radius: 5)

            Text(text)
                .font(.system(.callout, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340, alignment: .leading)
        }
    }
}

// MARK: - AppKit wrapper (same public API as the original HUDOverlay)

@MainActor
final class HUDOverlay {
    private var panel: NSPanel?
    private let viewModel = HUDViewModel()
    private var hideTask: Task<Void, Never>?

    // ── Public API (unchanged from original) ────────────────────────────────

    func setMemoryLedger(_ text: String) {
        viewModel.memoryLedgerText = text
    }

    func show(_ text: String) {
        hideTask?.cancel(); hideTask = nil
        let newState = classify(text)
        viewModel.displayState = newState
        revealPanel()
        postAccessibilityAnnouncement(for: newState)
    }

    private func postAccessibilityAnnouncement(for state: HUDDisplayState) {
        let message: String
        switch state {
        case .listening:
            message = "Listening"
        case .thinking(let label):
            message = label.isEmpty ? "Jarvis is thinking" : label
        case .result(let text, _):
            message = text
        }
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: message,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
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
        if text.hasPrefix("✨") { return .thinking(label: String(localized: "hud.polishing", defaultValue: "Polishing…", bundle: .module)) }
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
            try? await Task.sleep(for: .milliseconds(380))
            self?.panel?.orderOut(nil)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !(Task.isCancelled) else { return }
            self?.hide()
        }
    }

    // ── Panel construction ───────────────────────────────────────────────────

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: HUDRootView(model: viewModel))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 140),
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
        let pw: CGFloat = 600
        let ph: CGFloat = 140

        // Position at the bottom-center of the screen, floating 50pt above the bottom/dock
        let x = sf.minX + (sf.width - pw) / 2
        let y = sf.minY + 50
        // print("[HUD-DEBUG] Main Screen Frame: \(screen.frame), Visible Frame: \(sf)")
        // print("[HUD-DEBUG] Calculated HUD Frame: x=\(x), y=\(y), w=\(pw), h=\(ph)")
        panel.setFrame(NSRect(x: x, y: y, width: pw, height: ph), display: false)
    }
}
