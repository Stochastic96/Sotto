import AppKit
import SwiftUI

// MARK: - Jarvis screen-edge glow
//
// The Apple-Intelligence-style glow that hugs the screen edges for the whole
// time Jarvis is listening, then fades out as thinking begins. Owned and
// driven by `HUDOverlay`; it never exists outside a Jarvis listening session.
//
// Non-disturbance contract (user requirement):
//   • click-through (`ignoresMouseEvents`) and non-activating — it can never
//     steal focus or block a click
//   • only on the screen the user is working on (the HUD's screen)
//   • the panel is created per session and RELEASED after fade-out, so no
//     Metal texture or window stays resident while idle (M1 / 8 GB budget)
//
// Rendering strategy (the M1-critical decision):
//   The blurred gradient ring is rasterized ONCE via `.drawingGroup()`. The
//   sustained animation only touches composite-time properties of that
//   texture — a slow hue rotation and an opacity "breathing" tied to voice
//   level — so no per-frame re-blur of a full-screen surface ever happens.
//   Under Reduce Motion or Low Power Mode the ring is static.

@Observable
private final class GlowModel {
    /// Smoothed voice level 0…1; drives opacity breathing only.
    var energy: CGFloat = 0
}

private struct EdgeGlowView: View {
    var model: GlowModel
    /// False under Low Power Mode (checked at session start).
    let allowsMotion: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hueAngle: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let gradient = AngularGradient(colors: SottoDesign.Accent.jarvis, center: .center)

        ZStack {
            // Wide soft halo.
            shape
                .inset(by: -6)
                .strokeBorder(gradient, lineWidth: 28)
                .blur(radius: 24)
            // Thin bright core so the edge reads crisp against any wallpaper.
            shape
                .inset(by: 3)
                .strokeBorder(gradient, lineWidth: 3)
                .blur(radius: 5)
        }
        .drawingGroup()                       // rasterize once; animate the texture only
        .hueRotation(.degrees(hueAngle))
        .opacity(0.55 + model.energy * 0.35)
        .animation(.easeOut(duration: 0.12), value: model.energy)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onAppear {
            guard allowsMotion && !reduceMotion else { return }
            withAnimation(.linear(duration: SottoDesign.Motion.glowRotationPeriod)
                .repeatForever(autoreverses: false)) {
                hueAngle = 360
            }
        }
    }
}

@MainActor
final class EdgeGlowOverlay {

    private var panel: NSPanel?
    private var model: GlowModel?

    var isActive: Bool { panel != nil }

    /// Bring the glow up on the given screen (full frame, including menu bar
    /// and Dock edges). Safe to call repeatedly; an existing panel is reused
    /// within the same session.
    func show(on screen: NSScreen) {
        if let panel {
            panel.setFrame(screen.frame, display: true)
            return
        }

        let model = GlowModel()
        self.model = model

        let allowsMotion = !ProcessInfo.processInfo.isLowPowerModeEnabled
        let hosting = NSHostingView(rootView: EdgeGlowView(model: model, allowsMotion: allowsMotion))

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Exactly one level below the HUD capsule, so the glow can never occlude it.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting
        self.panel = panel

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
    }

    /// Follow the HUD if the user's screen changes mid-session.
    func reposition(to screen: NSScreen) {
        panel?.setFrame(screen.frame, display: true)
    }

    /// Voice level (linear RMS ~0…1), forwarded from the HUD's 15 fps push.
    func updateLevel(_ rms: Float) {
        guard let model else { return }
        let shaped = CGFloat(min(1, sqrt(max(0, rms)) * 3.2))
        model.energy = model.energy * 0.7 + shaped * 0.3
    }

    /// Listening → thinking hand-off: fade over `glowFadeOut`, then release the
    /// panel entirely so nothing stays resident.
    func fadeOutAndTearDown() {
        guard let panel else { return }
        self.panel = nil
        self.model = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = SottoDesign.Motion.glowFadeOut
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // AppKit invokes this on the main thread; hop explicitly for Swift 6.
            Task { @MainActor in
                panel.orderOut(nil)
                panel.contentView = nil
            }
        })
    }

    /// Session abort (hide, result, dictation press, display vanished,
    /// memory pressure): drop the glow instantly.
    func tearDownImmediately() {
        guard let panel else { return }
        self.panel = nil
        self.model = nil
        panel.orderOut(nil)
        panel.contentView = nil
    }
}
