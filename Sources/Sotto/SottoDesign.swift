import AppKit
import SwiftUI

// MARK: - Sotto design tokens
//
// The single vocabulary for color, motion, and metrics shared by every visible
// surface (SwiftUI and AppKit). Two mode personalities are defined once here:
//
//   • dictation — quiet utility. The same gradient family as Jarvis but at
//     lower chroma and higher lightness, so dictation reads as a calm tool.
//   • jarvis    — the full Apple-Intelligence light gradient (blue → violet →
//     pink → warm orange), used for the capsule rim, the orb, and the
//     screen-edge glow.
//
// Design language rules (agreed with the user):
//   – no emoji or SF Symbols inside the HUD; typography, color, and motion only
//   – minimal chrome: one material background, one rim, one shadow
//   – at most two animated elements per view (listening = orb + glow)
//   – feedback within 100 ms of a hotkey press

enum SottoDesign {

    /// UI-layer mirror of `AppController.Mode`. Kept separate so view code
    /// never imports controller state.
    enum Mode: Equatable {
        case dictation
        case jarvis
    }

    // MARK: Accent palettes

    enum Accent {
        /// Jarvis — the Apple-Intelligence light gradient, looped so an
        /// `AngularGradient` closes seamlessly. Stops are deliberately
        /// light/pastel-leaning per the product's color identity.
        static let jarvis: [Color] = [
            Color(red: 0.42, green: 0.67, blue: 0.98),  // light blue
            Color(red: 0.62, green: 0.48, blue: 0.97),  // violet
            Color(red: 0.96, green: 0.55, blue: 0.76),  // pink
            Color(red: 0.98, green: 0.68, blue: 0.40),  // warm orange
            Color(red: 0.42, green: 0.67, blue: 0.98)   // loop back to blue
        ]

        /// Dictation — the same four hues blended toward white (~45%), so the
        /// quiet mode is unmistakably the same family at lower intensity.
        static let dictation: [Color] = [
            Color(red: 0.68, green: 0.82, blue: 0.99),
            Color(red: 0.79, green: 0.71, blue: 0.98),
            Color(red: 0.98, green: 0.75, blue: 0.87),
            Color(red: 0.99, green: 0.82, blue: 0.66),
            Color(red: 0.68, green: 0.82, blue: 0.99)
        ]

        /// Light-mode Jarvis stops: the same hue order, deepened toward mid-tone
        /// so the gradient rim keeps contrast against a light background.
        static let jarvisLight: [Color] = [
            Color(red: 0.22, green: 0.47, blue: 0.78),
            Color(red: 0.42, green: 0.28, blue: 0.77),
            Color(red: 0.76, green: 0.35, blue: 0.56),
            Color(red: 0.78, green: 0.48, blue: 0.20),
            Color(red: 0.22, green: 0.47, blue: 0.78)
        ]

        /// Light-mode dictation stops — the deepened family at lower intensity.
        static let dictationLight: [Color] = [
            Color(red: 0.48, green: 0.62, blue: 0.79),
            Color(red: 0.59, green: 0.51, blue: 0.78),
            Color(red: 0.78, green: 0.55, blue: 0.67),
            Color(red: 0.79, green: 0.62, blue: 0.46),
            Color(red: 0.48, green: 0.62, blue: 0.79)
        ]

        static func colors(for mode: Mode) -> [Color] {
            switch mode {
            case .dictation: return dictation
            case .jarvis: return jarvis
            }
        }

        /// Color-scheme-aware accent: the light variants hold contrast on light
        /// backgrounds; dark mode keeps the standard pastel palette.
        static func colors(for mode: Mode, colorScheme: ColorScheme) -> [Color] {
            guard colorScheme == .light else { return colors(for: mode) }
            switch mode {
            case .dictation: return dictationLight
            case .jarvis: return jarvisLight
            }
        }

        /// AppKit bridge for the few non-SwiftUI consumers (status bar tint,
        /// window accents).
        static func nsColors(for mode: Mode) -> [NSColor] {
            colors(for: mode).map { NSColor($0) }
        }
    }

    // MARK: Typography
    //
    // One type scale for every surface, so the HUD, Settings, and the AppKit
    // windows never drift into ad-hoc `.systemFont(ofSize:)` values. SwiftUI
    // tokens use Dynamic-Type text styles (they scale with the user's setting);
    // the AppKit tokens mirror them at fixed sizes for the legacy NSWindow views.
    enum Typography {
        // SwiftUI (HUD, overlays, Settings)
        static let label = Font.system(.callout, weight: .semibold)       // live pill word
        static let title = Font.system(.title3, weight: .semibold)        // section / clarify question
        static let sectionTitle = Font.system(.title2, weight: .semibold) // window header
        static let body = Font.system(.callout)                           // secondary detail
        static let caption = Font.system(.subheadline)                    // hint / secondary
        static let mono = Font.system(.caption2, design: .monospaced)     // debug ledger

        // AppKit (window controllers, permission flow, console)
        static var nsTitle: NSFont { .systemFont(ofSize: 15, weight: .bold) }
        static var nsHeadline: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
        static var nsBody: NSFont { .systemFont(ofSize: 13, weight: .regular) }
        static var nsCaption: NSFont { .systemFont(ofSize: 12, weight: .regular) }
        static func nsMono(_ size: CGFloat = 12) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    }

    // MARK: Opacity — the shared alpha layers (no more scattered magic numbers).
    enum Opacity {
        static let shadow = 0.28        // capsule / elevated drop shadow
        static let glowShadow = 0.28    // accent glow around an active surface
        static let decorative = 0.35    // ambient brand gradient bands
        static let rimStrong = 0.26     // bright edge of an at-rest rim
        static let rimSoft = 0.10       // dim edge of an at-rest rim
        static let rim = 0.25           // orb / disc hairline rim
        static let muted = 0.12         // inactive track / disabled fill
        static let sweep = 0.85         // shimmer highlight
    }

    // MARK: Motion

    enum Motion {
        /// Drives capsule resize/visibility (structural model changes).
        static let structural = Animation.spring(response: 0.34, dampingFraction: 0.82)
        /// Drives phase content swaps (listening → thinking → result).
        static let phase = Animation.spring(response: 0.30, dampingFraction: 0.85)
        /// Substitute for either spring under Reduce Motion.
        static let reduced = Animation.easeInOut(duration: 0.2)

        /// One full hue cycle of the edge glow. Slow and ambient, never busy.
        static let glowRotationPeriod: TimeInterval = 8
        /// Edge glow fade when listening hands off to thinking.
        static let glowFadeOut: TimeInterval = 0.6

        static func structural(reduceMotion: Bool) -> Animation {
            reduceMotion ? reduced : structural
        }

        static func phase(reduceMotion: Bool) -> Animation {
            reduceMotion ? Animation.easeInOut(duration: 0.18) : phase
        }
    }

    // MARK: Metrics

    enum Metrics {
        static let corner: CGFloat = 20
        static let windowCorner: CGFloat = 16
        static let barCount = 16
        static let orbDiameter: CGFloat = 30

        // The floating live-indicator pill. Kept small and sized to its content;
        // the transparent panel is only a canvas to bottom-center the pill in.
        static let hudSize = CGSize(width: 460, height: 128)
        static let hudPaddingH: CGFloat = 16
        static let hudPaddingV: CGFloat = 10

        // Regular titled windows — one registry instead of literals per controller.
        static let settingsSize = CGSize(width: 520, height: 640)
        static let consoleSize = CGSize(width: 780, height: 480)
        static let promptReviewSize = CGSize(width: 560, height: 460)
        static let explanationSize = CGSize(width: 520, height: 420)
    }

    // MARK: Brand mesh (shared by the Jarvis orb and the Settings header band)

    enum Mesh {
        /// Static 3×3 control grid. The orb perturbs the interior points at
        /// runtime; static surfaces (the Settings header) use it as-is.
        static let grid: [SIMD2<Float>] = [
            [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
            [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
            [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
        ]

        /// The nine-cell distribution of an accent palette across the grid.
        static func colors(for mode: Mode) -> [Color] {
            let a = Accent.colors(for: mode)
            return [a[0], a[1], a[2],
                    a[3], a[0], a[1],
                    a[2], a[3], a[0]]
        }
    }

    // MARK: Window / panel factories
    //
    // Every floating overlay (HUD capsule, edge glow) and every regular window
    // is built here, so the click-through/level/material contract lives in one
    // place instead of being re-derived per file.

    /// A borderless, non-activating, click-through overlay panel. `belowMaximumBy`
    /// is how many levels below `.maximumWindow` it sits — the HUD uses 1 and the
    /// edge glow uses 2, so the glow can never occlude the capsule. Keeping both
    /// offsets here makes that ordering invariant explicit and un-driftable.
    @MainActor
    static func makeOverlayPanel(size: CGSize, belowMaximumBy offset: Int) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) - offset)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }

    /// A standard titled window with the app's shared material backdrop, centered.
    /// The caller sets the content on the returned window's `contentView`'s backdrop
    /// or replaces the content view entirely (SwiftUI hosting).
    @MainActor
    static func makeWindow(size: CGSize, title: String,
                           styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.center()
        return window
    }
}
