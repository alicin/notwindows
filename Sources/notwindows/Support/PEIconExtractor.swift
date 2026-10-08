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
        let pe = Reader(data: data)
        guard pe.u16(0) == 0x5A4D, let peOffset = pe.u32(0x3C).map(Int.init), pe.u32(peOffset) == 0x0000_4550,
              let sectionCount = pe.u16(peOffset + 6).map(Int.init),
              let optionalSize = pe.u16(peOffset + 20).map(Int.init) else { return nil }

        let optional = peOffset + 24
        let directories: Int
        switch pe.u16(optional) {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: return nil
        }
        guard let resourceRVA = pe.u32(directories + 2 * 8), resourceRVA != 0 else { return nil }

        var sections: [(va: UInt32, size: UInt32, raw: UInt32)] = []
        let table = optional + optionalSize
        for i in 0..<sectionCount {
            let base = table + i * 40
            guard let vsize = pe.u32(base + 8), let va = pe.u32(base + 12),
                  let rawSize = pe.u32(base + 16), let raw = pe.u32(base + 20) else { return nil }
            sections.append((va, max(vsize, rawSize), raw))
        }
        func offset(ofRVA rva: UInt32) -> Int? {
            for s in sections where rva >= s.va && rva < s.va &+ s.size {
                return Int(s.raw) + Int(rva - s.va)
            }
            return nil
        }
        guard let root = offset(ofRVA: resourceRVA) else { return nil }

        func entries(at directory: Int) -> [(id: UInt32?, target: Int, isDirectory: Bool)] {
            guard let named = pe.u16(directory + 12), let ids = pe.u16(directory + 14) else { return [] }
            return (0..<Int(named) + Int(ids)).compactMap { i in
                let entry = directory + 16 + i * 8
                guard let name = pe.u32(entry), let target = pe.u32(entry + 4) else { return nil }
                let id: UInt32? = name & 0x8000_0000 == 0 ? name : nil
                return (id, root + Int(target & 0x7FFF_FFFF), target & 0x8000_0000 != 0)
            }
        }
        /// Descends to the first language leaf under `directory` and returns that resource's bytes.
        func firstLeaf(_ directory: Int) -> Data? {
            guard let entry = entries(at: directory).first else { return nil }
            if entry.isDirectory { return firstLeaf(entry.target) }
            guard let rva = pe.u32(entry.target), let size = pe.u32(entry.target + 4),
                  let start = offset(ofRVA: rva) else { return nil }
            return pe.slice(start, Int(size))
        }

        let types = entries(at: root)
        guard let groupType = types.first(where: { $0.id == rtGroupIcon && $0.isDirectory }),
              let iconType = types.first(where: { $0.id == rtIcon && $0.isDirectory }),
              let group = firstLeaf(groupType.target) else { return nil }

        var icons: [UInt32: Int] = [:]
        for entry in entries(at: iconType.target) where entry.isDirectory {
            if let id = entry.id { icons[id] = entry.target }
        }

        let grp = Reader(data: group)
        guard let count = grp.u16(4), count > 0 else { return nil }
        var images: [(header: Data, image: Data)] = []
        for i in 0..<Int(count) {
            let base = 6 + i * 14
            guard let header = grp.slice(base, 12), let id = grp.u16(base + 12),
                  let directory = icons[UInt32(id)], let image = firstLeaf(directory) else { continue }
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

    private struct Reader {
        let data: Data

        func slice(_ offset: Int, _ length: Int) -> Data? {
            guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
            let start = data.startIndex + offset
            return data.subdata(in: start..<start + length)
        }

        func u16(_ offset: Int) -> UInt16? {
            guard let bytes = slice(offset, 2) else { return nil }
            return UInt16(bytes[bytes.startIndex]) | UInt16(bytes[bytes.startIndex + 1]) << 8
        }

        func u32(_ offset: Int) -> UInt32? {
            guard let bytes = slice(offset, 4) else { return nil }
            return bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
        }
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
