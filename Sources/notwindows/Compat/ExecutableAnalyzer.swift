import Foundation

enum ExecutableAnalyzer {
    private static let antiCheatMarkers: [(name: String, files: [String])] = [
        ("Easy Anti-Cheat", ["easyanticheat", "easyanticheat_eos_setup.exe", "easyanticheat_x64.dll", "start_protected_game.exe"]),
        ("BattlEye", ["battleye", "beservice.exe", "beservice_x64.exe"]),
        ("Riot Vanguard", ["vgk.sys", "vgc.exe"]),
        ("EA Javelin", ["eaanticheat.gameservicelauncher.exe", "eaanticheat.installer.exe"]),
        ("nProtect GameGuard", ["gameguard", "gamemon.des"]),
        ("XIGNCODE3", ["xigncode", "x3.xem"]),
        ("PunkBuster", ["pbsvc.exe", "pb"]),
    ]

    static func analyze(_ executable: URL) -> ExecutableReport {
        var report = ExecutableReport()
        let pe = PEFile(url: executable)
        if let pe {
            report.is64Bit = pe.is64Bit
            report.imports = pe.importedDLLs
            report.isDotNet = pe.isDotNet || report.imports.contains("mscoree.dll")
            report.productName = pe.versionString("ProductName")
            report.companyName = pe.versionString("CompanyName")
            report.hasSteamStub = pe.sections.contains { $0.name == ".bind" }
            if !report.isDotNet { report.x87 = X87Scanner.measure(pe) }
        }

        let folder = executable.deletingLastPathComponent()
        let roots = [folder, folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        let listings = roots.map(listing)
        let near = listings[0]
        let everything = listings.reduce(into: Set<String>()) { $0.formUnion($1) }

        if let (engine, detail) = engine(executable: executable, pe: pe, near: near, everything: everything) {
            report.engine = engine
            report.engineDetail = detail
        }
        report.antiCheat = antiCheatMarkers.filter { marker in marker.files.contains(where: everything.contains) }.map(\.name)
        report.hasSteamAPI = near.contains("steam_api.dll") || near.contains("steam_api64.dll")
        report.launcherTarget = launcherTarget(for: executable)
        return report
    }

    /// Lowercased names of a folder's entries.
    private static func listing(_ folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { $0.lowercased() })
    }

    /// The real name of an entry found case-insensitively.
    private static func child(_ folder: URL, named lowercased: String) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { $0.lowercased() == lowercased }.map { folder.appendingPathComponent($0) }
    }

    private static func engine(executable: URL, pe: PEFile?, near: Set<String>, everything: Set<String>) -> (ExecutableReport.GameEngine, String?)? {
        let name = executable.lastPathComponent.lowercased()
        let stem = executable.deletingPathExtension().lastPathComponent.lowercased()
        let folder = executable.deletingLastPathComponent()

        if near.contains("unityplayer.dll") || near.contains(where: { $0.hasSuffix("_data") }) {
            return (.unity, unityDetail(folder: folder, stem: stem, near: near))
        }
        if let unreal = unrealVersion(executable: executable, pe: pe, name: name) { return (.unreal, unreal.isEmpty ? nil : unreal) }
        if near.contains("hl2.exe") || near.contains("bin") && near.contains("platform") { return (.source, nil) }
        if near.contains("data.win") { return (.gameMaker, nil) }
        if near.contains("renpy") { return (.renPy, nil) }
        if near.contains("rgss3a.dll") || near.contains(where: { $0.hasPrefix("rgss") && $0.hasSuffix(".dll") }) || near.contains("nw.dll") && near.contains("www") { return (.rpgMaker, nil) }

        // Bethesda's games keep .bsa/.ba2 archives and .esm masters in Data (Morrowind: "Data Files"). Creation, the
        // engine from Skyrim on, grew out of Gamebryo; Fallout 4 and Starfield moved to .ba2.
        for dataName in ["data", "data files"] where near.contains(dataName) {
            guard let data = child(folder, named: dataName) else { continue }
            let files = listing(data)
            if files.contains(where: { $0.hasSuffix(".ba2") }) || files.contains("skyrim.esm") { return (.creation, nil) }
            if files.contains(where: { $0.hasSuffix(".bsa") || $0.hasSuffix(".esm") }) { return (.gamebryo, nil) }
        }

        if near.contains("crysystem.dll") || near.contains(where: { $0.hasPrefix("cryrender") && $0.hasSuffix(".dll") }) { return (.cryEngine, nil) }

        if let idTech = idTechVersion(folder: folder, near: near) { return (.idTech, idTech) }

        if let pe {
            if contains(pe.data, "Gamebryo File Format") || contains(pe.data, "NetImmerse File Format") { return (.gamebryo, nil) }
            if contains(pe.data, "RenderWare") { return (.renderWare, nil) }
        }
        return nil
    }

    /// "2021.3 · IL2CPP": the version from the serialized data's header, and whether scripts were compiled ahead of time.
    private static func unityDetail(folder: URL, stem: String, near: Set<String>) -> String? {
        let runtime = near.contains("gameassembly.dll") ? "IL2CPP" : "Mono"
        let dataName = near.contains(stem + "_data") ? stem + "_data" : near.first { $0.hasSuffix("_data") }
        var version: String?
        if let dataName, let data = child(folder, named: dataName) {
            for file in ["globalgamemanagers", "maindata", "data.unity3d"] {
                guard let url = child(data, named: file), let handle = try? FileHandle(forReadingFrom: url) else { continue }
                let head = String(decoding: ((try? handle.read(upToCount: 4096)) ?? Data()).map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self)
                try? handle.close()
                if let match = head.range(of: #"\b(20\d\d|[3-6])\.\d+\.\d+[abfp]\d+"#, options: .regularExpression) {
                    version = head[match].split(separator: ".").prefix(2).joined(separator: ".")
                    break
                }
            }
        }
        return [version, runtime].compactMap { $0 }.joined(separator: " · ")
    }

    /// "5", "4", "3", or "" for an Unreal game whose major version didn't show; nil when it isn't Unreal.
    private static func unrealVersion(executable: URL, pe: PEFile?, name: String) -> String? {
        let binaries = executable.deletingLastPathComponent()
        let isInBinaries = binaries.deletingLastPathComponent().lastPathComponent.lowercased() == "binaries"
        let root = binaries.deletingLastPathComponent().deletingLastPathComponent()
        let shipping = name.hasSuffix("-shipping.exe")
        // UE4/5: <Root>/<Project>/Binaries/Win64/<Project>-Win64-Shipping.exe next to <Root>/Engine.
        if shipping || isInBinaries && listing(root.deletingLastPathComponent()).contains("engine") {
            // Builds embed their branch name, e.g. "++UE5+Release-5.1", as UTF-16.
            if let data = pe?.data {
                for major in ["5", "4"] where contains(data, "+UE\(major)+", utf16: true) || contains(data, "+UE\(major)+") { return major }
            }
            return shipping || listing(root.deletingLastPathComponent()).contains("engine") ? "" : nil
        }
        // UE3: <Root>/Binaries/Win32/<Game>.exe next to <Root>/<Game>Game/CookedPC.
        if isInBinaries {
            let isUE3 = listing(root).contains { name in
                name.hasSuffix("game") && child(root, named: name).map { listing($0).contains { $0.hasPrefix("cookedpc") } } == true
            }
            if isUE3 { return "3" }
        }
        return nil
    }

    /// id Software's engines by their archive formats: .pk3 (id Tech 3), .pk4 (4), .resources (6, or 7 with a package map).
    private static func idTechVersion(folder: URL, near: Set<String>) -> String? {
        for name in near where name.hasPrefix("base") || name == "main" {
            guard let base = child(folder, named: name) else { continue }
            let files = listing(base)
            if files.contains(where: { $0.hasSuffix(".pk4") }) { return "4" }
            if files.contains(where: { $0.hasSuffix(".pk3") }) { return "3" }
            if files.contains(where: { $0.hasSuffix(".resources") }) { return files.contains("packagemapspec.json") ? "7" : "6" }
        }
        return nil
    }

    private static let launcherSkips = ["unins", "setup", "install", "redist", "crash", "report", "update", "config", "editor", "server"]

    /// A launcher next to a much bigger executable is usually a settings or patch front end for that game. Launchers
    /// often reset settings or show a window Wine handles badly, and the game itself runs without them.
    static func launcherTarget(for executable: URL) -> String? {
        let stem = executable.deletingPathExtension().lastPathComponent.lowercased()
        guard stem.contains("launcher") else { return nil }
        let folder = executable.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let size = (try? executable.resourceValues(forKeys: Set(keys)))?.fileSize,
              let siblings = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        let base = stem.replacingOccurrences(of: "launcher", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " _-."))
        let candidates = siblings.compactMap { url -> (url: URL, size: Int, related: Bool)? in
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            guard url.pathExtension.lowercased() == "exe", url != executable, !name.contains("launcher"),
                  !launcherSkips.contains(where: name.contains),
                  let bytes = (try? url.resourceValues(forKeys: Set(keys)))?.fileSize, bytes >= max(2 * size, 2_000_000) else { return nil }
            return (url, bytes, !base.isEmpty && (name.hasPrefix(base) || base.hasPrefix(name)))
        }
        // FalloutNVLauncher.exe → FalloutNV.exe: a name that shares the launcher's beats a merely bigger file.
        let best = candidates.max { ($0.related ? 1 : 0, $0.size) < ($1.related ? 1 : 0, $1.size) }
        return best?.url.lastPathComponent
    }

    static func contains(_ data: Data, _ text: String, utf16: Bool = false) -> Bool {
        let needle = utf16 ? Data(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) : Data(text.utf8)
        return data.withUnsafeBytes { haystack in
            needle.withUnsafeBytes { pattern in
                guard let base = haystack.baseAddress, let needleBase = pattern.baseAddress else { return false }
                return memmem(base, haystack.count, needleBase, pattern.count) != nil
            }
        }
    }
}

/// Mac-specific defaults that no Linux-oriented database knows about.
enum MacRules {
    /// What the rules need to know about the game beyond its executable.
    struct Context {
        var installFolder: URL?
        var prefix: URL?
        /// The engine can start games through rosettax87.
        var supportsRosettaX87 = true
        var isSteamGame = false
    }

    /// Redistributables by the DLLs that give them away. Recommended ones are those Wine's built-in copies often
    /// fall short for.
    static let redistributables: [(prefixes: [String], verb: String, recommended: Bool)] = [
        (["mfc140", "mfc140u"], "vcrun2022", true),
        (["msvcp140", "vcruntime140", "concrt140"], "vcrun2022", false),
        (["msvcp120", "msvcr120", "mfc120"], "vcrun2013", true),
        (["msvcp110", "msvcr110", "mfc110"], "vcrun2012", true),
        (["msvcp100", "msvcr100", "mfc100"], "vcrun2010", true),
        (["msvcp90", "msvcr90", "mfc90"], "vcrun2008", true),
        (["msvcp80", "msvcr80", "mfc80"], "vcrun2005", true),
        (["msvcp71", "msvcr71", "mfc71"], "vcrun2003", true),
        (["mfc42"], "mfc42", true),
        (["d3dx9_"], "d3dx9", true),
        (["d3dx10_"], "d3dx10", true),
        (["d3dx11_"], "d3dx11_43", true),
        (["d3dcompiler_43"], "d3dcompiler_43", true),
        (["d3dcompiler_47"], "d3dcompiler_47", false),
        (["xactengine", "x3daudio", "xaudio2_0", "xaudio2_1", "xaudio2_2", "xaudio2_3", "xaudio2_4", "xaudio2_5", "xaudio2_6", "xaudio2_7"], "xact", false),
        (["physxloader", "physx3", "physxcore", "physxcudart"], "physx", true),
        (["dplayx", "dpnet"], "directplay", true),
        (["msxml3"], "msxml3", false),
        (["msxml6"], "msxml6", false),
        (["wmvcore", "wmasf"], "wmp10", false),
    ]

    /// The Winetricks verb that installs a DLL, e.g. "msvcp140.dll" → vcrun2022.
    static func verb(forDLL dll: String) -> (verb: String, recommended: Bool)? {
        let name = dll.lowercased()
        return redistributables.first { $0.prefixes.contains(where: name.hasPrefix) }.map { ($0.verb, $0.recommended) }
    }

    static func suggestions(for report: ExecutableReport, executable: URL, context: Context = Context()) -> [CompatSuggestion] {
        var result: [CompatSuggestion] = []
        func add(_ action: CompatAction, _ reason: String, recommended: Bool = true, source: CompatSource = .executable) {
            result.append(CompatSuggestion(action: action, reason: reason, source: source, recommended: recommended))
        }
        let imports = report.imports

        if imports.contains("d3d12.dll") {
            if report.is64Bit {
                add(.renderer(.d3dmetal), "Imports d3d12.dll. D3DMetal is the only Direct3D 12 path on macOS.")
            }
        } else if imports.contains("d3d11.dll") || imports.contains("dxgi.dll") || imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") || imports.contains("d3d10core.dll") {
            add(.renderer(.dxmt), "Imports Direct3D 10/11. DXMT translates it straight to Metal.")
            if report.engine == .unreal && report.is64Bit {
                add(.renderer(.d3dmetal), "Unreal Engine games often run better on D3DMetal if DXMT has glitches.", recommended: false, source: .macRules)
            }
        }

        if imports.contains("d3d9.dll") || imports.contains("d3d8.dll") {
            add(.direct3D9(.d9vk), "Imports \(imports.contains("d3d8.dll") ? "d3d8" : "d3d9").dll. D9VK is faster than WineD3D for Direct3D 8/9.")
        }
        if imports.contains("ddraw.dll") {
            add(.cncDDraw(true), "Imports ddraw.dll. cnc-ddraw fixes most DirectDraw games.")
        }

        if WineRosetta.isLegacyWoW(executable) {
            add(.wineRosetta(true), "32-bit World of Warcraft needs instructions Rosetta 2 can't run.", source: .macRules)
            add(.direct3D9(.d9vk), "WineRosetta hands Direct3D 9 to D9VK.", source: .macRules)
        }

        if let x87 = report.x87, context.supportsRosettaX87 {
            let measured = "\(Int((x87.share * 100).rounded()))% of its floating-point instructions are x87"
            switch x87.level {
            case .heavy:
                add(.rosettaX87(true), "\(measured), which Rosetta 2 runs slowly. rosettax87 often makes such games several times faster.", source: .macRules)
            case .moderate:
                add(.rosettaX87(true), "\(measured), which Rosetta 2 runs slowly. rosettax87 may speed it up.", recommended: false, source: .macRules)
            case .unknown where x87.isLegacyToolchain:
                add(.rosettaX87(true), "Its code is encrypted, so x87 use can't be measured, but it was built with Visual C++ 2010 or older, which compiles floating-point math to x87. Try rosettax87 if it runs slowly.",
                    recommended: false, source: .macRules)
            default:
                break
            }
        }

        if let target = report.launcherTarget, let folder = context.installFolder,
           let relative = executable.deletingLastPathComponent().appendingPathComponent(target).relativePath(from: folder) {
            add(.executable(relative), "\(executable.lastPathComponent) looks like a launcher for \(target). Launchers can reset settings or add a step, and the game starts without them.",
                recommended: false)
        }

        let nativeDLLs = context.prefix.map { NativeDLLs(prefix: $0, is64Bit: report.is64Bit) }
        for entry in redistributables {
            let hits = entry.prefixes.flatMap { report.imports(prefix: $0) }
            guard let first = hits.first else { continue }
            // Steam's redistributable installers or the game's own setup may have put Microsoft's DLL there already.
            if let nativeDLLs, hits.allSatisfy(nativeDLLs.contains) { continue }
            // Wine's XAudio2 copes with 64-bit games, but old 32-bit ones tend to need Microsoft's.
            let recommended = entry.verb == "xact" ? !report.is64Bit : entry.recommended
            let reason = recommended
                ? "Imports \(first). Wine's built-in version is often incomplete for it."
                : "Imports \(first). Wine has a built-in copy that usually works; install this if the game crashes at start."
            add(.winetricks(entry.verb), reason, recommended: recommended)
        }

        if report.isDotNet {
            add(.keepMono, ".NET program. Wine Mono runs most of these.")
            add(.winetricks("dotnet48"), ".NET program. Install the real .NET Framework if Wine Mono isn't enough.", recommended: false)
        }
        var seen = Set<CompatAction>()
        return result.filter { seen.insert($0.action).inserted }
    }

    static func warnings(for report: ExecutableReport) -> [String] {
        var warnings = report.antiCheat.map {
            "\($0) detected. Kernel-level anti-cheat usually blocks Wine, so online play may not work."
        }
        if report.engine == nil, report.directXLabel == nil, report.imports.isEmpty {
            warnings.append("Couldn't read this executable. It may be a launcher stub, packed, or not a Windows program.")
        }
        return warnings
    }

    static func notes(for report: ExecutableReport, context: Context = Context()) -> [CompatNote] {
        var notes: [CompatNote] = []
        if report.hasSteamStub {
            notes.append(CompatNote(text: context.isSteamGame
                                        ? "Uses Steam's DRM, so it only starts while Steam is signed in. notwindows waits for that before starting it."
                                        : "Uses Steam's DRM, so it only starts while the Windows Steam client is running and signed in, in the same prefix.",
                                    source: .executable, kind: .info))
        }
        if let x87 = report.x87, !context.supportsRosettaX87, x87.level == .heavy {
            notes.append(CompatNote(text: "Most of its floating-point math is x87, which rosettax87 would speed up, but this engine can't start games through rosettax87.",
                                    source: .executable, kind: .info))
        }
        return notes
    }
}

/// Microsoft's own DLLs in a prefix, as opposed to the stand-ins Wine puts there for its built-in ones.
struct NativeDLLs {
    let folder: URL

    init(prefix: URL, is64Bit: Bool) {
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        let wow64 = windows.appendingPathComponent("syswow64", isDirectory: true)
        folder = !is64Bit && wow64.isDirectoryURL ? wow64 : windows.appendingPathComponent("system32", isDirectory: true)
    }

    func contains(_ dll: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(dll.lowercased())) else { return false }
        defer { try? handle.close() }
        // Wine's stand-ins carry "Wine builtin DLL" or "Wine placeholder DLL" right after the DOS header.
        let head = (try? handle.read(upToCount: 0x60)) ?? Data()
        return head.count >= 0x40 && head.range(of: Data("Wine ".utf8)) == nil
    }
}

extension URL {
    /// This path relative to `base`, or nil when it isn't inside it.
    func relativePath(from base: URL) -> String? {
        let path = standardizedFileURL.path, root = base.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }
}
