import Foundation
import Testing
@testable import notwindows

struct SharedSettingsFormatTests {
    /// What notwindows wrote before the metadata existed.
    static let formatOne = #"""
    {
      "arguments" : "-windowed",
      "engine" : "WS12WineSikarugir11.0_1",
      "executable" : "eldenring.exe",
      "format" : 1,
      "game" : "ELDEN RING",
      "settings" : { "direct3DBackend" : "d3dmetal", "rosettaX87" : false },
      "winetricks" : [ "vcrun2022" ]
    }
    """#

    @Test func readsFormatOneFiles() throws {
        let shared = try SharedSettings.decode(Data(Self.formatOne.utf8))
        #expect(shared.format == 1)
        #expect(shared.settings.direct3DBackend == .d3dmetal)
        #expect(shared.chip == nil && shared.note == nil && shared.summary.isEmpty)
    }

    @Test func carriesTheMacEngineAndNote() throws {
        var game = Game(name: "Fallout: New Vegas", executablePath: "/x/FalloutNV.exe")
        game.steamAppID = 22380
        game.settings.iniEdits = [IniEdit(setting: IniSetting(file: #"%DOCUMENTS%\My Games\FalloutNV\Fallout.ini"#, section: "General", key: "iNumHWThreads", value: "2"), isPending: false)]
        let machine = SharedSettings.Machine(model: "Mac17,2", chip: "Apple M5", macOS: "26.1")
        let shared = SharedSettings(game: game, winetricks: [], gameEngine: "Gamebryo", note: "  Smooth at 60 fps \n", machine: machine)
        #expect(shared.format == 2)
        #expect(shared.summary == "Apple M5 · macOS 26.1 · Gamebryo")
        #expect(shared.note == "Smooth at 60 fps")
        #expect(try SharedSettings.decode(shared.encoded()) == shared)
        #expect(SharedSettings(game: game, winetricks: [], note: "   ").note == nil)
    }
}

struct CommunitySetupTests {
    @Test func namesFoldersAndFindsTheGamesFiles() {
        #expect(CommunitySetups.folderName(steamAppID: 22380, game: "Fallout: New Vegas", executable: "FalloutNV.exe") == "22380-fallout-new-vegas")
        #expect(CommunitySetups.folderName(steamAppID: nil, game: "The Movies", executable: "MoviesSE.exe") == "moviesse.exe")

        let tree = #"""
        {"sha": "abc", "tree": [
          {"path": "community/setups", "type": "tree", "sha": "1"},
          {"path": "community/setups/22380-fallout-new-vegas/apple-m5-2026-10-14.notwindows", "type": "blob", "sha": "a1"},
          {"path": "community/setups/22380-fallout-new-vegas/README.md", "type": "blob", "sha": "a2"},
          {"path": "community/setups/223800-other-game/x.notwindows", "type": "blob", "sha": "a3"},
          {"path": "community/setups/moviesse.exe/m1.notwindows", "type": "blob", "sha": "a4"},
          {"path": "Sources/x.notwindows", "type": "blob", "sha": "a5"}
        ]}
        """#
        let newVegas = CommunitySetups.paths(inTree: Data(tree.utf8), steamAppID: 22380, executable: "FalloutNV.exe")
        #expect(newVegas.map(\.sha) == ["a1"])
        #expect(CommunitySetups.paths(inTree: Data(tree.utf8), steamAppID: nil, executable: "MoviesSE.EXE").map(\.sha) == ["a4"])
        #expect(CommunitySetups.rawURL("community/setups/a b/c.notwindows")?.absoluteString
                == "https://raw.githubusercontent.com/alicin/notwindows/main/community/setups/a%20b/c.notwindows")
    }

    @Test func fillsInGitHubsNewFilePage() throws {
        var game = Game(name: "Fallout: New Vegas", executablePath: "/x/FalloutNV.exe")
        game.steamAppID = 22380
        game.settings.rosettaX87 = true
        let database = try MacRuleDatabaseTests.shipped()
        for suggestion in database.suggestions(for: .init(steamAppID: 22380, executable: "FalloutNV.exe", engine: .gamebryo, is64Bit: false)) {
            suggestion.action.apply(to: &game)
        }
        let machine = SharedSettings.Machine(model: "Mac17,2", chip: "Apple M5", macOS: "26.1")
        let shared = SharedSettings(game: game, winetricks: ["xact"], gameEngine: "Gamebryo", note: "Smooth", machine: machine)
        let url = try #require(try CommunitySetups.submissionURL(for: shared, date: Date(timeIntervalSince1970: 1_791_000_000)))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/alicin/notwindows/new/main/community/setups/22380-fallout-new-vegas")
        #expect(components.queryItems?.first { $0.name == "filename" }?.value == "apple-m5-2026-10-03.notwindows")
        let value = try #require(components.queryItems?.first { $0.name == "value" }?.value)
        #expect(try SharedSettings.decode(Data(value.utf8)) == shared)
        // GitHub turns away request lines much past 8 KB.
        #expect(url.absoluteString.count < 8000)
    }
}

@Suite(.serialized)
@MainActor
struct CommunityImportTests {
    init() throws {
        setenv("NOTWINDOWS_HOME", try temporaryFolder().path, 1)
    }

    @Test func importedIniChangesAreMadeHere() throws {
        let prefix = try temporaryFolder()
        let ini = try makeFile("drive_c/users/\(NSUserName())/Documents/My Games/FalloutNV/Fallout.ini", in: prefix, contents: Data("[General]\nbUseThreadedAI=0\n".utf8))
        let library = GameLibrary(engines: EngineManager(), runtime: RuntimeManager())
        var target = Game(name: "Fallout: New Vegas", executablePath: "/x/FalloutNV.exe")
        target.externalPrefixPath = prefix.path
        library.save(target)

        var source = Game(name: "Fallout: New Vegas", executablePath: "/y/FalloutNV.exe")
        let setting = IniSetting(file: #"%DOCUMENTS%\My Games\FalloutNV\Fallout.ini"#, section: "General", key: "bUseThreadedAI", value: "1")
        source.settings.iniEdits = [IniEdit(setting: setting, isPending: false)]
        library.importSettings(SharedSettings(game: source, winetricks: []), into: target.id)

        #expect(IniEditor.value(in: ini, section: "General", key: "bUseThreadedAI") == "1")
        #expect(library.game(target.id)?.settings.iniEdits.map(\.isPending) == [false])
    }
}
