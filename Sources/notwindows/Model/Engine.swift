import Foundation

/// An installed Wine build in Sikarugir's `wswine.bundle` layout.
struct Engine: Identifiable, Hashable {
    let name: String
    let directory: URL

    var id: String { name }
    var bundle: URL { directory.appendingPathComponent("wswine.bundle", isDirectory: true) }
    var bin: URL { bundle.appendingPathComponent("bin", isDirectory: true) }
    /// CrossOver's wine32on64 builds run only 32-bit Windows programs, so their prefixes must be 32-bit too.
    var isWin32Only: Bool { bundle.appendingPathComponent("lib32on64").exists }
    var lib: URL { bundle.appendingPathComponent(isWin32Only ? "lib32on64" : "lib", isDirectory: true) }
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

    var family: EngineFamily { EngineFamily(engineName: name) }

    /// What this build's ntdll picks up from the environment. Sikarugir's loads renderers and rosettax87 that way;
    /// upstream Wine and some CrossOver builds don't, so those settings can't apply to them.
    var capabilities: Capabilities { Capabilities.of(self) }

    struct Capabilities: Equatable {
        var rendererHooks: Bool
        var rosettaX87: Bool

        private static let lock = NSLock()
        nonisolated(unsafe) private static var cache: [String: Capabilities] = [:]

        static func of(_ engine: Engine) -> Capabilities {
            let candidates = ["x86_64-unix/ntdll.so", "ntdll.so", "i386-unix/ntdll.so"].map { engine.wineLib.appendingPathComponent($0) }
            // Without an ntdll to read, fall back to what notwindows assumed before it checked: Sikarugir's hooks,
            // except in CrossOver's 32-bit builds.
            guard let ntdll = candidates.first(where: \.exists) else {
                return Capabilities(rendererHooks: !engine.isWin32Only, rosettaX87: !engine.isWin32Only)
            }
            lock.lock()
            defer { lock.unlock() }
            if let cached = cache[ntdll.path] { return cached }
            let data = (try? Data(contentsOf: ntdll, options: .alwaysMapped)) ?? Data()
            let found = Capabilities(rendererHooks: data.range(of: Data("WINEDLLPATH_DXMT".utf8)) != nil,
                                     rosettaX87: data.range(of: Data("ROSETTA_X87_PATH".utf8)) != nil)
            cache[ntdll.path] = found
            return found
        }
    }

    var version: String {
        let raw = (try? String(contentsOf: bundle.appendingPathComponent("version"), encoding: .utf8)) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    var displayName: String { Engine.displayName(for: name) }

    /// "WS12WineSikarugir11.0_1" -> "Sikarugir 11.0 (rev 1)", "WS11WineCX32Bit21.2.0" -> "CrossOver 21.2.0 (32-bit)"
    static func displayName(for name: String) -> String {
        // Gcenx's upstream builds: "wine-staging-11.18" -> "Wine Staging 11.18"
        if name.hasPrefix("wine-") {
            let parts = name.split(separator: "-")
            guard parts.count >= 3 else { return name }
            let channel = parts[1] == "stable" ? "" : " " + parts[1].capitalized
            return "Wine\(channel) \(parts[2...].joined(separator: "-"))"
        }
        var s = name
        if let range = s.range(of: #"^WS\d+"#, options: .regularExpression) { s.removeSubrange(range) }
        let is32Bit = s.contains("32Bit")
        s = s.replacingOccurrences(of: "32Bit", with: "")
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
        if s.hasPrefix(" ") { s = "Wine" + s }
        s = s.replacingOccurrences(of: "CX", with: "CrossOver ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if let revision { s += " (rev \(revision))" }
        if is32Bit { s += " (32-bit)" }
        return s
    }
}

/// Wine builds grouped the way people pick them: by who makes them and what they're for.
enum EngineFamily: String, CaseIterable, Identifiable {
    case sikarugir, crossOver, crossOver32, gptk, whisky, wineStaging, wineDevel, wine
    var id: String { rawValue }

    init(engineName name: String) {
        switch true {
        case name.hasPrefix("wine-staging"): self = .wineStaging
        case name.hasPrefix("wine-devel"): self = .wineDevel
        case name.hasPrefix("wine-"): self = .wine
        case name.contains("CX32Bit"): self = .crossOver32
        case name.contains("WineCX"): self = .crossOver
        case name.contains("GPTK"): self = .gptk
        case name.contains("Whisky"): self = .whisky
        case name.contains("Sikarugir"): self = .sikarugir
        default: self = .wine
        }
    }

    var title: String {
        switch self {
        case .sikarugir: "Sikarugir"
        case .crossOver: "CrossOver"
        case .crossOver32: "CrossOver 32-bit"
        case .gptk: "Game Porting Toolkit"
        case .whisky: "Whisky"
        case .wineStaging: "Wine Staging"
        case .wineDevel: "Wine Devel"
        case .wine: "Wine"
        }
    }

    var summary: String {
        switch self {
        case .sikarugir: "Gcenx's Wine for Sikarugir, with DXMT, DXVK, D9VK and D3DMetal. The best start for most games."
        case .crossOver: "Builds of CodeWeavers' CrossOver sources."
        case .crossOver32: "Runs only 32-bit Windows programs, in a 32-bit prefix, drawing through WineD3D. Suits older games."
        case .gptk: "The Wine from Apple's Game Porting Toolkit, made for D3DMetal and DirectX 12."
        case .whisky: "The Wine build that shipped with the Whisky app."
        case .wineStaging: "Upstream Wine with the Staging patches, built by Gcenx. Draws through WineD3D."
        case .wineDevel: "Upstream development Wine, built by Gcenx. Draws through WineD3D."
        case .wine: "Upstream Wine releases."
        }
    }

    var symbol: String {
        switch self {
        case .sikarugir: "wineglass.fill"
        case .crossOver, .crossOver32: "arrow.triangle.swap"
        case .gptk: "apple.logo"
        case .whisky: "drop.fill"
        case .wineStaging: "flask.fill"
        case .wineDevel: "hammer.fill"
        case .wine: "cube.fill"
        }
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
