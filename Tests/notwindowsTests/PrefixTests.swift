import Foundation
import Testing
@testable import notwindows

@Suite(.serialized)
@MainActor
struct PrefixTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("notwindows-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("NOTWINDOWS_HOME", home.path, 1)
    }

    private func makePrefix(_ prefix: URL, executable relative: String) throws -> URL {
        let exe = prefix.appendingPathComponent("drive_c/\(relative)")
        try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        try Data().write(to: exe)
        return exe
    }

    @Test func findsThePrefixHoldingAFile() throws {
        let prefix = home.appendingPathComponent("loose/prefix", isDirectory: true)
        let exe = try makePrefix(prefix, executable: "Games/Thing/thing.exe")
        #expect(GameLibrary.containingPrefix(of: exe).map(GameLibrary.key) == GameLibrary.key(prefix))
        #expect(GameLibrary.containingPrefix(of: home.appendingPathComponent("elsewhere/game.exe")) == nil)
    }

    @Test func sharesAndHandsOffAPrefix() throws {
        let library = GameLibrary(engines: EngineManager(), runtime: RuntimeManager())
        var launcher = Game(name: "Launcher")
        launcher.engineName = "WS12WineSikarugir11.0_1"
        launcher.settings.msync = false
        library.save(launcher)
        let wow = try makePrefix(launcher.prefixURL, executable: "microbot/vanilla/WoW.exe")

        var client = Game(name: "Client", executablePath: wow.path)
        library.shareGame(&client, prefix: launcher.prefixURL)
        library.save(client)

        #expect(client.engineName == launcher.engineName)
        #expect(client.settings.msync == false)
        #expect(library.prefixOwner(of: client)?.id == launcher.id)
        #expect(library.prefixMates(of: launcher).map(\.id) == [client.id])
        #expect(library.prefixChoices.count == 1)
        #expect(library.prefixChoices.first?.gameNames.sorted() == ["Client", "Launcher"])
        #expect(library.processFragment(for: client) == "/microbot/vanilla/")

        try library.handOffPrefix(of: launcher)
        let moved = try #require(library.game(client.id))
        #expect(moved.externalPrefixPath == nil)
        #expect(moved.isPrefixInitialized)
        #expect(moved.executablePath == moved.driveC.appendingPathComponent("microbot/vanilla/WoW.exe").standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: moved.executablePath))
    }
}
