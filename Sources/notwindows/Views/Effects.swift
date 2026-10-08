import AppKit
import CoreImage
import SwiftUI

// MARK: - Palette

struct IconPalette: Equatable {
    var primary: Color
    var secondary: Color
    var glow: Color

    static let fallback = IconPalette(
        primary: Color(red: 0.42, green: 0.12, blue: 0.36),
        secondary: Color(red: 0.12, green: 0.08, blue: 0.30),
        glow: Color(red: 0.85, green: 0.35, blue: 0.6)
    )
}

extension NSImage {
    /// Two tones sampled from the top and bottom halves of the icon, tuned to work as a backdrop.
    func palette() -> IconPalette? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let image = CIImage(cgImage: cg)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        let extent = image.extent

        func average(_ rect: CGRect) -> NSColor? {
            guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect)]),
                  let output = filter.outputImage else { return nil }
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
            let alpha = max(CGFloat(pixel[3]) / 255, 0.01)
            return NSColor(srgbRed: min(CGFloat(pixel[0]) / 255 / alpha, 1), green: min(CGFloat(pixel[1]) / 255 / alpha, 1),
                           blue: min(CGFloat(pixel[2]) / 255 / alpha, 1), alpha: 1)
        }

        let half = extent.height / 2
        guard let top = average(CGRect(x: extent.minX, y: extent.minY + half, width: extent.width, height: half)),
              let bottom = average(CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: half)) else { return nil }

        func tuned(_ color: NSColor, brightness range: ClosedRange<CGFloat>, saturationBoost: CGFloat) -> Color {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.usingColorSpace(.sRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let saturation = s < 0.08 ? s : min(s * saturationBoost + 0.08, 0.9)
            return Color(hue: h, saturation: saturation, brightness: min(max(b, range.lowerBound), range.upperBound))
        }
        return IconPalette(
            primary: tuned(top, brightness: 0.38...0.72, saturationBoost: 1.35),
            secondary: tuned(bottom, brightness: 0.16...0.42, saturationBoost: 1.25),
            glow: tuned(top, brightness: 0.75...0.95, saturationBoost: 1.5)
        )
    }
}

extension NSImage {
    /// A heavily blurred, saturated wash of the icon, pre-rendered once so cards don't blur live.
    func backdrop(side: CGFloat = 192) -> NSImage? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let source = CIImage(cgImage: cg)
        let scale = side / max(source.extent.width, source.extent.height)
        // Zoom into the centre so the result reads as colour, not as a recognisable shape.
        let zoomed = source
            .transformed(by: CGAffineTransform(scaleX: scale * 1.9, y: scale * 1.9))
        let center = CGPoint(x: zoomed.extent.midX, y: zoomed.extent.midY)
        let crop = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let background = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: crop)
        let filled = zoomed.composited(over: background)
        let blurred = filled.clampedToExtent()
            .applyingGaussianBlur(sigma: side * 0.11)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.6, kCIInputContrastKey: 1.05])
            .cropped(to: crop)
        let context = CIContext()
        guard let output = context.createCGImage(blurred, from: crop) else { return nil }
        return NSImage(cgImage: output, size: NSSize(width: side, height: side))
    }
}

// MARK: - Artwork

/// A rich backdrop generated from a game's icon: tinted gradient, a pre-blurred wash of the art and a soft highlight.
struct ArtworkBackground: View {
    let backdrop: NSImage?
    var palette: IconPalette?

    var body: some View {
        let colors = palette ?? .fallback
        ZStack {
            LinearGradient(colors: [colors.primary, colors.secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let backdrop {
                Image(nsImage: backdrop)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.7)
                    .blendMode(.softLight)
            }
            RadialGradient(colors: [colors.glow.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 360)
            LinearGradient(colors: [.clear, colors.secondary.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }
}

// MARK: - Tilt

/// Tilts content towards the pointer with a moving specular highlight, like a physical card.
struct TiltOnHover: ViewModifier {
    var maxAngle: Double = 9
    var cornerRadius: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGSize = .zero
    @State private var pointer: UnitPoint = .center
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if hovering && !reduceMotion {
                    RadialGradient(colors: [.white.opacity(0.28), .clear], center: pointer, startRadius: 0, endRadius: 180)
                        .blendMode(.plusLighter)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .rotation3DEffect(.degrees(reduceMotion ? 0 : -offset.height * maxAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : offset.width * maxAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case .active(let location):
                                let size = proxy.size
                                guard size.width > 0, size.height > 0 else { return }
                                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.8)) {
                                    hovering = true
                                    pointer = UnitPoint(x: location.x / size.width, y: location.y / size.height)
                                    offset = CGSize(width: location.x / size.width - 0.5, height: location.y / size.height - 0.5)
                                }
                            case .ended:
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) {
                                    hovering = false
                                    offset = .zero
                                    pointer = .center
                                }
                            }
                        }
                }
            }
    }
}

extension View {
    func tiltOnHover(maxAngle: Double = 9, cornerRadius: CGFloat = 18) -> some View {
        modifier(TiltOnHover(maxAngle: maxAngle, cornerRadius: cornerRadius))
    }
}

// MARK: - Running glow

/// A slowly rotating gradient ring marking a game that's currently running.
struct RunningGlow: View {
    var cornerRadius: CGFloat = 18
    var lineWidth: CGFloat = 3
    var tint: Color = .green
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let angle = Angle.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4 * 360)
            let gradient = AngularGradient(colors: [tint, .mint, .cyan, tint.opacity(0.2), tint], center: .center, angle: angle)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(gradient, lineWidth: lineWidth)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(gradient, lineWidth: lineWidth * 2)
                    .blur(radius: 8)
                    .opacity(0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Small pulsing status dot.
struct PulsingDot: View {
    var color: Color = .green
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .background {
                Circle()
                    .fill(color.opacity(0.5))
                    .scaleEffect(animate && !reduceMotion ? 2.4 : 1)
                    .opacity(animate && !reduceMotion ? 0 : 0.8)
            }
            .onAppear {
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { animate = true }
            }
    }
}

// MARK: - Entrance

/// Fades and lifts views in on first appearance, staggered by index.
struct StaggeredAppear: ViewModifier {
    let index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .scaleEffect(visible || reduceMotion ? 1 : 0.96)
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(min(Double(index), 16) * 0.035)) { visible = true }
            }
    }
}

extension View {
    func staggeredAppear(_ index: Int) -> some View { modifier(StaggeredAppear(index: index)) }
}

// MARK: - Buttons

/// The big launcher-style play button with a bouncing glyph and a soft coloured glow.
struct PlayButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 38)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.mix(with: .black, amount: 0.25)], startPoint: .top, endPoint: .bottom))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: tint.opacity(isEnabled ? 0.55 : 0), radius: configuration.isPressed ? 4 : 12, y: configuration.isPressed ? 1 : 5)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension Color {
    func mix(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        return Color(
            red: a.redComponent + (b.redComponent - a.redComponent) * amount,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount
        )
    }
}

// MARK: - Toasts

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String?
    var tint: Color = .accentColor
}

struct ToastView: View {
    let toast: Toast
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                GameIconView(icon: icon, size: 30)
            } else {
                Image(systemName: toast.symbol)
                    .font(.title2)
                    .foregroundStyle(toast.tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(toast.title).font(.headline)
                if let detail = toast.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
    }
}
