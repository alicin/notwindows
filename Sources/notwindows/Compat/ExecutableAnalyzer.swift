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
        if let pe = PEFile(url: executable) {
            report.is64Bit = pe.is64Bit
            report.imports = pe.importedDLLs
            report.isDotNet = pe.isDotNet || report.imports.contains("mscoree.dll")
            report.productName = pe.versionString("ProductName")
            report.companyName = pe.versionString("CompanyName")
        }

        let folder = executable.deletingLastPathComponent()
        let roots = [folder, folder.deletingLastPathComponent(), folder.deletingLastPathComponent().deletingLastPathComponent()]
        let listings = roots.map { root -> Set<String> in
            Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).map { $0.lowercased() })
        }
        let near = listings[0]
        let everything = listings.reduce(into: Set<String>()) { $0.formUnion($1) }

        report.engine = engine(executable: executable, near: near, everything: everything)
        report.antiCheat = antiCheatMarkers.filter { marker in marker.files.contains(where: everything.contains) }.map(\.name)
        report.hasSteamAPI = near.contains("steam_api.dll") || near.contains("steam_api64.dll")
        return report
    }

    private static func engine(executable: URL, near: Set<String>, everything: Set<String>) -> ExecutableReport.GameEngine? {
        let name = executable.lastPathComponent.lowercased()
        if near.contains("unityplayer.dll") || near.contains(where: { $0.hasSuffix("_data") }) { return .unity }
        if name.hasSuffix("-win64-shipping.exe") || name.hasSuffix("-wingdk-shipping.exe") || executable.path.contains("/Binaries/Win64/") || everything.contains("engine") && everything.contains(where: { $0.hasSuffix(".uproject") }) {
            return .unreal
        }
        if near.contains("hl2.exe") || near.contains("bin") && near.contains("platform") { return .source }
        if near.contains("data.win") { return .gameMaker }
        if near.contains("renpy") { return .renPy }
        if near.contains("rgss3a.dll") || near.contains(where: { $0.hasPrefix("rgss") && $0.hasSuffix(".dll") }) || near.contains("nw.dll") && near.contains("www") { return .rpgMaker }
        return nil
    }
}

/// Mac-specific defaults that no Linux-oriented database knows about.
enum MacRules {
    static func suggestions(for report: ExecutableReport, executable: URL) -> [CompatSuggestion] {
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

        let redistributables: [(prefixes: [String], verb: String, recommended: Bool)] = [
            (["mfc140", "mfc140u"], "vcrun2022", true),
            (["msvcp140", "vcruntime140"], "vcrun2022", false),
            (["msvcp120", "msvcr120", "mfc120"], "vcrun2013", true),
            (["msvcp110", "msvcr110", "mfc110"], "vcrun2012", true),
            (["msvcp100", "msvcr100", "mfc100"], "vcrun2010", true),
            (["msvcp90", "msvcr90", "mfc90"], "vcrun2008", true),
            (["msvcp80", "msvcr80", "mfc80"], "vcrun2005", true),
            (["mfc42"], "mfc42", true),
            (["d3dx9_"], "d3dx9", true),
            (["d3dx10_"], "d3dx10", true),
            (["d3dx11_"], "d3dx11_43", true),
            (["d3dcompiler_43"], "d3dcompiler_43", true),
            (["d3dcompiler_47"], "d3dcompiler_47", false),
            (["xactengine", "x3daudio", "xaudio2_0", "xaudio2_1", "xaudio2_2", "xaudio2_3", "xaudio2_4", "xaudio2_5", "xaudio2_6", "xaudio2_7"], "xact", !report.is64Bit),
            (["physxloader", "physx3", "physxcore", "physxcudart"], "physx", true),
            (["dplayx", "dpnet"], "directplay", true),
            (["msxml3"], "msxml3", false),
        ]
        for entry in redistributables {
            let hits = entry.prefixes.flatMap { report.imports(prefix: $0) }
            guard let first = hits.first else { continue }
            let reason = entry.recommended
                ? "Imports \(first). Wine's built-in version is often incomplete for it."
                : "Imports \(first). Wine has a built-in copy that usually works; install this if the game crashes at start."
            add(.winetricks(entry.verb), reason, recommended: entry.recommended)
        }

        if report.isDotNet {
            add(.keepMono, ".NET program. Wine Mono runs most of these.")
            add(.winetricks("dotnet48"), ".NET program. Install the real .NET Framework if Wine Mono isn't enough.", recommended: false)
        }
        return result
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
}
