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

    /// The primary colour when it's vivid enough to tint controls; grey icons leave it to the system accent.
    var accent: Color? {
        guard let color = NSColor(primary).usingColorSpace(.sRGB), color.saturationComponent > 0.22 else { return nil }
        return primary
    }
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
                // Sized by the container, not the square image, so wide backdrops don't grow past their view.
                Color.clear
                    .overlay {
                        Image(nsImage: backdrop)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
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

/// A gradient tile with a white symbol, like the icons of Reminders' smart lists.
struct SymbolTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 22
    var bounce = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        shape
            .fill(LinearGradient(colors: [tint.mix(with: .white, amount: 0.18), tint], startPoint: .top, endPoint: .bottom))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: bounce)
            }
            .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: tint.opacity(0.35), radius: size * 0.09, y: size * 0.045)
    }
}

/// The arcade crab invader, flapping between its two frames and shuffling sideways like the original.
struct PixelInvader: View {
    /// Points per sprite pixel; whole multiples of 0.5 keep the edges crisp on Retina displays.
    var pixel: CGFloat = 1.5
    var color: Color = .green
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let frames = [
        ["..X.....X..",
         "...X...X...",
         "..XXXXXXX..",
         ".XX.XXX.XX.",
         "XXXXXXXXXXX",
         "X.XXXXXXX.X",
         "X.X.....X.X",
         "...XX.XX..."],
        ["..X.....X..",
         "X..X...X..X",
         "X.XXXXXXX.X",
         "XXX.XXX.XXX",
         "XXXXXXXXXXX",
         ".XXXXXXXXX.",
         "..X.....X..",
         ".X.......X."],
    ]
    private static let march: [CGFloat] = [0, 1, 2, 1]

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.4, paused: reduceMotion)) { context in
            let step = reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.4)
            Canvas { context, _ in
                var path = Path()
                for (y, row) in Self.frames[step % 2].enumerated() {
                    for (x, cell) in row.enumerated() where cell == "X" {
                        path.addRect(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel))
                    }
                }
                context.fill(path, with: .color(color))
            }
            .frame(width: 11 * pixel, height: 8 * pixel)
            .offset(x: Self.march[step % 4] * pixel)
            .frame(width: 13 * pixel, alignment: .leading)
        }
        .shadow(color: color.opacity(0.7), radius: pixel * 2)
    }
}

/// A game's icon redrawn as a grid of LED-like pixels, like an arcade marquee. Given a start time, the pixels flicker
/// through random colours and land on their own one by one.
struct PixelMosaic: View {
    let grid: PixelGrid
    var revealStart: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    static let revealDuration: TimeInterval = 1.4

    var body: some View {
        let animating = revealStart != nil && !reduceMotion && !settled
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { timeline in
            let elapsed = animating ? timeline.date.timeIntervalSince(revealStart ?? timeline.date) : .infinity
            Canvas { context, size in
                let cell = min(size.width, size.height) / CGFloat(grid.side)
                let inset = max(1, (cell * 0.16).rounded()) / 2
                let origin = CGPoint(x: size.width - cell * CGFloat(grid.side), y: size.height - cell * CGFloat(grid.side))
                for (index, color) in grid.colors.enumerated() {
                    guard let color else { continue }
                    var rect = CGRect(x: origin.x + CGFloat(index % grid.side) * cell, y: origin.y + CGFloat(index / grid.side) * cell,
                                      width: cell, height: cell)
                    let landsAt = 0.35 + (Self.revealDuration - 0.35) * Self.noise(index, 0)
                    let fill: Color
                    if elapsed >= landsAt {
                        // A quick pop as the pixel locks onto its colour.
                        let since = elapsed - landsAt
                        if since < 0.16 { rect = rect.insetBy(dx: -cell * 0.2 * (1 - since / 0.16), dy: -cell * 0.2 * (1 - since / 0.16)) }
                        fill = color
                    } else {
                        let fade = min(max((elapsed - 0.3 * Self.noise(index, 1)) / 0.2, 0), 1)
                        guard fade > 0 else { continue }
                        let hue = Self.noise(index, Int(elapsed / 0.06) + 2)
                        fill = Color(hue: hue, saturation: 0.7, brightness: 1).opacity(0.85 * fade)
                    }
                    rect = rect.insetBy(dx: inset, dy: inset)
                    context.fill(Path(roundedRect: rect, cornerRadius: rect.width * 0.22, style: .continuous), with: .color(fill))
                }
            }
        }
        .allowsHitTesting(false)
        .task(id: revealStart) {
            settled = false
            guard revealStart != nil else { return }
            try? await Task.sleep(for: .seconds(Self.revealDuration + 0.25))
            settled = true
        }
    }

    /// A stable pseudo-random number in 0..<1 for a pixel and a step.
    private static func noise(_ index: Int, _ step: Int) -> Double {
        var x = (UInt64(truncatingIfNeeded: index) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(truncatingIfNeeded: step) &* 0xC2B2_AE3D_27D4_EB4F)
        x ^= x >> 31
        x &*= 0xBF58_476D_1CE4_E5B9
        x ^= x >> 29
        return Double(x % 1_000_000) / 1_000_000
    }
}

struct PixelGrid: Equatable {
    let side: Int
    /// Row by row from the top; nil where the icon is transparent.
    let colors: [Color?]
}

extension NSImage {
    /// The icon averaged down to `side`×`side` pixels.
    func pixelGrid(side: Int) -> PixelGrid? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        let colors = (0..<side * side).map { index -> Color? in
            let alpha = Double(pixels[index * 4 + 3]) / 255
            guard alpha > 0.35 else { return nil }
            func channel(_ offset: Int) -> Double { min(Double(pixels[index * 4 + offset]) / 255 / alpha, 1) }
            return Color(.sRGB, red: channel(0), green: channel(1), blue: channel(2))
        }
        return PixelGrid(side: side, colors: colors)
    }
}

// MARK: - Layout

/// The column a grouped `Form` lays its sections out in: at most 704pt wide, centred, with at least 20pt either side.
/// Content above a form uses the same column so its edges line up with the sections.
enum FormColumn {
    static let maxWidth: CGFloat = 704
    static let margin: CGFloat = 20
}

extension View {
    func formColumn(alignment: Alignment = .leading) -> some View {
        frame(maxWidth: FormColumn.maxWidth, alignment: alignment)
            .padding(.horizontal, FormColumn.margin)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Section footers start at the same edge as the section's header and row text, as in System Settings; a grouped
    /// Form right-aligns them by default and gives them the box's full width.
    func sectionNote() -> some View {
        multilineTextAlignment(.leading)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

// MARK: - Entrance

/// Fades and lifts views in the first time they appear, staggered by index. Coming back to a screen shows it
/// straight away; only views new to this session animate.
struct StaggeredAppear: ViewModifier {
    let index: Int
    let id: AnyHashable
    @MainActor private static var shown: Set<AnyHashable> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible: Bool

    init(index: Int, id: AnyHashable) {
        self.index = index
        self.id = id
        _visible = State(initialValue: Self.shown.contains(id))
    }

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : 14)
            .scaleEffect(visible || reduceMotion ? 1 : 0.96)
            .onAppear {
                guard !visible else { return }
                Self.shown.insert(id)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.82).delay(min(Double(index), 16) * 0.035)) { visible = true }
            }
    }
}

extension View {
    func staggeredAppear(_ index: Int, id: some Hashable) -> some View { modifier(StaggeredAppear(index: index, id: id)) }
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
