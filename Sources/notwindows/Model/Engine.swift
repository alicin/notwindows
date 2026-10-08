import Foundation

/// An installed Wine build in Sikarugir's `wswine.bundle` layout.
struct Engine: Identifiable, Hashable {
    let name: String
    let directory: URL

    var id: String { name }
    var bundle: URL { directory.appendingPathComponent("wswine.bundle", isDirectory: true) }
    var bin: URL { bundle.appendingPathComponent("bin", isDirectory: true) }
    var lib: URL { bundle.appendingPathComponent("lib", isDirectory: true) }
    var wineLib: URL { lib.appendingPathComponent("wine", isDirectory: true) }
    /// Prefers the real loader: Sikarugir's bin/wine is a thin launcher that misbehaves outside a wrapper.
    /// Older (pre-WoW64) builds only ship bin/wine64 or bin/wine.
    var loader: URL {
        let candidates = [
            wineLib.appendingPathComponent("x86_64-unix/wine"),
            bin.appendingPathComponent("wine64"),
            bin.appendingPathComponent("wine"),
        ]
        return candidates.first(where: \.exists) ?? candidates[0]
    }
    var wineserver: URL { bin.appendingPathComponent("wineserver") }

    var isValid: Bool { loader.exists && wineserver.exists }

    var version: String {
        let raw = (try? String(contentsOf: bundle.appendingPathComponent("version"), encoding: .utf8)) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    var displayName: String { Engine.displayName(for: name) }

    /// "WS12WineSikarugir11.0_1" -> "Sikarugir 11.0 (rev 1)"
    static func displayName(for name: String) -> String {
        var s = name
        if let range = s.range(of: #"^WS\d+"#, options: .regularExpression) { s.removeSubrange(range) }
        if s.hasPrefix("Wine") { s.removeFirst(4) }
        s = s.replacingOccurrences(of: "WhiskyWine", with: "Whisky")
        var revision: String?
        if let range = s.range(of: #"_\d+$"#, options: .regularExpression) {
            revision = String(s[range].dropFirst())
            s.removeSubrange(range)
        }
        if let range = s.range(of: #"\d"#, options: .regularExpression) {
            s.insert(" ", at: range.lowerBound)
        }
        s = s.replacingOccurrences(of: "CX", with: "CrossOver ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if let revision { s += " (rev \(revision))" }
        return s
    }
}

/// The shared support files (MoltenVK, GStreamer, DXVK/DXMT/D3DMetal, …) extracted from a Sikarugir wrapper template.
struct Runtime: Hashable {
    let name: String
    let directory: URL

    var contents: URL { directory.appendingPathComponent("Contents", isDirectory: true) }
    var frameworks: URL { contents.appendingPathComponent("Frameworks", isDirectory: true) }
    var gstreamerLibraries: URL { frameworks.appendingPathComponent("GStreamer.framework/Libraries", isDirectory: true) }
    var renderers: URL { frameworks.appendingPathComponent("renderer", isDirectory: true) }
    var vulkanICDs: URL { contents.appendingPathComponent("Resources/vulkan/icd.d", isDirectory: true) }
    var tools: URL { contents.appendingPathComponent("Tools", isDirectory: true) }

    var isValid: Bool { frameworks.exists && renderers.exists }

    func renderer(_ name: String) -> URL { renderers.appendingPathComponent(name, isDirectory: true) }

    func icd(for driver: VulkanDriver) -> URL {
        switch driver {
        case .moltenVK: vulkanICDs.appendingPathComponent("MoltenVK_icd.json")
        case .kosmicKrisp: vulkanICDs.appendingPathComponent("kosmickrisp_mesa_icd.json")
        }
    }

    struct Component: Identifiable {
        let name: String
        let version: String
        var id: String { name }
    }

    var components: [Component] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: renderers.path)) ?? []
        return names.sorted().compactMap { name in
            guard renderer(name).isDirectoryURL else { return nil }
            let raw = (try? String(contentsOf: renderer(name).appendingPathComponent("version"), encoding: .utf8)) ?? ""
            let version = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? "—"
            return Component(name: name, version: version)
        }
    }
}
