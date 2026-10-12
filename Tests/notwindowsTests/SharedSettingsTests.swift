import Foundation
import Testing
@testable import notwindows

@Suite(.serialized)
@MainActor
struct SharedSettingsTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("notwindows-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("NOTWINDOWS_HOME", home.path, 1)
    }

    private func sampleGame() -> Game {
        var game = Game(name: "ELDEN RING", executablePath: "/Users/someone/Games/ELDEN RING/eldenring.exe")
        game.arguments = "-windowed"
        game.engineName = "WS12WineSikarugir11.0_1"
        game.settings.direct3DBackend = .d3dmetal
        game.settings.dllOverrides = [DLLOverride(name: "dinput8", mode: .nativeThenBuiltin)]
        game.totalPlaytime = 3600
        game.isFavorite = true
        return game
    }

    @Test func roundTripsWithoutLocalDetails() throws {
        let shared = SharedSettings(game: sampleGame(), winetricks: ["vcrun2022"])
        let data = try shared.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users/someone"))
        #expect(!text.contains("totalPlaytime"))
        #expect(!text.contains("isFavorite"))
        #expect(try SharedSettings.decode(data) == shared)
    }

    @Test func rejectsFilesFromNewerVersions() throws {
        var shared = SharedSettings(game: sampleGame(), winetricks: [])
        shared.format = SharedSettings.currentFormat + 1
        #expect(throws: CocoaError.self) { try SharedSettings.decode(shared.encoded()) }
    }

    @Test func matchesBySteamAppOrExecutable() {
        let shared = SharedSettings(game: sampleGame(), winetricks: [])
        #expect(shared.matches(Game(name: "Elden Ring", executablePath: "/Volumes/Games/EldenRing.EXE")))
        #expect(!shared.matches(Game(name: "Sekiro", executablePath: "/Volumes/Games/sekiro.exe")))

        var steam = sampleGame()
        steam.steamAppID = 1245620
        var other = Game(name: "Renamed", executablePath: "/x/start_protected_game.exe")
        other.steamAppID = 1245620
        #expect(SharedSettings(game: steam, winetricks: []).matches(other))
    }

    @Test func importReplacesSettingsAndReportsWhatsMissing() throws {
        let library = GameLibrary(engines: EngineManager(), runtime: RuntimeManager())
        var target = Game(name: "ELDEN RING", executablePath: "/Volumes/Games/eldenring.exe")
        target.isFavorite = false
        library.save(target)
        try FileManager.default.createDirectory(at: target.prefixURL, withIntermediateDirectories: true)
        try "vcrun2022\n".write(to: target.prefixURL.appendingPathComponent("winetricks.log"), atomically: true, encoding: .utf8)

        let shared = SharedSettings(game: sampleGame(), winetricks: ["vcrun2022", "d3dcompiler_47"])
        let result = library.importSettings(shared, into: target.id)

        let imported = try #require(library.game(target.id))
        #expect(imported.settings == shared.settings)
        #expect(imported.arguments == "-windowed")
        #expect(imported.executablePath == "/Volumes/Games/eldenring.exe")
        #expect(imported.isFavorite == false)
        #expect(imported.engineName == nil)
        #expect(result.missingEngine == "Sikarugir 11.0 (rev 1)")
        #expect(result.missingWinetricks == ["d3dcompiler_47"])
    }
}
