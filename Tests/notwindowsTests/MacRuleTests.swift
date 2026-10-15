import AppKit
import Foundation
import Testing
@testable import notwindows

struct MacRuleDatabaseTests {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/mac-rules.json")

    static func shipped() throws -> MacRuleDatabase { try MacRuleDatabase.decode(Data(contentsOf: file)) }

    func actions(_ subject: MacRuleDatabase.Subject) throws -> [CompatAction] {
        try Self.shipped().suggestions(for: subject).map(\.action)
    }

    @Test func shippedRulesDecodeCompletely() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.file)) as? [String: Any]
        let rules = try #require(json?["rules"] as? [[String: Any]])
        let database = try Self.shipped()
        #expect(database.rules.count == rules.count)
        for (rule, decoded) in zip(rules, database.rules) {
            #expect((rule["actions"] as? [Any])?.count == decoded.actions.count, "\(decoded.name) lost an action")
        }
    }

    @Test func newVegasGetsItsOwnAndTheEngineFixes() throws {
        let actions = try actions(.init(steamAppID: 22380, executable: "FalloutNVLauncher.exe", engine: .gamebryo, is64Bit: false))
        let prefs = #"%DOCUMENTS%\My Games\FalloutNV\FalloutPrefs.ini"#
        let expected: [CompatAction] = [
            .executable("FalloutNV.exe"), .rosettaX87(true), .retina(false),
            .iniSetting(IniSetting(file: prefs, section: "Display", key: "iSize W", value: "%SCREEN_WIDTH%")),
            .iniSetting(IniSetting(file: prefs, section: "Display", key: "iSize H", value: "%SCREEN_HEIGHT%")),
            .iniSetting(IniSetting(file: prefs, section: "Display", key: "bFull Screen", value: "1")),
            .iniSetting(IniSetting(file: prefs, section: "Display", key: "iMultiSample", value: "0")),
            .iniSetting(IniSetting(file: #"%DOCUMENTS%\My Games\FalloutNV\Fallout.ini"#, section: "General", key: "bUseThreadedAI", value: "1")),
            .iniSetting(IniSetting(file: #"%DOCUMENTS%\My Games\FalloutNV\Fallout.ini"#, section: "General", key: "iNumHWThreads", value: "2")),
            .dllOverride(name: "x3daudio1_6", mode: .nativeThenBuiltin), .dllOverride(name: "x3daudio1_7", mode: .nativeThenBuiltin),
            .dllOverride(name: "xaudio2_6", mode: .nativeThenBuiltin), .dllOverride(name: "xaudio2_7", mode: .nativeThenBuiltin),
        ]
        #expect(actions == expected)
    }

    @Test func fallout3AndOblivionGetTheGamebryoRule() throws {
        let fallout3 = try actions(.init(steamAppID: 22370, executable: "Fallout3Launcher.exe", engine: .gamebryo, is64Bit: false))
        #expect(fallout3.contains(.iniSetting(IniSetting(file: #"%DOCUMENTS%\My Games\Fallout3\Fallout.ini"#, section: "General", key: "iNumHWThreads", value: "2"))))
        #expect(fallout3.contains(.executable("Fallout3.exe")))
        #expect(fallout3.contains(.dllOverride(name: "xaudio2_7", mode: .nativeThenBuiltin)))

        let oblivion = try actions(.init(steamAppID: nil, executable: "Oblivion.exe", engine: .gamebryo, is64Bit: false))
        #expect(oblivion.contains(.iniSetting(IniSetting(file: #"%DOCUMENTS%\My Games\Oblivion\Oblivion.ini"#, section: "General", key: "bUseThreadedAI", value: "1"))))
        #expect(oblivion.contains(.iniSetting(IniSetting(file: #"%DOCUMENTS%\My Games\Oblivion\Oblivion.ini"#, section: "Display", key: "iSize W", value: "%SCREEN_WIDTH%"))))

        // Without a game rule naming its .ini, a Gamebryo game gets only the engine's DLL overrides.
        let unknown = try actions(.init(steamAppID: nil, executable: "Civ4.exe", engine: .gamebryo, is64Bit: false))
        #expect(unknown.count == 4)
        #expect(unknown.allSatisfy { if case .dllOverride = $0 { true } else { false } })
    }

    @Test func classicWoWAndTheMovies() throws {
        let wow = try actions(.init(steamAppID: nil, executable: "WoW.exe", engine: nil, is64Bit: false))
        #expect(wow == [.wineRosetta(true), .direct3D9(.d9vk), .rosettaX87(true)])
        #expect(try actions(.init(steamAppID: nil, executable: "Wow.exe", engine: nil, is64Bit: true)).isEmpty)

        let movies = try actions(.init(steamAppID: nil, executable: "MoviesSE.exe", engine: nil, is64Bit: false))
        #expect(movies == [.engine(.family(.crossOver32)), .winetricks("wmp10")])
    }

    @Test func skipsActionsItDoesNotKnowAndNewerFormats() throws {
        let json = #"""
        {"format": 1, "revision": 9, "rules": [{"name": "Future", "match": {"executables": ["a.exe"]},
          "actions": [{"teleport": true, "reason": "from a newer version"}, {"esync": false, "reason": "known", "recommended": false}]}]}
        """#
        let database = try MacRuleDatabase.decode(Data(json.utf8))
        let suggestions = database.suggestions(for: .init(steamAppID: nil, executable: "A.EXE", engine: nil, is64Bit: true))
        #expect(suggestions.map(\.action) == [.esync(false)])
        #expect(suggestions.first?.recommended == false)
        #expect(suggestions.first?.source == .macRule("Future"))

        let newer = json.replacingOccurrences(of: #""format": 1"#, with: #""format": 2"#)
        #expect(throws: CocoaError.self) { try MacRuleDatabase.decode(Data(newer.utf8)) }
    }

    @Test func macRulesOutrankLinuxFixes() {
        var report = CompatReport()
        report.suggestions = [
            CompatSuggestion(action: .dllOverride(name: "xaudio2_7", mode: .nativeThenBuiltin), reason: "", source: .macRule("Gamebryo engine"), recommended: true),
            CompatSuggestion(action: .dllOverride(name: "XAUDIO2_7", mode: .builtin), reason: "", source: .protonFixes(file: "22380.py"), recommended: true),
            CompatSuggestion(action: .rosettaX87(true), reason: "", source: .macRule("Fallout: New Vegas"), recommended: true),
            CompatSuggestion(action: .rosettaX87(true), reason: "", source: .macRules, recommended: false),
        ]
        report.deduplicate()
        #expect(report.suggestions.map(\.source) == [.macRule("Gamebryo engine"), .macRule("Fallout: New Vegas")])
    }
}

/// Smart Setup on a copy of a Steam New Vegas install, applied the way auto-apply does it.
@Suite(.serialized)
@MainActor
struct NewVegasSetupTests {
    let home: URL

    init() throws {
        home = try temporaryFolder()
        setenv("NOTWINDOWS_HOME", home.path, 1)
    }

    @Test func configuresNewVegasLikeAKnownGoodSetup() throws {
        let prefix = home.appendingPathComponent("prefix", isDirectory: true)
        let install = try makeFile("drive_c/Program Files (x86)/Steam/steamapps/common/Fallout New Vegas/FalloutNVLauncher.exe", in: prefix,
                                   contents: TestPE.build([.init(name: ".text", bytes: Data(TestPE.sseCode)), .init(name: ".bind", bytes: Data(count: 64))]))
            .deletingLastPathComponent()
        try makeFile("FalloutNV.exe", in: install, contents: TestPE.build([.init(name: ".text", bytes: Data(count: 2_500_000))]))
        try makeFile("Data/Fallout - Meshes.bsa", in: install)
        try makeFile("Data/FalloutNV.esm", in: install)
        let games = try makeFile("drive_c/users/\(NSUserName())/Documents/My Games/FalloutNV/Fallout.ini", in: prefix,
                                 contents: Data("[General]\r\nbUseThreadedAI=0\r\n\r\n[Display]\r\niSize W=1024\r\n".utf8)).deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: games.appendingPathComponent("Fallout.ini").path)
        try makeFile("FalloutPrefs.ini", in: games, contents: Data("[Display]\r\niSize W=1024\r\niSize H=663\r\nbFull Screen=0\r\niMultiSample=4\r\n".utf8))

        let library = GameLibrary(engines: EngineManager(), runtime: RuntimeManager())
        var game = Game(name: "Fallout: New Vegas", executablePath: install.appendingPathComponent("FalloutNVLauncher.exe").path)
        game.steamAppID = 22380
        game.installDirectory = install.path
        game.externalPrefixPath = prefix.path
        library.save(game)

        let executable = try #require(game.executableURL)
        let exe = ExecutableAnalyzer.analyze(executable)
        #expect(exe.engine == .gamebryo)
        #expect(exe.launcherTarget == "FalloutNV.exe")
        let context = MacRules.Context(installFolder: game.installFolder, prefix: game.prefixURL)
        let rules = CompatAdvisor.ruleSuggestions(try MacRuleDatabaseTests.shipped(), game: game, executable: executable, report: exe,
                                                  steamAppID: 22380, context: context)
        var report = CompatReport()
        report.suggestions = rules.suggestions + MacRules.suggestions(for: exe, executable: executable, context: context)
        report.deduplicate()

        let state = library.compatState(game.id)
        let unattended = report.suggestions.filter { $0.recommended && library.canApplyUnattended($0.action, to: game, state: state) }
        library.applyCompat(unattended, to: game.id)

        let configured = try #require(library.game(game.id))
        #expect(configured.executableURL?.lastPathComponent == "FalloutNV.exe")
        #expect(configured.settings.rosettaX87)
        #expect(!configured.settings.retinaMode)
        #expect(Set(configured.settings.dllOverrides.map { "\($0.name)=\($0.mode.rawValue)" }) == ["x3daudio1_6=n,b", "x3daudio1_7=n,b", "xaudio2_6=n,b", "xaudio2_7=n,b"])
        #expect(configured.settings.iniEdits.count == 6)
        #expect(configured.settings.iniEdits.allSatisfy { !$0.isPending })

        let fallout = games.appendingPathComponent("Fallout.ini")
        #expect(IniEditor.value(in: fallout, section: "General", key: "bUseThreadedAI") == "1")
        #expect(IniEditor.value(in: fallout, section: "General", key: "iNumHWThreads") == "2")
        let prefs = games.appendingPathComponent("FalloutPrefs.ini")
        #expect(IniEditor.value(in: prefs, section: "Display", key: "bFull Screen") == "1")
        #expect(IniEditor.value(in: prefs, section: "Display", key: "iMultiSample") == "0")
        if let screen = NSScreen.screens.first?.frame.size {
            #expect(IniEditor.value(in: prefs, section: "Display", key: "iSize W") == String(Int(screen.width)))
            #expect(IniEditor.value(in: prefs, section: "Display", key: "iSize H") == String(Int(screen.height)))
        }
        #expect(String(decoding: try Data(contentsOf: fallout), as: UTF8.self).contains("\r\niNumHWThreads=2\r\n"))
        #expect((try FileManager.default.attributesOfItem(atPath: fallout.path)[.posixPermissions] as? NSNumber)?.intValue == 0o444)
        let after = library.compatState(game.id)
        #expect(report.suggestions.filter { $0.recommended && !$0.action.isSatisfied(by: configured, state: after) }.isEmpty)
    }
}
