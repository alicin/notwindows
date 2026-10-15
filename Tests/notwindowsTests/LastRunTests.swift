import Foundation
import Testing
@testable import notwindows

struct LogDiagnosticsTests {
    static let log = #"""
    notwindows launch 2026-10-14T20:00:00Z
    WINEDEBUG=-all,err+module,err+macdrv,err+mscoree,trace+msgbox

    0024:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\Games\\Game\\Game.exe") not found
    0024:err:module:loader_init Importing dlls for L"C:\\Games\\Game\\Game.exe" failed, status c0000135
    0024:err:module:import_dll Library helper.dll (which is needed by L"C:\\Games\\Game\\Game.exe") not found
    0030:err:macdrv:macdrv_ChangeDisplaySettings No matching mode found 1024x768x32 @60!
    [S_API FAIL] SteamAPI_Init() failed; SteamAPI_IsSteamRunning() failed.
    0040:trace:msgbox:MSGBOX_OnInit L"Application load error 5:0000065434"
    0040:trace:msgbox:MSGBOX_OnInit L"This game requires a CPU with AVX support.\nIt will now close."
    0044:trace:msgbox:MSGBOX_OnInit L"Couldn't create the \"Main\" window."
    wine: Call from 7B012345 to unimplemented function d3dx9_43.dll.D3DXCreateEffectEx, aborting
    0050:err:module:import_dll Loading library foo.dll (which is needed by L"C:\\Games\\Game\\game.exe") failed (error c000007b).
    0060:err:mscoree:CLRRuntimeInfo_GetRuntimeHost Wine Mono is not installed
    wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001234 (thread 0124), starting debugger...
    """#

    @Test func findsFixesAndExplanations() {
        var game = Game(name: "Game", executablePath: "/tmp/Game.exe")
        game.settings.advertiseAVX = false
        game.settings.skipMono = true
        let diagnosis = LogDiagnostics.diagnose(Self.log, game: game, displaySizes: [CGSize(width: 1920, height: 1243), CGSize(width: 1512, height: 982)])

        #expect(diagnosis.suggestions.map(\.action) == [.winetricks("vcrun2022"), .advertiseAVX(true), .winetricks("d3dx9"), .keepMono])
        #expect(diagnosis.suggestions.allSatisfy { $0.source == .lastRun && $0.recommended })
        #expect(diagnosis.suggestions[0].reason == "Game.exe couldn't start because MSVCP140.dll is missing. vcrun2022 installs it.")

        let notes = diagnosis.notes.map(\.text)
        #expect(notes.contains { $0.contains("helper.dll is missing") })
        #expect(notes.contains { $0.contains("1024x768") && $0.contains("the display's own size, 1920x1243, or another it offers: 1512x982") })
        #expect(notes.contains { $0.contains("The game needs Steam (SteamAPI_IsSteamRunning() failed.)") })
        #expect(notes.contains { $0.contains("Steam's DRM refused to start the game (“Application load error 5:0000065434”)") })
        #expect(notes.contains("The game showed an error: “Couldn't create the \"Main\" window.”"))
        #expect(notes.contains { $0.contains("foo.dll is built for the other architecture") })
        #expect(notes.contains("The game crashed: page fault at 0000000140001234."))
    }

    @Test func staysQuietForCleanLogs() {
        let log = "0024:fixme:ntdll:NtQuerySystemInformation info_class 0xc6\nwarn:  DXVK-Sikarugir: No state cache file found\n"
        #expect(LogDiagnostics.diagnose(log, game: Game(name: "Game")).isEmpty)
        #expect(WineLogLevel.off.winedebug == "-all,err+module,err+macdrv,err+mscoree,trace+msgbox")
    }

    @Test func readsTheStartAndEndOfLongLogs() throws {
        let folder = try temporaryFolder()
        let start = "err:module:import_dll Library a.dll (which is needed by L\"x.exe\") not found\n"
        let end = "wine: Unhandled page fault on read access to 0 at address 1 (thread 2), starting debugger...\n"
        let log = try makeFile("last-run.log", in: folder, contents: Data((start + String(repeating: "x", count: 3000) + "\n" + end).utf8))
        let text = try #require(LogDiagnostics.readLog(log, limit: 1000))
        #expect(text.hasPrefix(start))
        #expect(text.hasSuffix(end))
        #expect(text.count < 1100)
    }
}

struct SessionTests {
    @Test func classifiesSessions() {
        let now = Date()
        #expect(PlaySession(start: now, duration: 3, exitCode: 5).isQuickCrash)
        #expect(!PlaySession(start: now, duration: 3, exitCode: 0).isQuickCrash)
        #expect(!PlaySession(start: now, duration: 3, exitCode: 9, wasStopped: true).isQuickCrash)
        #expect(!PlaySession(start: now, duration: 40, exitCode: 1).isQuickCrash)
        #expect(PlaySession(start: now, duration: 600, exitCode: 0).isLong)
    }

    @Test func knownGoodSetupsIgnoreListIdentifiers() {
        var game = Game(name: "Game", executablePath: "/tmp/game.exe")
        game.settings.dllOverrides = [DLLOverride(name: "xaudio2_7", mode: .nativeThenBuiltin)]
        game.settings.iniEdits = [IniEdit(setting: IniSetting(file: "%INSTALLDIR%\\a.ini", section: "S", key: "k", value: "1"), isPending: true)]
        let good = KnownGoodSetup(game: game, session: PlaySession(start: Date(), duration: 900))

        CompatAction.dllOverride(name: "xaudio2_7", mode: .nativeThenBuiltin).apply(to: &game)
        game.settings.iniEdits[0].isPending = false
        #expect(good.matches(game))

        game.settings.rosettaX87 = true
        game.engineName = "WS11WineCX32Bit21.2.0"
        #expect(!good.matches(game))
        good.restore(to: &game)
        #expect(good.matches(game))
        #expect(!game.settings.rosettaX87 && game.engineName == nil)
    }
}

@Suite(.serialized)
@MainActor
struct LastRunLibraryTests {
    init() throws {
        setenv("NOTWINDOWS_HOME", try temporaryFolder().path, 1)
    }

    @Test func learnsFromQuickCrashesAndLongSessions() async throws {
        let library = GameLibrary(engines: EngineManager(), runtime: RuntimeManager())
        let game = Game(name: "Crashy", executablePath: "/tmp/crashy.exe")
        library.save(game)
        try makeFile("last-run.log", in: game.logsDirectory, contents: Data(LogDiagnosticsTests.log.utf8))

        library.recordSession(PlaySession(start: Date(), duration: 2, exitCode: 3), for: game.id)
        await library.diagnoseLastRun(game.id)
        #expect(library.game(game.id)?.lastSession?.isQuickCrash == true)
        #expect(library.game(game.id)?.knownGood == nil)
        #expect(library.suggestions(for: game.id).first?.action == .winetricks("vcrun2022"))
        #expect(library.pendingSuggestionCount(game.id) == 2)

        library.recordSession(PlaySession(start: Date(), duration: 1800, exitCode: 0), for: game.id)
        let played = try #require(library.game(game.id))
        #expect(played.isKnownGood)
        #expect(library.pendingSuggestionCount(game.id) == 0)
        library.update(game.id) { $0.settings.retinaMode = true }
        #expect(library.game(game.id)?.isKnownGood == false)
        library.restoreKnownGood(game.id)
        #expect(library.game(game.id)?.isKnownGood == true)
    }
}
