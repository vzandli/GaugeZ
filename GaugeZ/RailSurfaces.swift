import AppKit
import SwiftUI

// MARK: - Native Liquid Glass Controls & Containers

extension View {
    @ViewBuilder
    func glassControl(enabled: Bool = true) -> some View {
        if #available(macOS 26.0, *), enabled {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Groups glass controls in a card. It intentionally does NOT wrap them in a
/// `GlassEffectContainer`: inside the borderless, transparent edge panel that container
/// allocates roughly 220 MB of backdrop buffers the moment a card opens (measured with the
/// attached settings card), while the plain `.glass` buttons cost a few MB. The buttons keep
/// their Liquid Glass look without it.
struct GlassGroup<Content: View>: View {
    let enabled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
    }
}

// MARK: - Frosted glass

/// High-fidelity Liquid Glass surfaces built on vibrant behind-window blur with multi-layer
/// specular edge highlights and refractive sheen gradients.
enum RailGlass {
    /// Normalized opacity scaling:
    /// slider at 85% transparency (opacity 0.15) -> 0.02 (crystal clear!)
    /// slider at 15% transparency (opacity 0.85) -> 0.45 (smoked dark glass!)
    /// Scaled opacity:
    /// opacity 0.0 (100% transparency) -> Color.black.opacity(0.0) / crystal-clear glass!
    /// opacity 1.0 (0% transparency) -> Color.black.opacity(0.52) / dark smoked glass!
    static func tint(for opacity: Double) -> Color {
        let clamped = max(0.0, min(1.0, opacity))
        // 0.0 (100% transparency on slider) -> Color.clear (pure crystal-clear menu glass)
        // 1.0 (0% transparency on slider) -> 24% soft smoked tint
        return clamped > 0.01 ? Color.black.opacity(clamped * 0.24) : Color.clear
    }

    static func railTint(opacity: Double = 0.50) -> Color {
        tint(for: opacity)
    }

    static func cardTint(opacity: Double = 0.50) -> Color {
        tint(for: opacity)
    }

    static func panelTint(opacity: Double = 0.50) -> Color {
        tint(for: opacity)
    }

    static var railTint: Color { railTint() }
    static var cardTint: Color { cardTint() }
    static var panelTint: Color { panelTint() }

    /// Multi-layer liquid glass surface matching native macOS menu translucency.
    struct Frosted<S: Shape>: View {
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @Environment(\.colorSchemeContrast) private var contrast
        let shape: S
        var glassOpacity: Double = 0.50
        var tint: Color? = nil

        var body: some View {
            let clampedOpacity = max(0.0, min(1.0, glassOpacity))
            let tintColor = tint ?? RailGlass.tint(for: clampedOpacity)

            ZStack {
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(white: 0.04))
                    shape.stroke(.white.opacity(0.75), lineWidth: 1.5)
                } else {
                // 1. Native macOS glass blur: scales opacity with slider so at 100% transparency
                // the dark graphite wash fades out and the vibrant wallpaper colors pass directly through!
                BehindWindowBlur(material: .popover)
                    .clipShape(shape)
                    .opacity(max(0.22, 0.28 + clampedOpacity * 0.72))

                // 2. Translucent tinted body (only adds dark tint when user reduces transparency)
                shape.fill(tintColor)

                // 3. Subtle optical surface sheen (soft top reflection)
                shape.fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.12), location: 0.0),
                            .init(color: .white.opacity(0.03), location: 0.25),
                            .init(color: .clear, location: 0.60)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // 4. Clean specular edge highlight (light refraction without dark muddy strokes)
                shape
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.40), location: 0.0),
                                .init(color: .white.opacity(0.18), location: 0.45),
                                .init(color: .white.opacity(0.08), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )

                // 5. Crisp subtle outer hairline matching macOS native menu border
                shape
                    .stroke(Color.black.opacity(0.20), lineWidth: 0.5)
            }
            }
            .allowsHitTesting(false)
        }
    }

    /// Frosted glass when enabled, otherwise the solid dark surface with a hairline edge.
    /// Dual-stage elevation: shadow is scaled with glass opacity so it never creates a dark backing inside transparent glass.
    struct Surface<S: Shape>: ViewModifier {
        let shape: S
        var glassOpacity: Double = 0.50
        var tint: Color? = nil
        let interactive: Bool
        let enabled: Bool
        var shadowed = true

        func body(content: Content) -> some View {
            let clampedOpacity = max(0.0, min(1.0, glassOpacity))
            content
                .background {
                    ZStack {
                        if shadowed {
                            // Shadow is softened and scaled with opacity to avoid darkening the transparent interior
                            shape.fill(.black.opacity(enabled ? clampedOpacity * 0.18 : 0.35))
                                .blur(radius: enabled ? 14 : 10)
                                .offset(y: 4)

                            shape.fill(.black.opacity(enabled ? clampedOpacity * 0.12 : 0.22))
                                .blur(radius: enabled ? 4 : 2)
                                .offset(y: 1)
                        }
                        if enabled {
                            Frosted(shape: shape, glassOpacity: glassOpacity, tint: tint)
                        } else {
                            shape.fill(Color(white: 0.04).opacity(0.97))
                            shape.stroke(.white.opacity(0.1), lineWidth: 1)
                        }
                    }
                }
        }
    }
}

struct BehindWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // .popover provides rich wallpaper color transmission without forcing an opaque black mask
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

