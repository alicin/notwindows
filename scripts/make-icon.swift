import AppKit

// Renders Resources/AppIcon.icns: a gradient squircle with a wine glass and a controller.
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)

    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.55, green: 0.08, blue: 0.30, alpha: 1),
        NSColor(red: 0.32, green: 0.06, blue: 0.42, alpha: 1),
        NSColor(red: 0.10, green: 0.05, blue: 0.25, alpha: 1),
    ])!.draw(in: path, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let glow = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    glow.draw(fromCenter: NSPoint(x: rect.midX - rect.width * 0.2, y: rect.maxY), radius: 0,
              toCenter: NSPoint(x: rect.midX - rect.width * 0.2, y: rect.maxY), radius: rect.width * 0.9, options: [])
    NSGraphicsContext.restoreGraphicsState()

    func symbol(_ name: String, pointSize: CGFloat, at center: NSPoint, alpha: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            .applying(.init(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let r = NSRect(x: center.x - image.size.width / 2, y: center.y - image.size.height / 2, width: image.size.width, height: image.size.height)
        image.draw(in: r)
    }
    symbol("wineglass.fill", pointSize: s * 0.36, at: NSPoint(x: rect.midX, y: rect.midY + s * 0.06), alpha: 0.96)
    symbol("gamecontroller.fill", pointSize: s * 0.14, at: NSPoint(x: rect.midX, y: rect.minY + s * 0.15), alpha: 0.75)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
