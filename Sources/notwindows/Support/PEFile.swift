import Foundation

/// Minimal reader for Windows PE files: architecture, imports, .NET header, resources and version strings.
struct PEFile {
    enum Machine { case i386, amd64, arm64, other(UInt16) }

    let data: Data
    let machine: Machine
    private let sections: [(va: UInt32, size: UInt32, raw: UInt32)]
    private let directories: Int

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        self.data = data
        let r = Reader(data: data)
        guard r.u16(0) == 0x5A4D, let peOffset = r.u32(0x3C).map(Int.init), r.u32(peOffset) == 0x0000_4550,
              let rawMachine = r.u16(peOffset + 4),
              let sectionCount = r.u16(peOffset + 6).map(Int.init),
              let optionalSize = r.u16(peOffset + 20).map(Int.init) else { return nil }

        switch rawMachine {
        case 0x014C: machine = .i386
        case 0x8664: machine = .amd64
        case 0xAA64: machine = .arm64
        default: machine = .other(rawMachine)
        }

        let optional = peOffset + 24
        switch r.u16(optional) {
        case 0x10B: directories = optional + 96
        case 0x20B: directories = optional + 112
        default: return nil
        }

        var sections: [(UInt32, UInt32, UInt32)] = []
        let table = optional + optionalSize
        for i in 0..<sectionCount {
            let base = table + i * 40
            guard let vsize = r.u32(base + 8), let va = r.u32(base + 12),
                  let rawSize = r.u32(base + 16), let raw = r.u32(base + 20) else { return nil }
            sections.append((va, max(vsize, rawSize), raw))
        }
        self.sections = sections
    }

    var is64Bit: Bool {
        switch machine {
        case .amd64, .arm64: true
        default: false
        }
    }

    var reader: Reader { Reader(data: data) }

    func offset(ofRVA rva: UInt32) -> Int? {
        for s in sections where rva >= s.va && rva < s.va &+ s.size {
            return Int(s.raw) + Int(rva - s.va)
        }
        return nil
    }

    func directory(_ index: Int) -> (rva: UInt32, size: UInt32)? {
        guard let rva = reader.u32(directories + index * 8), let size = reader.u32(directories + index * 8 + 4), rva != 0 else { return nil }
        return (rva, size)
    }

    /// Lowercased names of imported and delay-loaded DLLs.
    var importedDLLs: Set<String> {
        var names = Set<String>()
        let r = reader
        if let imports = directory(1), var cursor = offset(ofRVA: imports.rva) {
            while let nameRVA = r.u32(cursor + 12), nameRVA != 0, names.count < 512 {
                if let name = cString(atRVA: nameRVA) { names.insert(name.lowercased()) }
                cursor += 20
            }
        }
        if let delayed = directory(13), var cursor = offset(ofRVA: delayed.rva) {
            while let nameRVA = r.u32(cursor + 4), nameRVA != 0, names.count < 512 {
                if let name = cString(atRVA: nameRVA) { names.insert(name.lowercased()) }
                cursor += 32
            }
        }
        return names
    }

    var isDotNet: Bool { directory(14) != nil }

    private func cString(atRVA rva: UInt32) -> String? {
        guard let start = offset(ofRVA: rva), start < data.count else { return nil }
        let base = data.startIndex + start
        guard let end = data[base..<min(base + 256, data.endIndex)].firstIndex(of: 0) else { return nil }
        return String(decoding: data[base..<end], as: UTF8.self)
    }

    // MARK: Resources

    struct ResourceEntry {
        let id: UInt32?
        let target: Int
        let isDirectory: Bool
    }

    var resourceRoot: Int? { directory(2).flatMap { offset(ofRVA: $0.rva) } }

    func resourceEntries(at directory: Int) -> [ResourceEntry] {
        guard let root = resourceRoot else { return [] }
        let r = reader
        guard let named = r.u16(directory + 12), let ids = r.u16(directory + 14) else { return [] }
        return (0..<Int(named) + Int(ids)).compactMap { i in
            let entry = directory + 16 + i * 8
            guard let name = r.u32(entry), let target = r.u32(entry + 4) else { return nil }
            let id: UInt32? = name & 0x8000_0000 == 0 ? name : nil
            return ResourceEntry(id: id, target: root + Int(target & 0x7FFF_FFFF), isDirectory: target & 0x8000_0000 != 0)
        }
    }

    /// Descends to the first language leaf under `directory` and returns that resource's bytes.
    func firstResourceLeaf(_ directory: Int, depth: Int = 0) -> Data? {
        guard depth < 4, let entry = resourceEntries(at: directory).first else { return nil }
        if entry.isDirectory { return firstResourceLeaf(entry.target, depth: depth + 1) }
        guard let rva = reader.u32(entry.target), let size = reader.u32(entry.target + 4),
              let start = offset(ofRVA: rva) else { return nil }
        return reader.slice(start, Int(size))
    }

    func resourceTypeDirectory(_ type: UInt32) -> Int? {
        guard let root = resourceRoot else { return nil }
        return resourceEntries(at: root).first { $0.id == type && $0.isDirectory }?.target
    }

    /// A string from the version resource, e.g. "ProductName" or "CompanyName".
    func versionString(_ key: String) -> String? {
        guard let directory = resourceTypeDirectory(16), let version = firstResourceLeaf(directory) else { return nil }
        let needle = Data((key + "\0").utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        guard let range = version.range(of: needle) else { return nil }
        var cursor = range.upperBound - version.startIndex
        cursor = (cursor + 3) & ~3
        var units: [UInt16] = []
        let r = Reader(data: version)
        while let unit = r.u16(cursor), unit != 0, units.count < 256 {
            units.append(unit)
            cursor += 2
        }
        let value = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    struct Reader {
        let data: Data

        func slice(_ offset: Int, _ length: Int) -> Data? {
            guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
            let start = data.startIndex + offset
            return data.subdata(in: start..<start + length)
        }

        func u16(_ offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= data.count else { return nil }
            let i = data.startIndex + offset
            return UInt16(data[i]) | UInt16(data[i + 1]) << 8
        }

        func u32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let i = data.startIndex + offset
            return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
        }
    }
}
