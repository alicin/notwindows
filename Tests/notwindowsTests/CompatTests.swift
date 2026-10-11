import Foundation
import Testing
@testable import notwindows

struct ExecutableAnalysisTests {
    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "exe", subdirectory: "Fixtures"))
    }

    @Test func readsDirectX12Executable() throws {
        let url = try fixture("dx12-64")
        let pe = try #require(PEFile(url: url))
        #expect(pe.is64Bit)
        #expect(pe.importedDLLs.isSuperset(of: ["d3d12.dll", "dxgi.dll"]))
        #expect(pe.versionString("ProductName") == "Fixture Quest: Remastered")
        #expect(pe.versionString("CompanyName") == "Bunnies Inc")

        let report = ExecutableAnalyzer.analyze(url)
        #expect(report.directXLabel == "DirectX 12")
        let actions = MacRules.suggestions(for: report, executable: url).map(\.action)
        #expect(actions.contains(.renderer(.d3dmetal)))
        #expect(!actions.contains(.renderer(.dxmt)))
    }

    @Test func readsDirectX9Executable() throws {
        let url = try fixture("dx9-32")
        let report = ExecutableAnalyzer.analyze(url)
        #expect(!report.is64Bit)
        #expect(report.directXLabel == "DirectX 9")
        #expect(WineRosetta.is32BitExecutable(url))
        let actions = MacRules.suggestions(for: report, executable: url).map(\.action)
        #expect(actions.contains(.direct3D9(.d9vk)))
        #expect(actions.contains(.cncDDraw(true)))
        #expect(actions.contains(.winetricks("d3dx9")))
    }
}

struct ProtonFixTranslatorTests {
    let script = #"""
    """Game fix for Example Game

    Needs native DirectPlay.
    """
    from protonfixes import util

    def main() -> None:
        util.protontricks('d3dcompiler_47 dxvk')
        util.protontricks('win7')
        util.winedll_override('dinput', util.OverrideOrder.NATIVE_BUILTIN)
        util.winedll_override("xaudio2_7", "n")
        util.set_environment('PROTON_USE_WINED3D', '1')
        util.set_environment('WINE_LARGE_ADDRESS_AWARE', '1')
        util.append_argument('-nointro -windowed')
        util.disable_esync()
        # util.protontricks('commented_out')
        util.regedit_add('HKCU\\Software\\Example', 'Key', 'REG_DWORD', '1')
    """#

    @Test func translatesCommonCalls() {
        let result = ProtonFixTranslator.translate(script, file: "gamefixes-steam/1.py", knownVerbs: ["d3dcompiler_47", "win7"])
        let actions = result.suggestions.map(\.action)
        #expect(actions.contains(.winetricks("d3dcompiler_47")))
        #expect(actions.contains(.windowsVersion(.win7)))
        #expect(actions.contains(.dllOverride(name: "dinput", mode: .nativeThenBuiltin)))
        #expect(actions.contains(.dllOverride(name: "xaudio2_7", mode: .native)))
        #expect(actions.contains(.environment(key: "WINE_LARGE_ADDRESS_AWARE", value: "1")))
        #expect(actions.contains(.argument("-nointro")))
        #expect(actions.contains(.argument("-windowed")))
        #expect(actions.contains(.esync(false)))
        #expect(!actions.contains(.winetricks("commented_out")))
        #expect(!actions.contains { if case .environment(let key, _) = $0 { key.hasPrefix("PROTON_") } else { false } })
        #expect(result.notes.contains { $0.text.contains("dxvk") })
        #expect(result.notes.contains { $0.text.contains("regedit_add") })
        #expect(result.suggestions.first?.reason == "Game fix for Example Game")
    }
}

struct LutrisTranslatorTests {
    @Test func translatesOverridesEnvAndWinetricks() {
        let script: [String: Any] = [
            "wine": ["overrides": ["ddraw": "n,b", "d3d8": "native"]],
            "system": ["env": ["WINEDEBUG": "-all", "__GL_SHADER_DISK_CACHE": 1]],
            "installer": [["task": ["name": "winetricks", "app": "corefonts dxvk winxp"]], ["move": ["src": "a", "dst": "b"]]],
        ]
        let actions = LutrisTranslator.translate(script, slug: "example", knownVerbs: ["corefonts", "winxp"]).map(\.action)
        #expect(actions.contains(.dllOverride(name: "ddraw", mode: .nativeThenBuiltin)))
        #expect(actions.contains(.dllOverride(name: "d3d8", mode: .native)))
        #expect(actions.contains(.environment(key: "WINEDEBUG", value: "-all")))
        #expect(!actions.contains { if case .environment(let key, _) = $0 { key.hasPrefix("__GL") } else { false } })
        #expect(actions.contains(.winetricks("corefonts")))
        #expect(actions.contains(.windowsVersion(.winxp)))
        #expect(!actions.contains(.winetricks("dxvk")))
    }
}

struct MatchingTests {
    @Test func scoresTitles() {
        #expect(TitleMatcher.score("The Witcher 3: Wild Hunt", "witcher3") > 0.6)
        #expect(TitleMatcher.score("The Witcher 3: Wild Hunt", "The Witcher 3 Wild Hunt GOTY") >= 0.75)
        #expect(TitleMatcher.score("Fallout: New Vegas", "FalloutNV") < 0.75)
        #expect(TitleMatcher.score("Diablo II", "Diablo 2") == 1)
        #expect(TitleMatcher.score("Hollow Knight", "Stardew Valley") == 0)
    }

    @Test func parsesUMUDatabaseWithQuotedFields() {
        let csv = """
        TITLE,STORE,CODENAME,UMU_ID,COMMON ACRONYM (Optional),NOTE (Optional),EXE_STRINGS (Optional)
        Trackmania,ubisoft,5595,umu-2225070,tm,"also known as 'Trackmania (2020)', not 2003",
        "Warhammer 40,000: Space Marine",gog,123,umu-55150,,,
        Duet Night Abyss,egs,58c7,umu-3950020,,,Duet Night Abyss/EMLauncher.exe

        """
        let entries = CompatSources.parseUMUDatabase(csv)
        #expect(entries.count == 3)
        #expect(entries[1].title == "Warhammer 40,000: Space Marine")
        #expect(entries[0].umuID == "umu-2225070")
        #expect(entries[2].exeStrings == ["Duet Night Abyss/EMLauncher.exe"])
    }
}

struct CompatActionTests {
    @Test func appliesAndDetectsSatisfaction() {
        var game = Game(name: "Test", executablePath: "/tmp/test.exe")
        let actions: [CompatAction] = [
            .renderer(.d3dmetal), .dllOverride(name: "dinput8", mode: .nativeThenBuiltin),
            .environment(key: "FOO", value: "1"), .argument("-windowed"), .esync(false),
        ]
        for action in actions { #expect(!action.isSatisfied(by: game, installedVerbs: [])) }
        for action in actions { action.apply(to: &game) }
        for action in actions { let satisfied = action.isSatisfied(by: game, installedVerbs: []); #expect(satisfied) }
        CompatAction.argument("-windowed").apply(to: &game)
        #expect(game.arguments == "-windowed -windowed")
        #expect(CompatAction.winetricks("vcrun2022").isSatisfied(by: game, installedVerbs: ["vcrun2022"]))
    }

    @Test func deduplicatesConflicts() {
        var report = CompatReport()
        report.suggestions = [
            CompatSuggestion(action: .renderer(.d3dmetal), reason: "fix", source: .protonFixes(file: "x"), recommended: true),
            CompatSuggestion(action: .renderer(.dxmt), reason: "exe", source: .executable, recommended: true),
            CompatSuggestion(action: .winetricks("d3dcompiler_47"), reason: "fix", source: .protonFixes(file: "x"), recommended: true),
            CompatSuggestion(action: .winetricks("d3dcompiler_47"), reason: "exe", source: .executable, recommended: false),
        ]
        report.deduplicate()
        #expect(report.suggestions.map(\.action) == [.renderer(.d3dmetal), .winetricks("d3dcompiler_47")])
        let allRecommended = report.suggestions.allSatisfy { $0.recommended }
        #expect(allRecommended)
    }
}

struct ProtonFixCommentTests {
    @Test func usesCommentAboveCallAsReason() {
        let script = """
        \"\"\"Game fix for Assetto Corsa\"\"\"
        from protonfixes import util

        def main() -> None:
            util.protontricks('dotnet48')
            # Fixes Content Manager (black windows)
            util.protontricks('d3dx11_43')
            util.protontricks('d3dcompiler_47')

            util.protontricks('win10')
        """
        let suggestions = ProtonFixTranslator.translate(script, file: "f.py", knownVerbs: []).suggestions
        let reasons = Dictionary(uniqueKeysWithValues: suggestions.map { ($0.action, $0.reason) })
        #expect(reasons[.winetricks("dotnet48")] == "Game fix for Assetto Corsa")
        #expect(reasons[.winetricks("d3dx11_43")] == "Fixes Content Manager (black windows)")
        #expect(reasons[.winetricks("d3dcompiler_47")] == "Game fix for Assetto Corsa")
        #expect(reasons[.windowsVersion(.win10)] == "Game fix for Assetto Corsa")
    }
}
