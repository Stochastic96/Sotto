import SwiftUI

// MARK: - Jarvis orb
//
// The listening indicator for Jarvis mode: a small fluid MeshGradient disc that
// breathes with the user's voice, in the spirit of Siri's orb. It replaces the
// waveform only in Jarvis mode — dictation keeps its quiet utility waveform.
//
// Real-time contract mirrors the waveform's: `energy` is a smoothed 0…1 level
// pushed at ~15 fps from outside any animation key. The organic drift is driven
// by a TimelineView capped at 30 fps; the view is 44 pt, so per-frame cost is
// negligible. Under Reduce Motion the mesh is static and only a subtle scale
// responds to voice level.

struct OrbView: View {
    /// Smoothed voice level, 0…1. High-frequency; do not animate structurally.
    let energy: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                orb(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    orb(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .frame(width: SottoDesign.Metrics.orbDiameter,
               height: SottoDesign.Metrics.orbDiameter)
        .scaleEffect(1 + energy * 0.08)
        .animation(.easeOut(duration: 0.12), value: energy)
        .accessibilityHidden(true)
    }

    private func orb(at time: TimeInterval) -> some View {
        let e = Float(min(max(energy, 0), 1))
        return MeshGradient(
            width: 3,
            height: 3,
            points: meshPoints(at: time, energy: e),
            colors: meshColors(energy: e)
        )
        .clipShape(Circle())
        .overlay(
            // A faint rim so the orb keeps a defined edge on any material.
            Circle().strokeBorder(.white.opacity(SottoDesign.Opacity.rim), lineWidth: 0.5)
        )
        .shadow(color: SottoDesign.Accent.jarvis[1].opacity(0.35 + Double(e) * 0.25),
                radius: 6 + CGFloat(e) * 4)
    }

    /// 3×3 control grid. Edges stay pinned so the disc fills its circle; the
    /// center and mid-edge points drift on slow sine paths and push outward
    /// with voice energy, which reads as fluid "breathing".
    private func meshPoints(at time: TimeInterval, energy: Float) -> [SIMD2<Float>] {
        let t = Float(time)
        let drift = 0.10 + energy * 0.08

        func sway(_ speed: Float, _ offset: Float) -> Float {
            sin(t * speed + offset) * drift
        }

        return [
            [0.0, 0.0], [0.5 + sway(0.9, 0.0), 0.0], [1.0, 0.0],
            [0.0, 0.5 + sway(0.7, 2.1)],
            [0.5 + sway(1.1, 4.2), 0.5 + sway(0.8, 1.3)],
            [1.0, 0.5 + sway(0.6, 3.4)],
            [0.0, 1.0], [0.5 + sway(1.0, 5.5), 1.0], [1.0, 1.0]
        ]
    }

    /// Jarvis gradient distributed across the grid; voice energy brightens the
    /// center so louder speech visibly energizes the orb.
    private func meshColors(energy: Float) -> [Color] {
        let accent = SottoDesign.Accent.jarvis
        let center = Color.white.opacity(0.55 + Double(energy) * 0.35)
        return [
            accent[0], accent[1], accent[2],
            accent[3], center, accent[0],
            accent[2], accent[3], accent[1]
        ]
    }
}
