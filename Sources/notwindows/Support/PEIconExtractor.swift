import AppKit

/// Pulls the main icon group out of a Windows PE executable's resource section and returns it as an .ico blob.
enum PEIconExtractor {
    private static let rtIcon: UInt32 = 3
    private static let rtGroupIcon: UInt32 = 14

    static func icoData(fromExecutableAt url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return icoData(fromPE: data)
    }

    static func image(fromExecutableAt url: URL) -> NSImage? {
        guard let ico = icoData(fromExecutableAt: url), let image = NSImage(data: ico), image.isValid else { return nil }
        return image
    }

    static func icoData(fromPE data: Data) -> Data? {
        guard let pe = PEFile(data: data),
              let groupDirectory = pe.resourceTypeDirectory(rtGroupIcon),
              let iconDirectory = pe.resourceTypeDirectory(rtIcon),
              let group = pe.firstResourceLeaf(groupDirectory) else { return nil }

        var icons: [UInt32: Int] = [:]
        for entry in pe.resourceEntries(at: iconDirectory) where entry.isDirectory {
            if let id = entry.id { icons[id] = entry.target }
        }

        let grp = PEFile.Reader(data: group)
        guard let count = grp.u16(4), count > 0 else { return nil }
        var images: [(header: Data, image: Data)] = []
        for i in 0..<Int(count) {
            let base = 6 + i * 14
            guard let header = grp.slice(base, 12), let id = grp.u16(base + 12),
                  let directory = icons[UInt32(id)], let image = pe.firstResourceLeaf(directory) else { continue }
            images.append((header, image))
        }
        guard !images.isEmpty else { return nil }

        var ico = Data()
        ico.appendLE(UInt16(0))
        ico.appendLE(UInt16(1))
        ico.appendLE(UInt16(images.count))
        var imageOffset = 6 + 16 * images.count
        for item in images {
            var header = item.header
            header.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(item.image.count).littleEndian, Array.init))
            ico.append(header)
            ico.appendLE(UInt32(imageOffset))
            imageOffset += item.image.count
        }
        for item in images { ico.append(item.image) }
        return ico
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension NSImage {
    func pngData(maxDimension: CGFloat = 256) -> Data? {
        let best = representations.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
        let pixels = CGFloat(max(best?.pixelsWide ?? 0, best?.pixelsHigh ?? 0))
        let side = min(maxDimension, pixels > 0 ? pixels : maxDimension)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
