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

        static func colors(for mode: Mode) -> [Color] {
            switch mode {
            case .dictation: return dictation
            case .jarvis: return jarvis
            }
        }

        /// AppKit bridge for the few non-SwiftUI consumers (status bar tint,
        /// window accents).
        static func nsColors(for mode: Mode) -> [NSColor] {
            colors(for: mode).map { NSColor($0) }
        }
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
        static let corner: CGFloat = 22
        static let barCount = 24
        static let orbDiameter: CGFloat = 44
    }

    // MARK: Status tints

    static func tintColor(_ tint: HUDModel.Tint) -> Color {
        switch tint {
        case .neutral: return .secondary
        case .success: return Color(nsColor: .systemGreen)
        case .warning: return Color(nsColor: .systemOrange)
        case .accent: return Accent.jarvis[1]   // clarifying questions are a Jarvis moment
        }
    }
}
