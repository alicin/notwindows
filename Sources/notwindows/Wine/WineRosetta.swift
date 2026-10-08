import Foundation

/// Places winerosetta next to a 32-bit game as `d3d9.dll` (plus D9VK as `d9vk.dll`), and cleans up after itself.
enum WineRosetta {
    static let markerName = ".notwindows-winerosetta"
    static let backupSuffix = ".notwindows-backup"

    static var bundledDLL: URL? {
        Bundle.main.url(forResource: "winerosetta", withExtension: "dll", subdirectory: "winerosetta")
    }

    static func d9vkDLL(in runtime: Runtime) -> URL {
        runtime.renderer("d9vk").appendingPathComponent("wine/i386-windows/d3d9.dll")
    }

    /// Brings `directory` in line with `enabled`. Files the user had there before are moved aside, never deleted.
    static func sync(directory: URL, enabled: Bool, dll: URL?, d9vk: URL?) throws {
        let fm = FileManager.default
        let marker = directory.appendingPathComponent(markerName)
        let previouslyPlaced = Set(((try? String(contentsOf: marker, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init))

        var wanted: [String: URL] = [:]
        if enabled {
            guard let dll, dll.exists else {
                throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "winerosetta.dll is missing from the app bundle."])
            }
            wanted["d3d9.dll"] = dll
            if let d9vk, d9vk.exists { wanted["d9vk.dll"] = d9vk }
        }

        for name in previouslyPlaced where wanted[name] == nil {
            let target = directory.appendingPathComponent(name)
            try? fm.removeItem(at: target)
            let backup = directory.appendingPathComponent(name + backupSuffix)
            if backup.exists { try fm.moveItem(at: backup, to: target) }
        }

        for (name, source) in wanted {
            let target = directory.appendingPathComponent(name)
            if target.exists && !previouslyPlaced.contains(name) {
                let backup = directory.appendingPathComponent(name + backupSuffix)
                if !backup.exists { try fm.moveItem(at: target, to: backup) }
            }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source, to: target)
        }

        if wanted.isEmpty {
            try? fm.removeItem(at: marker)
        } else {
            try wanted.keys.sorted().joined(separator: "\n").write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    /// True for 32-bit (i386) PE executables.
    static func is32BitExecutable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 0x40), header.count == 0x40, header[0] == 0x4D, header[1] == 0x5A else { return false }
        let peOffset = header[0x3C..<0x40].reversed().reduce(0) { $0 << 8 | Int($1) }
        try? handle.seek(toOffset: UInt64(peOffset))
        guard let pe = try? handle.read(upToCount: 6), pe.count == 6, pe[0] == 0x50, pe[1] == 0x45 else { return false }
        return Int(pe[4]) | Int(pe[5]) << 8 == 0x014C
    }

    /// Classic 32-bit WoW clients that need winerosetta under Rosetta 2.
    static func isLegacyWoW(_ url: URL) -> Bool {
        url.lastPathComponent.lowercased() == "wow.exe" && is32BitExecutable(url)
    }
}
