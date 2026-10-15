import Foundation
import Testing
@testable import notwindows

struct IniFileTests {
    static let falloutINI = "[General]\r\nSStartingCell=\r\nbUseThreadedAI=0\r\nsIntroSequence=Caf\u{E9}\r\n\r\n[Display]\r\niSize W=1024\r\n"

    @Test func keepsEncodingLineEndingsAndUntouchedLines() throws {
        let original = try #require(Self.falloutINI.data(using: .isoLatin1))
        var ini = try #require(IniFile(data: original))
        #expect(ini.encoding == .isoLatin1)
        #expect(ini.value(section: "general", key: "BUSETHREADEDAI") == "0")

        let changes = [
            ini.set(section: "General", key: "bUseThreadedAI", value: "1"),
            ini.set(section: "General", key: "iNumHWThreads", value: "2"),
            ini.set(section: "Display", key: "iSize W", value: "1920"),
            ini.set(section: "Display", key: "iSize W", value: "1920"),
            ini.set(section: "Audio", key: "fDefaultVolume", value: "1.0"),
        ]
        #expect(changes == [true, true, true, false, true])

        let expected = "[General]\r\nSStartingCell=\r\nbUseThreadedAI=1\r\nsIntroSequence=Caf\u{E9}\r\niNumHWThreads=2\r\n\r\n[Display]\r\niSize W=1920\r\n\r\n[Audio]\r\nfDefaultVolume=1.0\r\n"
        #expect(ini.data == expected.data(using: .isoLatin1))
    }

    @Test func keepsByteOrderMarksAndSpacing() throws {
        let text = "[Video]\nWidth = 800\n"
        var ini = try #require(IniFile(data: Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!))
        ini.set(section: "video", key: "width", value: "1512")
        #expect(ini.data == Data([0xFF, 0xFE]) + "[Video]\nWidth = 1512\n".data(using: .utf16LittleEndian)!)
    }

    @Test func editsFilesInPlaceKeepingABackupAndReadOnlyPermissions() throws {
        let folder = try temporaryFolder()
        let file = try makeFile("Fallout.ini", in: folder, contents: Self.falloutINI.data(using: .isoLatin1)!)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)

        #expect(try IniEditor.apply([("General", "bUseThreadedAI", "1")], to: file))
        #expect(try IniEditor.apply([("General", "iNumHWThreads", "2")], to: file))
        #expect(IniEditor.value(in: file, section: "General", key: "bUseThreadedAI") == "1")
        #expect(IniEditor.value(in: file, section: "General", key: "iNumHWThreads") == "2")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o444)

        let backup = folder.appendingPathComponent("Fallout.ini.notwindows-backup")
        #expect(try Data(contentsOf: backup) == Self.falloutINI.data(using: .isoLatin1))
        #expect(try !IniEditor.apply([("General", "x", "1")], to: folder.appendingPathComponent("Missing.ini")))
    }
}

struct NewCompatActionTests {
    /// A prefix whose user Documents folder holds a game's .ini, like Wine sets up.
    func prefixGame() throws -> (game: Game, documents: URL) {
        let prefix = try temporaryFolder()
        let documents = prefix.appendingPathComponent("drive_c/users/\(NSUserName())/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        var game = Game(name: "New Vegas", executablePath: prefix.appendingPathComponent("drive_c/Games/FNV/FalloutNV.exe").path)
        game.externalPrefixPath = prefix.path
        return (game, documents)
    }

    @Test func iniSettingsResolvePlaceholdersAndWaitForMissingFiles() throws {
        var (game, documents) = try prefixGame()
        let state = CompatState(screenSize: CGSize(width: 1920, height: 1243))
        let width = CompatAction.iniSetting(IniSetting(file: #"%DOCUMENTS%\My Games\FalloutNV\FalloutPrefs.ini"#, section: "Display", key: "iSize W", value: "%SCREEN_WIDTH%"))
        #expect(width.title == "FalloutPrefs.ini: iSize W = screen width")
        #expect(!width.isSatisfied(by: game, state: state))

        // Until the game creates the file, the change waits and counts as done.
        width.apply(to: &game, state: state)
        #expect(game.settings.iniEdits.count == 1 && game.settings.iniEdits[0].isPending)
        #expect(width.isSatisfied(by: game, state: state))

        let file = try makeFile("my games/falloutnv/FalloutPrefs.ini", in: documents, contents: Data("[Display]\r\niSize W=1024\r\n".utf8))
        #expect(game.path(forWindowsPath: #"%DOCUMENTS%\My Games\FalloutNV\FalloutPrefs.ini"#) == file)
        #expect(!width.isSatisfied(by: game, state: state))
        _ = try IniEditor.apply([("Display", "iSize W", state.expand("%SCREEN_WIDTH%"))], to: file)
        #expect(width.isSatisfied(by: game, state: state))

        width.apply(to: &game, state: state)
        #expect(game.settings.iniEdits.count == 1)
    }

    @Test func enginesAreChosenByNameOrFamily() {
        var game = Game(name: "The Movies", executablePath: "/tmp/MoviesSE.exe")
        let state = CompatState(engineName: "WS12WineSikarugir11.0_1",
                                installedEngines: ["WS12WineSikarugir11.0_1", "WS11WineCX32Bit22.1.1", "WS11WineCX32Bit21.2.0"])
        let action = CompatAction.engine(.family(.crossOver32))
        #expect(action.title == "Wine engine → CrossOver 32-bit")
        #expect(!action.isSatisfied(by: game, state: state))
        #expect(action.isAvailable(state: state))
        action.apply(to: &game, state: state)
        #expect(game.engineName == "WS11WineCX32Bit22.1.1")

        var running = state
        running.engineName = game.engineName
        #expect(action.isSatisfied(by: game, state: running))
        #expect(!CompatAction.engine(.family(.gptk)).isAvailable(state: state))
        #expect(CompatAction.engine(.named("WS11WineCX32Bit21.2.0")).isAvailable(state: state))
    }

    @Test func togglesDisplayAndCPUSettings() {
        var game = Game(name: "Game", executablePath: "/tmp/game.exe")
        let actions: [CompatAction] = [.advertiseAVX(false), .retina(true), .vulkanDriver(.moltenVK), .rosettaX87(true)]
        game.settings.vulkanDriver = .kosmicKrisp
        for action in actions {
            #expect(!action.isSatisfied(by: game, state: CompatState()))
            action.apply(to: &game)
            #expect(action.isSatisfied(by: game, state: CompatState()))
        }
    }

    @Test func conflictingIniValuesKeepTheFirst() {
        var report = CompatReport()
        let file = #"%DOCUMENTS%\My Games\Oblivion\Oblivion.ini"#
        report.suggestions = [
            CompatSuggestion(action: .iniSetting(IniSetting(file: file, section: "Display", key: "iSize W", value: "1920")), reason: "", source: .macRules, recommended: true),
            CompatSuggestion(action: .iniSetting(IniSetting(file: file.uppercased(), section: "display", key: "ISIZE W", value: "1024")), reason: "", source: .executable, recommended: true),
            CompatSuggestion(action: .iniSetting(IniSetting(file: file, section: "Display", key: "iSize H", value: "1080")), reason: "", source: .executable, recommended: true),
        ]
        report.deduplicate()
        #expect(report.suggestions.count == 2)
        #expect(report.suggestions.first?.action == .iniSetting(IniSetting(file: file, section: "Display", key: "iSize W", value: "1920")))
    }
}
