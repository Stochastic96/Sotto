import AppKit
import SwiftUI

// MARK: - Sotto HUD
//
// The bottom-center LIVE VOICE INDICATOR — and nothing else. It only ever shows
// what is happening *right now*:
//   • listening — a small waveform (dictation) or breathing orb (Jarvis)
//   • thinking  — a minimal indeterminate activity line
//   • clarify   — a single question Jarvis is waiting on
//
// Every non-live outcome (a reply, a result, "done", a finished long task, a
// system event) is a native top-right notification via `Notifier` — never a box
// on top of the user's work. The tone is Japanese-minimal: one small pill, a few
// words, no emoji or SF Symbols; state reads through motion, color, and sound.
//
// Real-time contract: the SwiftUI front end observes `HUDModel`. Only `phase`
// and `title` drive the resize/transition spring; audio `levels`/`orbEnergy` are
// pushed at ~15 fps outside any animation key.

// Palette, motion, and metric tokens live in SottoDesign.swift.

// MARK: - Observable model (the real-time channel)

@Observable final class HUDModel {
    // `preview` = the post-release dictation sneak-preview (frozen words), shown
    // for a beat then vanishing — never a polish spinner.
    enum Phase: Equatable { case listening, thinking, clarify, preview }

    // Structural — changes here drive the resize/transition spring.
    var phase: Phase = .listening
    var mode: SottoDesign.Mode = .dictation
    /// The one short word ("Listening" / "Working") or the clarifying question.
    var title: String = ""
    /// Only used by `.clarify`: the "how to answer" hint.
    var detail: String = ""
    /// Live dictation sneak-preview text (what you're saying). Grows the pill.
    var caption: String = ""
    var visible = false

    // High-frequency — updated up to ~15 fps, deliberately NOT in any animation key.
    var levels: [CGFloat] = Array(repeating: 0, count: SottoDesign.Metrics.barCount)
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
                        .font(SottoDesign.Typography.mono)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: SottoDesign.Metrics.hudSize.width, height: SottoDesign.Metrics.hudSize.height)
        .animation(SottoDesign.Motion.structural(reduceMotion: reduceMotion),
                   value: model.visible)
        .animation(SottoDesign.Motion.phase(reduceMotion: reduceMotion),
                   value: model.phase)
        .animation(.easeInOut(duration: 0.2), value: model.title)
        // Fluid growth as live words stream in / freeze on release.
        .animation(.easeOut(duration: 0.16), value: model.caption)
    }

    // The one container, sized to its content.
    private var capsule: some View {
        HStack(spacing: 14) {
            content
        }
        .padding(.horizontal, SottoDesign.Metrics.hudPaddingH)
        .padding(.vertical, SottoDesign.Metrics.hudPaddingV)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SottoDesign.Metrics.corner, style: .continuous))
        .overlay(borderOverlay)
        .compositingGroup()
        .shadow(color: .black.opacity(SottoDesign.Opacity.shadow), radius: 18, y: 8)
        .shadow(color: glowColor.opacity(isActive ? SottoDesign.Opacity.glowShadow : 0), radius: 22, y: 0)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .listening:
            if model.mode == .jarvis {
                IndicatorLabel(word: listeningWord) { OrbView(energy: model.orbEnergy) }
            } else {
                // Dictation: a fluid pill that grows with a live sneak-preview of
                // what you're saying, or just "Listening" before the first words.
                DictationListeningView(levels: model.levels, caption: model.caption, accent: accent)
            }
        case .thinking:
            IndicatorLabel(word: model.title.isEmpty ? workingWord : model.title) {
                ActivityLine(reduceMotion: reduceMotion, accent: accent)
                    .frame(width: 56, height: 4)
            }
        case .clarify:
            ClarifyView(question: model.title, hint: model.detail, accent: accent)
        case .preview:
            // Frozen sneak-preview after release; fades out before polish finishes.
            PreviewText(text: model.caption)
        }
    }

    private var listeningWord: String {
        String(localized: "hud.listening", defaultValue: "Listening", bundle: .module)
    }
    private var workingWord: String {
        String(localized: "hud.working", defaultValue: "Working", bundle: .module)
    }

    // Active = a gradient rim + glow (live capture/work); clarify and the frozen
    // sneak-preview read as calmer resting cards.
    private var isActive: Bool { model.phase == .listening || model.phase == .thinking }

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
                LinearGradient(colors: [.white.opacity(SottoDesign.Opacity.rimStrong),
                                        .white.opacity(SottoDesign.Opacity.rimSoft)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
        }
    }
}

// MARK: - Live pill building blocks

/// The one pill layout: a compact indicator on the left, one word on the right.
private struct IndicatorLabel<Indicator: View>: View {
    let word: String
    @ViewBuilder let indicator: () -> Indicator

    var body: some View {
        HStack(spacing: 10) {
            indicator()
            Text(word)
                .font(SottoDesign.Typography.label)
                .foregroundStyle(.primary)
                .fixedSize()
        }
    }
}

/// Dictation listening: a small waveform plus a live, growing sneak-preview of
/// the words being recognized. Before the first word it's just "Listening"; as
/// the ASR partials arrive the pill grows to fit them (capped at a few lines).
private struct DictationListeningView: View {
    let levels: [CGFloat]
    let caption: String
    let accent: [Color]

    var body: some View {
        HStack(spacing: 10) {
            Waveform(levels: levels, accent: accent)
            if caption.isEmpty {
                Text(String(localized: "hud.listening", defaultValue: "Listening", bundle: .module))
                    .font(SottoDesign.Typography.label)
                    .foregroundStyle(.primary)
                    .fixedSize()
            } else {
                Text(caption)
                    .font(SottoDesign.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        }
    }
}

/// The frozen post-release sneak-preview — the words you spoke, held for a beat
/// then faded out (before polish completes). Text only, no indicator.
private struct PreviewText: View {
    let text: String
    var body: some View {
        Text(text)
            .font(SottoDesign.Typography.body)
            .foregroundStyle(.primary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380, alignment: .leading)
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let accent: [Color]

    private let minBar: CGFloat = 3
    private let maxBar: CGFloat = 20

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

private struct ActivityLine: View {
    let reduceMotion: Bool
    let accent: [Color]
    @State private var animate = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule()
                .fill(Color.primary.opacity(SottoDesign.Opacity.muted))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: accent, startPoint: .leading, endPoint: .trailing))
                        .frame(width: w * 0.42)
                        .offset(x: (animate && !reduceMotion) ? w * 0.58 : -w * 0.42)
                        .animation((animate && !reduceMotion)
                                   ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
                                   value: animate)
                }
                .clipShape(Capsule())
        }
        .onAppear { animate = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Clarify: the one text state that stays in the pill (a live question)

private struct ClarifyView: View {
    let question: String
    let hint: String
    let accent: [Color]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Capsule()
                .fill(accent[1])
                .frame(width: 3)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(question)
                    .font(SottoDesign.Typography.title)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if !hint.isEmpty {
                    Text(hint)
                        .font(SottoDesign.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
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
        /// Dictation post-release sneak-preview: the spoken words, held briefly
        /// then faded out (caller passes `dismissAfter`). Never a polish spinner.
        case preview(String)
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
        // Non-live outcomes → native top-right notification, and the live pill
        // fades away. The HUD is never a results box. `dismissAfter` is moot here
        // (the system manages the banner), which also removes the old duplicate
        // hide-timer hazard.
        switch intent {
        case .reply(let text):
            Notifier.shared.post(title: "Jarvis", body: Self.stripDecoration(text))
            hide(); return
        case .success(let t, let d):
            Notifier.shared.post(title: Self.stripDecoration(t), body: d)
            hide(); return
        case .info(let t, let d):
            Notifier.shared.post(title: Self.stripDecoration(t), body: d)
            hide(); return
        case .warning(let t, let d):
            Notifier.shared.post(title: Self.stripDecoration(t), body: d)
            hide(); return
        case .listening, .thinking, .progress, .clarify, .preview:
            break   // live — render in the pill below
        }

        hideTask?.cancel(); hideTask = nil

        if let mode, mode != model.mode {
            model.mode = mode
            lastAnnouncement = ""   // personality switch: let VoiceOver re-announce
        }

        switch intent {
        case .listening:
            if model.phase != .listening { model.resetLevels(); model.orbEnergy = 0 }
            model.phase = .listening
            model.title = ""; model.detail = ""
            model.caption = ""   // always start a fresh preview (no stale words)
        case .thinking(let label):
            model.phase = .thinking
            model.title = label; model.detail = ""; model.caption = ""
        case .progress(let label, _):
            // Live progress collapses to a single word — no growing preview text.
            model.phase = .thinking
            model.title = label; model.detail = ""; model.caption = ""
        case .preview(let text):
            model.phase = .preview
            model.caption = text; model.title = ""; model.detail = ""
        case .clarify(let question):
            // Model-sourced text: strip any stray emoji/glyphs to hold the icon-free contract.
            model.phase = .clarify
            model.title = Self.stripDecoration(question)
            model.detail = String(localized: "hud.clarifyHint",
                                  defaultValue: "Press ⌘⇧J to answer", bundle: .module)
        default:
            break   // routed above
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
        // Derive glow lifecycle from the resolved phase/mode — the same predicate the
        // renderer uses — so it can never disagree with what's on screen. (Matching on
        // the raw intent missed `.progress`, which is a thinking phase, and popped the
        // glow instead of fading it.)
        if model.phase == .listening && model.mode == .jarvis {
            if let screen = targetScreen() { edgeGlow.show(on: screen) }
        } else if model.phase == .thinking {
            edgeGlow.fadeOutAndTearDown()
        } else {
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
        if model.mode == .jarvis { edgeGlow.updateLevel(model.orbEnergy) }
    }

    /// Live dictation sneak-preview: feed the ASR partials while listening so the
    /// pill grows with the user's words. Dictation only; Jarvis stays a minimal orb.
    func updateCaption(_ text: String) {
        guard model.phase == .listening, model.mode == .dictation else { return }
        // @Observable notifies on every set; skip unchanged partials (e.g. silence).
        guard model.caption != text else { return }
        model.caption = text
    }

    /// Polish streaming preview intentionally omitted — dictation polish is silent
    /// (the sneak-preview has already vanished by then). No-op kept for callers.
    func updateProgressDetail(_ text: String) {}

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
        case .preview: message = ""   // the frozen words were already announced live
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
        // One level below .maximumWindow; the edge glow sits one further below.
        let panel = SottoDesign.makeOverlayPanel(size: SottoDesign.Metrics.hudSize, belowMaximumBy: 1)
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
        let w = SottoDesign.Metrics.hudSize.width, h = SottoDesign.Metrics.hudSize.height
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
