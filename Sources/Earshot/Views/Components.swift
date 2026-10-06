import AppKit
import SwiftUI

/// Blurs whatever is behind the captions.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

extension View {
    /// A dark halo that keeps light text legible over video or busy backgrounds.
    @ViewBuilder
    func readableShadow(_ enabled: Bool) -> some View {
        if enabled {
            self
                .shadow(color: .black.opacity(0.9), radius: 1.2, x: 0, y: 1)
                .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 0)
        } else {
            self
        }
    }

    /// The theme's text shadow. The Shadow theme has no backdrop at all, so it adds a
    /// firmer drop shadow under the halo to keep white text legible over white slides.
    @ViewBuilder
    func captionShadow(_ theme: Theme) -> some View {
        if theme.bare {
            self
                .shadow(color: .black.opacity(0.85), radius: 1.5, x: 1.5, y: 2)
                .readableShadow(true)
        } else {
            self.readableShadow(theme.textShadow)
        }
    }

    /// Fades content out towards the top (and optionally the bottom) edge.
    func edgeFade(top: CGFloat = 0.18, bottom: CGFloat = 0) -> some View {
        mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: top),
                    .init(color: .black, location: 1 - bottom),
                    .init(color: bottom > 0 ? .clear : .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

/// The captions' rounded, themed backdrop.
struct PanelBackground: View {
    let theme: Theme
    let opacity: Double

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let alpha = opacity
        ZStack {
            if theme.usesMaterial {
                VisualEffectBackground(material: .hudWindow)
                    .opacity(alpha)
            }
            shape.fill(theme.background.opacity(theme.usesMaterial ? alpha * 0.45 : alpha))
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(theme.isDark ? 0.10 : 0.35), lineWidth: 0.5))
    }
}

/// A compact bar-graph level meter.
struct LevelMeter: View {
    var level: Double
    var active: Bool
    var color: Color
    var bars = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                let threshold = Double(index) / Double(bars) * 0.8
                Capsule()
                    .fill(color.opacity(level > threshold ? (active ? 1 : 0.6) : 0.22))
                    .frame(width: 3, height: 5 + CGFloat(index) * 2.4)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
