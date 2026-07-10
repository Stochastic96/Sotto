import AppKit
import SwiftUI

// MARK: - Sotto HUD
//
// A single, professional, icon-free overlay that reads as system-level Apple
// Intelligence — not a third-party badge. It lives at the bottom-center of the
// active screen and never uses emoji or SF Symbols: state is conveyed through
// typography, a live audio waveform, an indeterminate activity line, and a
// restrained Siri-style gradient accent.
//
// Three phases only:
//   • listening — live waveform driven by real microphone level
//   • thinking  — minimal indeterminate activity line
//   • result    — one or two lines of text with an optional status accent
//
// Real-time contract
// -------------------
// The SwiftUI front end observes `HUDModel`. Structural changes (phase, title,
// detail, tint) are the ONLY things that drive the resize/transition spring.
// High-frequency signals — audio `levels` and the streaming `caption` — live in
// separate observable fields, so pushing them at 15 fps never triggers layout
// animation churn. Callers drive everything through the typed `present`,
// `updateLevel`, and `updateCaption` API; a compatibility shim keeps the older
// string-based call sites working (and strips any decoration they still pass).

// Palette, motion, and metric tokens live in SottoDesign.swift, shared with
// every other visible surface.

// MARK: - Observable model (the real-time channel)

@Observable final class HUDModel {
    enum Phase: Equatable { case listening, thinking, result }
    enum Tint: Equatable { case neutral, success, warning, accent }

    // Structural — changes here drive the resize/transition spring.
    var phase: Phase = .result
    var mode: SottoDesign.Mode = .dictation
    var title: String = ""
    var detail: String = ""
    var tint: Tint = .neutral
    var visible = false

    // High-frequency — updated up to ~15 fps, deliberately NOT in any animation key.
    var levels: [CGFloat] = Array(repeating: 0, count: SottoDesign.Metrics.barCount)
    var caption: String = ""
    /// Smoothed voice level for the Jarvis orb (same contract as `levels`).
    var orbEnergy: CGFloat = 0

    // Debug-only footnote (memory ledger). Empty in normal use.
    var footnote: String = ""

    /// Shift a new normalized level (0...1) into the rolling waveform buffer.
    func pushLevel(_ value: CGFloat) {
        var next = levels
        next.removeFirst()
        next.append(min(1, max(0, value)))
        levels = next
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: SottoDesign.Metrics.barCount)
    }
}

// MARK: - SwiftUI root

struct HUDRootView: View {
    var model: HUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            if model.visible {
                capsule
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .bottom))
                    ))

                if !model.footnote.isEmpty {
                    Text(model.footnote)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: 660, height: 220)
        .animation(SottoDesign.Motion.structural(reduceMotion: reduceMotion),
                   value: model.visible)
        .animation(SottoDesign.Motion.phase(reduceMotion: reduceMotion),
                   value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.title)
    }

    // The one container, sized to its content.
    private var capsule: some View {
        HStack(spacing: 14) {
            content
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SottoDesign.Metrics.corner, style: .continuous))
        .overlay(borderOverlay)
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .shadow(color: glowColor.opacity(isActive ? 0.28 : 0), radius: 22, y: 0)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            if model.mode == .jarvis {
                JarvisListeningView(energy: model.orbEnergy, caption: model.caption)
            } else {
                ListeningView(levels: model.levels, caption: model.caption,
                              accent: SottoDesign.Accent.dictation)
            }
        case .thinking:
            ThinkingView(title: model.title, detail: model.caption,
                         reduceMotion: reduceMotion, accent: accent)
        case .result:
            ResultView(title: model.title, detail: model.detail, tint: model.tint,
                       shimmer: model.mode == .jarvis && model.tint != .warning && !reduceMotion,
                       accent: accent)
        }
    }

    private var isActive: Bool { model.phase != .result }

    private var accent: [Color] { SottoDesign.Accent.colors(for: model.mode) }

    private var glowColor: Color { accent[1] }

    // Gradient rim while active (Apple-Intelligence signature); thin neutral rim at rest.
    @ViewBuilder
    private var borderOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: SottoDesign.Metrics.corner, style: .continuous)
        if isActive {
            shape.strokeBorder(
                AngularGradient(colors: accent, center: .center),
                lineWidth: 1.2
            )
            .opacity(0.9)
        } else {
            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.26), .white.opacity(0.10)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
        }
    }
}

// MARK: - Listening: quiet waveform (dictation) / breathing orb (Jarvis)

private struct ListeningView: View {
    let levels: [CGFloat]
    let caption: String
    let accent: [Color]

    var body: some View {
        HStack(spacing: 12) {
            Waveform(levels: levels, accent: accent)
            ListeningLabel(caption: caption)
        }
    }
}

private struct JarvisListeningView: View {
    let energy: CGFloat
    let caption: String

    var body: some View {
        HStack(spacing: 12) {
            OrbView(energy: energy)
            ListeningLabel(caption: caption)
        }
    }
}

private struct ListeningLabel: View {
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "hud.listening", defaultValue: "Listening", bundle: .module))
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(.primary)
            if !caption.isEmpty {
                Text(caption)
                    .font(.system(.footnote))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let accent: [Color]

    private let minBar: CGFloat = 3
    private let maxBar: CGFloat = 26

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(
                        LinearGradient(colors: [accent[0], accent[1], accent[2]],
                                       startPoint: .bottom, endPoint: .top)
                    )
                    .frame(width: 3, height: minBar + level * (maxBar - minBar))
            }
        }
        .frame(height: maxBar, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: levels)
        .accessibilityHidden(true)
    }
}

// MARK: - Thinking: indeterminate activity line

private struct ThinkingView: View {
    let title: String
    let detail: String
    let reduceMotion: Bool
    let accent: [Color]
    @State private var animate = false

    var body: some View {
        HStack(spacing: 12) {
            ActivityLine(animate: animate && !reduceMotion, accent: accent)
                .frame(width: 88, height: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? String(localized: "hud.working", defaultValue: "Working", bundle: .module) : title)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.primary)
                if !detail.isEmpty {
                    // Live progress detail (e.g. streaming polish preview) —
                    // fed through the high-frequency caption channel, display only.
                    Text(detail)
                        .font(.system(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }
        }
        .onAppear { animate = true }
    }
}

private struct ActivityLine: View {
    let animate: Bool
    let accent: [Color]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * 0.42)
                        .offset(x: animate ? w * 0.58 : -w * 0.42)
                        .animation(animate ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                                   value: animate)
                }
                .clipShape(Capsule())
        }
    }
}

// MARK: - Result: text with optional status accent

private struct ResultView: View {
    let title: String
    let detail: String
    let tint: HUDModel.Tint
    let shimmer: Bool
    let accent: [Color]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if tint != .neutral {
                Capsule()
                    .fill(SottoDesign.tintColor(tint))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(shimmer ? 5 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(ShimmerSweep(enabled: shimmer, accent: accent))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(.footnote))
                        .foregroundStyle(.secondary)
                        .lineLimit(shimmer ? 5 : 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: shimmer ? 500 : 460, alignment: .leading)
        }
        .frame(maxHeight: 140)
    }
}

/// One-shot Writing-Tools-style gradient sweep across freshly arrived Jarvis
/// text. Runs exactly once per appearance (~0.9 s) — never repeatForever, so
/// there is no sustained GPU cost. Skipped entirely under Reduce Motion (the
/// caller passes `enabled: false`).
private struct ShimmerSweep: ViewModifier {
    let enabled: Bool
    let accent: [Color]
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        if enabled {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, accent[1].opacity(0.85), accent[2].opacity(0.85), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 0.9)) { phase = 1.2 }
                }
        } else {
            content
        }
    }
}

// MARK: - AppKit controller

@MainActor
final class HUDOverlay {

    // Typed intent — the modern, emoji-free API.
    enum Intent: Equatable {
        case listening
        case thinking(String)
        /// Ongoing multi-step work with a live detail line ("Reading your screen").
        case progress(String, detail: String = "")
        /// A question Jarvis is waiting on; styled with the accent bar and an
        /// answer hint, announced to VoiceOver as a question.
        case clarify(String)
        /// A conversational Jarvis reply; gets the one-shot shimmer treatment.
        case reply(String)
        case success(String, detail: String = "")
        case warning(String, detail: String = "")
        case info(String, detail: String = "")
    }

    private var panel: NSPanel?
    private let model = HUDModel()
    private let edgeGlow = EdgeGlowOverlay()
    private var hideTask: Task<Void, Never>?
    private var lastAnnouncement = ""
    // Set once in ensurePanel(); read only to unregister in the nonisolated deinit.
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    // MARK: Typed API

    /// `mode` selects the visual personality (dictation waveform vs Jarvis orb
    /// and gradient). `nil` keeps the current mode, so call sites that don't
    /// know the mode stay source-compatible; AppController sets it explicitly
    /// at session start and on dictation→Jarvis delegation.
    func present(_ intent: Intent, mode: SottoDesign.Mode? = nil, dismissAfter seconds: Double? = nil) {
        hideTask?.cancel(); hideTask = nil

        if let mode, mode != model.mode {
            model.mode = mode
            lastAnnouncement = ""   // personality switch: let VoiceOver re-announce
        }

        switch intent {
        case .listening:
            if model.phase != .listening { model.resetLevels(); model.orbEnergy = 0 }
            model.phase = .listening
            model.caption = ""
        case .thinking(let label):
            model.phase = .thinking
            model.title = label
            model.caption = ""
        case .progress(let label, let detail):
            model.phase = .thinking
            model.title = label
            model.caption = detail
        case .clarify(let question):
            model.phase = .result; model.tint = .accent; model.title = question
            model.detail = String(localized: "hud.clarifyHint",
                                  defaultValue: "Press ⌘⇧J to answer", bundle: .module)
        case .reply(let text):
            model.phase = .result; model.tint = .neutral; model.title = text; model.detail = ""
        case .success(let t, let d):
            model.phase = .result; model.tint = .success; model.title = t; model.detail = d
        case .warning(let t, let d):
            model.phase = .result; model.tint = .warning; model.title = t; model.detail = d
        case .info(let t, let d):
            model.phase = .result; model.tint = .neutral; model.title = t; model.detail = d
        }

        revealPanel()
        syncEdgeGlow(for: intent)
        announceIfChanged(for: intent)

        if let seconds { scheduleHide(after: seconds) }
    }

    /// The edge glow exists only while Jarvis is listening: it rises with
    /// `.listening` in Jarvis mode, fades out into any thinking phase, and is
    /// dropped instantly by results, dictation, or hide.
    private func syncEdgeGlow(for intent: Intent) {
        switch intent {
        case .listening where model.mode == .jarvis:
            if let screen = targetScreen() { edgeGlow.show(on: screen) }
        case .thinking:
            edgeGlow.fadeOutAndTearDown()
        default:
            edgeGlow.tearDownImmediately()
        }
    }

    /// Emergency release of every transient GPU layer (memory pressure).
    func tearDownTransientLayers() {
        edgeGlow.tearDownImmediately()
    }

    /// Push a live microphone level (linear RMS, ~0...1). Cheap; safe at 15 fps.
    func updateLevel(_ rms: Float) {
        guard model.phase == .listening else { return }
        // Perceptual curve so quiet speech still animates without clipping loud speech.
        let shaped = CGFloat(min(1, sqrt(max(0, rms)) * 3.2))
        model.pushLevel(shaped)
        // Low-passed copy for the Jarvis orb — same 15 fps push, no extra timer.
        model.orbEnergy = model.orbEnergy * 0.7 + shaped * 0.3
        if model.mode == .jarvis { edgeGlow.updateLevel(rms) }
    }

    /// Update the live streaming caption shown under "Listening". Display only.
    func updateCaption(_ text: String) {
        guard model.phase == .listening else { return }
        model.caption = text
    }

    /// Update the live detail line under a thinking/progress title (e.g. the
    /// streaming polish preview). High-frequency and display only — never
    /// routes anywhere, and never retriggers the structural animation.
    func updateProgressDetail(_ text: String) {
        guard model.phase == .thinking else { return }
        model.caption = text
    }

    func setMemoryLedger(_ text: String) {
        model.footnote = text
    }

    func hide() {
        hideTask?.cancel(); hideTask = nil
        edgeGlow.tearDownImmediately()
        dismissPanel()
    }

    // MARK: Legacy string shim (keeps older call sites compiling; strips decoration)

    func show(_ legacy: String) {
        present(intent(fromLegacy: legacy))
    }

    func showResult(_ legacy: String, autoHideAfter seconds: Double = 6) {
        present(intent(fromLegacy: legacy), dismissAfter: seconds)
    }

    // MARK: Legacy interpretation

    private func intent(fromLegacy raw: String) -> Intent {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Phase/tint detection mirrors the original prefix classifier exactly, so no
        // result loses its detail line by being mistaken for a transient "thinking" state.
        let isListening = trimmed.hasPrefix("●")
        let isThinking = ["…", "✨", "⏳"].contains { trimmed.hasPrefix($0) }
        let isSuccess = trimmed.hasPrefix("✓") || trimmed.hasPrefix("✅")
        let isClarify = trimmed.hasPrefix("❓")
        let isReply = trimmed.hasPrefix("🗣") || trimmed.hasPrefix("🧠")
        let warningMarkers = ["⚠️", "⚠", "⚡", "🔋", "📅", "💡", "📦", "📄", "💿"]
        let isWarning = warningMarkers.contains { trimmed.hasPrefix($0) }

        let clean = Self.stripDecoration(trimmed)
        let (title, detail) = Self.splitTitleDetail(clean)

        if isListening { return .listening }
        if isSuccess   { return .success(title, detail: detail) }
        if isWarning   { return .warning(title, detail: detail) }
        if isClarify   { return .clarify(title) }
        if isReply     { return .reply(detail.isEmpty ? title : "\(title)\n\(detail)") }
        if isThinking  { return .thinking(title) }
        return .info(title, detail: detail)
    }

    /// Remove emoji, pictographs, and legacy status glyphs; collapse whitespace.
    static func stripDecoration(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        let explicit: Set<Unicode.Scalar> = Set("●✓✅✦✨⏳⚠⚡🔋📅💡📦📄💿❓🔍📸📝📋🔑🗺📈📊🗣🧠🌤🚌🏠▁▂▃▄▅▆▇█"
            .unicodeScalars)
        for u in s.unicodeScalars {
            if u == "\u{FE0F}" || u == "\u{200D}" { continue }        // variation selector / ZWJ
            if explicit.contains(u) { continue }
            let p = u.properties
            if p.isEmojiPresentation || p.isEmojiModifier || p.isEmojiModifierBase { continue }
            switch p.generalCategory {
            case .otherSymbol, .modifierSymbol: continue
            default: break
            }
            scalars.append(u)
        }
        var out = String(scalars)
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First line becomes the title; any remainder becomes the detail.
    private static func splitTitleDetail(_ text: String) -> (String, String) {
        guard let nl = text.firstIndex(of: "\n") else { return (text, "") }
        let title = String(text[..<nl]).trimmingCharacters(in: .whitespaces)
        let detail = String(text[text.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, detail)
    }

    // MARK: Accessibility

    private func announceIfChanged(for intent: Intent) {
        let message: String
        switch intent {
        case .listening: message = "Listening"
        case .thinking(let t): message = t.isEmpty ? "Working" : t
        case .progress(let t, let d): message = d.isEmpty ? t : "\(t). \(d)"
        case .clarify(let q): message = "Question: \(q)"
        case .reply(let r): message = r
        case .success(let t, let d), .warning(let t, let d), .info(let t, let d):
            message = d.isEmpty ? t : "\(t). \(d)"
        }
        guard message != lastAnnouncement, !message.isEmpty else { return }
        lastAnnouncement = message
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                NSAccessibility.NotificationUserInfoKey.announcement: message,
                NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }

    // MARK: Panel lifecycle

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func revealPanel() {
        ensurePanel()
        positionPanel()
        panel?.orderFrontRegardless()
        model.visible = true
    }

    private func dismissPanel() {
        model.visible = false
        lastAnnouncement = ""
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard let self, self.model.visible == false else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let hosting = NSHostingView(rootView: HUDRootView(model: model))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // shadow is rendered by SwiftUI
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        self.panel = panel

        // Re-center when displays change (resolution, arrangement, connect/disconnect).
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleScreenChange() }
        }
    }

    /// The screen the user is working on: pointer's screen, then key/main,
    /// then any. Shared by the HUD capsule and the edge glow so both always
    /// land on the same display.
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func positionPanel() {
        guard let panel, let screen = targetScreen() else { return }

        let sf = screen.visibleFrame
        let w: CGFloat = 660, h: CGFloat = 220
        let x = sf.minX + (sf.width - w) / 2
        let y = sf.minY + 48
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
    }

    /// Displays changed (resolution, arrangement, connect/disconnect): re-seat
    /// the capsule and keep the glow glued to the same screen — or drop it if
    /// no screen is available anymore.
    private func handleScreenChange() {
        positionPanel()
        guard edgeGlow.isActive else { return }
        if let screen = targetScreen() {
            edgeGlow.reposition(to: screen)
        } else {
            edgeGlow.tearDownImmediately()
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
