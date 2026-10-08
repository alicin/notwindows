import Foundation
import Testing
@testable import notwindows

struct WineEnvironmentTests {
    let engine = Engine(name: "WS12WineSikarugir11.0_1", directory: URL(fileURLWithPath: "/E"))
    let runtime = Runtime(name: "Template-1.0.21", directory: URL(fileURLWithPath: "/R"))
    let prefix = URL(fileURLWithPath: "/P")

    func env(_ change: (inout GameSettings) -> Void = { _ in }) -> [String: String] {
        var settings = GameSettings()
        change(&settings)
        return WineEnvironment.make(engine: engine, runtime: runtime, prefix: prefix, settings: settings,
                                    cacheDirectory: URL(fileURLWithPath: "/C"), base: ["HOME": "/Users/test", "UNRELATED_VAR": "x"])
    }

    @Test func baseEnvironment() {
        let e = env()
        #expect(e["WINEPREFIX"] == "/P")
        #expect(e["SikarugirAppWine11"] == "1")
        #expect(e["HOME"] == "/Users/test")
        #expect(e["UNRELATED_VAR"] == nil)
        #expect(e["PATH"]?.hasPrefix("/E/wswine.bundle/bin:") == true)
        #expect(e["DYLD_FALLBACK_LIBRARY_PATH"]?.hasPrefix("/E/wswine.bundle/lib:/R/Contents/Frameworks:") == true)
    }

    @Test func defaultRenderersMatchSikarugir() {
        let e = env { $0.vulkanDriver = .moltenVK }
        #expect(e["WINEDLLPATH_DXMT"] == "/R/Contents/Frameworks/renderer/dxmt/wine")
        #expect(e["WINEDLLPATH_PREPEND"] == "/R/Contents/Frameworks/renderer/dxmt/wine")
        #expect(e["WINEDLLPATH_D9VK"] == "/R/Contents/Frameworks/renderer/d9vk/wine")
        #expect(e["WINEDLLPATH_CNCD"] == "/R/Contents/Frameworks/renderer/cnc_ddraw/wine")
        #expect(e["WINEDLLPATH_DXVK"] == nil)
        #expect(e["WINEDLLPATH_D3DMETAL"] == nil)
        #expect(e["VK_DRIVER_FILES"] == "/R/Contents/Resources/vulkan/icd.d/MoltenVK_icd.json")
    }

    @Test func d3dmetalReplacesDXMT() {
        let e = env { $0.direct3DBackend = .d3dmetal }
        #expect(e["WINEDLLPATH_D3DMETAL"] == "/R/Contents/Frameworks/renderer/d3dmetal/wine")
        #expect(e["CX_D3DMETALPATH"] == "/R/Contents/Frameworks/renderer/d3dmetal/external")
        #expect(e["WINEDLLPATH_DXMT"] == nil)
    }

    @Test func dxvkFollowsVulkanDriver() {
        #expect(env { $0.direct3DBackend = .dxvk; $0.vulkanDriver = .kosmicKrisp }["WINEDLLPATH_DXVK"]?.contains("/dxvk3/") == true)
        #expect(env { $0.direct3DBackend = .dxvk; $0.vulkanDriver = .moltenVK }["WINEDLLPATH_DXVK"]?.contains("/dxvk/") == true)
        #expect(env { $0.direct3DBackend = .dxvk; $0.vulkanDriver = .kosmicKrisp; $0.dxvkVersion = .legacy }["WINEDLLPATH_DXVK"]?.contains("/dxvk/") == true)
        #expect(env { $0.direct3DBackend = .dxvk }["DXVK_SHADER_CACHE_PATH"] == "/C/dxvk")
    }

    @Test func togglesAndOverrides() {
        let e = env {
            $0.msync = false
            $0.metalHUD = true
            $0.cncDDraw = false
            $0.skipGecko = true
            $0.dllOverrides = [DLLOverride(name: " dinput8 ", mode: .nativeThenBuiltin), DLLOverride(name: "", mode: .native)]
            $0.environment = [EnvironmentVariable(key: "WINEMSYNC", value: "1"), EnvironmentVariable(key: "FOO", value: "bar")]
        }
        #expect(e["MTL_HUD_ENABLED"] == "1")
        #expect(e["WINEDLLPATH_CNCD"] == nil)
        #expect(e["WINEDLLOVERRIDES"] == "mshtml=;dinput8=n,b")
        #expect(e["WINEMSYNC"] == "1")
        #expect(e["FOO"] == "bar")
    }
}

struct RegistryWriterTests {
    @Test func rendersMacDriverAndVersion() {
        var settings = GameSettings()
        settings.retinaMode = true
        settings.optionAsAlt = true
        settings.windowsVersion = .win7
        let doc = RegistryWriter.document(for: settings)
        #expect(doc.hasPrefix("REGEDIT4\r\n"))
        #expect(doc.contains(#"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#))
        #expect(doc.contains(#""RetinaMode"="Y""#))
        #expect(doc.contains(#""LeftOptionIsAlt"="Y""#))
        #expect(doc.contains(#""LeftCommandIsCtrl"="N""#))
        #expect(doc.contains(#""LogPixels"=dword:000000c0"#))
        #expect(doc.contains(#""Version"="win7""#))
    }

    @Test func fingerprintTracksRegistrySettingsOnly() {
        var a = GameSettings()
        var b = a
        b.metalHUD.toggle()
        #expect(a.registryFingerprint == b.registryFingerprint)
        a.retinaMode.toggle()
        #expect(a.registryFingerprint != b.registryFingerprint)
    }
}

struct MiscTests {
    @Test func splitsArguments() {
        #expect(CommandLineSplitter.split(#"-dx11  -w "C:\My Games\cfg.ini" """#) == ["-dx11", "-w", #"C:\My Games\cfg.ini"#, ""])
        #expect(CommandLineSplitter.split("") == [])
    }

    @Test func engineDisplayNames() {
        #expect(Engine.displayName(for: "WS12WineSikarugir11.0_1") == "Sikarugir 11.0 (rev 1)")
        #expect(Engine.displayName(for: "WS12WineCX24.0.7_7") == "CrossOver 24.0.7 (rev 7)")
        #expect(Engine.displayName(for: "WS12WineGPTK1.1_3") == "GPTK 1.1 (rev 3)")
        #expect(Engine.displayName(for: "WS12WhiskyWine2.5.0_3") == "Whisky 2.5.0 (rev 3)")
    }

    @Test func suggestsNamesFromFolders() {
        #expect(GameLibrary.suggestedName(for: URL(fileURLWithPath: "/x/Hollow Knight/hollow_knight.exe")) == "hollow knight")
        #expect(GameLibrary.suggestedName(for: URL(fileURLWithPath: "/x/Witcher 3/bin/x64/game.exe")) == "Witcher 3")
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let decoded = try JSONDecoder().decode(GameSettings.self, from: Data(#"{"metalHUD":true}"#.utf8))
        #expect(decoded.metalHUD)
        #expect(decoded.direct3DBackend == .dxmt)
    }

    @Test func roundTripsGame() throws {
        var game = Game(name: "Test", executablePath: "/tmp/a.exe")
        game.settings.direct3DBackend = .d3dmetal
        let data = try JSONEncoder().encode(game)
        let back = try JSONDecoder().decode(Game.self, from: data)
        #expect(back == game)
    }
}

struct WinetricksCatalogTests {
    @Test func parsesMetadataBlocks() {
        let script = """
        w_metadata vcrun2022 dlls \\
            title="Visual C++ 2015-2022 libraries" \\
            publisher="Microsoft" \\
            year="2022" \\
            media="download" \\
            conflicts="vcrun2015 vcrun2019" \\
            file1="vc_redist.x86.exe"

        load_vcrun2022()
        {
            w_metadata fake notacategory
        }
        w_metadata vd=off settings \\
            title_bg="something" \\
            title="Disable virtual desktop"
        w_metadata dotnet20sdk dlls \\
            title=".NET SDK" \\
            media="manual_download"
        """
        let verbs = WinetricksCatalog.parse(script)
        #expect(verbs.map(\.name) == ["vcrun2022", "vd=off", "dotnet20sdk"])
        #expect(verbs[0].title == "Visual C++ 2015-2022 libraries")
        #expect(verbs[0].publisher == "Microsoft")
        #expect(verbs[0].conflicts == ["vcrun2015", "vcrun2019"])
        #expect(verbs[0].needsDownload)
        #expect(verbs[1].category == .settings)
        #expect(verbs[1].title == "Disable virtual desktop")
        #expect(verbs[2].needsManualDownload)
    }

    @Test func readsInstalledVerbs() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        try "w_workaround_wine_bug-53925\nwebview2\ncorefonts\nwebview2\n".write(to: prefix.appendingPathComponent("winetricks.log"), atomically: true, encoding: .utf8)
        #expect(WinetricksCatalog.installedVerbs(in: prefix) == ["webview2", "corefonts"])
    }
}

struct WineRosettaTests {
    func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func placesAndRestoresFiles() throws {
        let game = try makeDir()
        let sources = try makeDir()
        defer { try? FileManager.default.removeItem(at: game); try? FileManager.default.removeItem(at: sources) }
        let dll = sources.appendingPathComponent("winerosetta.dll")
        let d9vk = sources.appendingPathComponent("d9vk-d3d9.dll")
        try Data("rosetta".utf8).write(to: dll)
        try Data("d9vk".utf8).write(to: d9vk)
        try Data("users own".utf8).write(to: game.appendingPathComponent("d3d9.dll"))

        try WineRosetta.sync(directory: game, enabled: true, dll: dll, d9vk: d9vk)
        #expect(try String(contentsOf: game.appendingPathComponent("d3d9.dll"), encoding: .utf8) == "rosetta")
        #expect(try String(contentsOf: game.appendingPathComponent("d9vk.dll"), encoding: .utf8) == "d9vk")
        #expect(try String(contentsOf: game.appendingPathComponent("d3d9.dll.notwindows-backup"), encoding: .utf8) == "users own")

        try WineRosetta.sync(directory: game, enabled: true, dll: dll, d9vk: nil)
        #expect(!game.appendingPathComponent("d9vk.dll").exists)
        #expect(try String(contentsOf: game.appendingPathComponent("d3d9.dll.notwindows-backup"), encoding: .utf8) == "users own")

        try WineRosetta.sync(directory: game, enabled: false, dll: dll, d9vk: nil)
        #expect(try String(contentsOf: game.appendingPathComponent("d3d9.dll"), encoding: .utf8) == "users own")
        #expect(!game.appendingPathComponent("d3d9.dll.notwindows-backup").exists)
        #expect(!game.appendingPathComponent(WineRosetta.markerName).exists)
    }

    @Test func overridesD3D9WhenEnabled() {
        var settings = GameSettings()
        settings.wineRosetta = true
        let env = WineEnvironment.make(engine: Engine(name: "E", directory: URL(fileURLWithPath: "/E")),
                                       runtime: Runtime(name: "R", directory: URL(fileURLWithPath: "/R")),
                                       prefix: URL(fileURLWithPath: "/P"), settings: settings, base: [:])
        #expect(env["WINEDLLOVERRIDES"]?.hasPrefix("d3d9=n,b") == true)
    }
}
