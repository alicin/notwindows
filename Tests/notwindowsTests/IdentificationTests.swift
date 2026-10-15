import Foundation
import Testing
@testable import notwindows

/// Writes appinfo.vdf files the way the Steam client does.
enum TestAppInfo {
    static func build(magic: UInt32, apps: [(id: UInt32, info: VDF.Value)]) -> Data {
        var strings: [String] = []
        func le<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func key(_ name: String) -> Data {
            guard magic == 0x0756_4429 else { return Data(name.utf8) + Data([0]) }
            if let index = strings.firstIndex(of: name) { return le(UInt32(index)) }
            strings.append(name)
            return le(UInt32(strings.count - 1))
        }
        func object(_ pairs: [(key: String, value: VDF.Value)]) -> Data {
            var data = Data()
            for (name, value) in pairs {
                switch value {
                case .object(let children): data += Data([0x00]) + key(name) + object(children)
                case .string(let text):
                    if let number = Int32(text) { data += Data([0x02]) + key(name) + le(number) } else { data += Data([0x01]) + key(name) + Data(text.utf8) + Data([0]) }
                }
            }
            return data + Data([0x08])
        }
        var body = Data()
        for app in apps {
            let kv = object([("appinfo", app.info)])
            let header = Data(count: magic >= 0x0756_4428 ? 60 : 40)
            body += le(app.id) + le(UInt32(header.count + kv.count)) + header + kv
        }
        body += le(UInt32(0))
        guard magic == 0x0756_4429 else { return le(magic) + le(UInt32(1)) + body }
        let tableOffset = UInt64(16 + body.count)
        var table = le(UInt32(strings.count))
        for name in strings { table += Data(name.utf8) + Data([0]) }
        return le(magic) + le(UInt32(1)) + le(tableOffset) + body + table
    }

    static let newVegas: VDF.Value = .object([
        ("appid", .string("22380")),
        ("common", .object([("name", .string("Fallout: New Vegas")), ("type", .string("game"))])),
        ("config", .object([("launch", .object([
            ("0", .object([("executable", .string("FalloutNVLauncher.exe"))])),
            ("1", .object([("executable", .string("FalloutNV.exe")), ("arguments", .string("-beta")), ("config", .object([("BetaKey", .string("beta"))]))])),
            ("2", .object([("executable", .string("FalloutNV.app")), ("config", .object([("oslist", .string("macos"))]))])),
        ]))])),
        ("extended", .object([("installscript", .string("InstallScript.vdf"))])),
    ])
}

struct SteamAppInfoTests {
    @Test(arguments: [UInt32(0x0756_4427), 0x0756_4428, 0x0756_4429])
    func readsLaunchOptionsAndInstallScripts(magic: UInt32) throws {
        let other: VDF.Value = .object([("appid", .string("7")), ("common", .object([("name", .string("Steam Client"))]))])
        let data = TestAppInfo.build(magic: magic, apps: [(7, other), (22380, TestAppInfo.newVegas)])
        let apps = SteamAppInfo.parse(data, ids: [22380])
        let app = try #require(apps[22380])
        #expect(app["common"]?["name"]?.string == "Fallout: New Vegas")
        #expect(SteamAppInfo.launchOptions(app) == [.init(executable: "FalloutNVLauncher.exe", arguments: "", description: nil, betaKey: nil, osList: nil)])
        #expect(SteamAppInfo.installScript(app) == "InstallScript.vdf")
        #expect(SteamAppInfo.parse(Data("not appinfo".utf8), ids: [22380]).isEmpty)
    }

    @Test func suggestsSteamsExecutableAndArguments() throws {
        let folder = try temporaryFolder()
        let launcher = try makeFile("Game Launcher.exe", in: folder, contents: Data(count: 100_000))
        let game = try makeFile("Game.exe", in: folder, contents: Data(count: 3_000_000))
        try makeFile("bin/tool.exe", in: folder)
        let app: VDF.Value = .object([("config", .object([("launch", .object([
            ("0", .object([("executable", .string("Game Launcher.exe")), ("arguments", .string("-skipintro \"-config=a b\""))])),
        ]))]))])
        var entry = Game(name: "Game", executablePath: folder.appendingPathComponent("bin/tool.exe").path)
        entry.installDirectory = folder.path

        #expect(CompatAdvisor.steamLaunchSuggestions(app, game: entry, executable: entry.executableURL!).map(\.action) == [.executable("Game Launcher.exe")])
        #expect(CompatAdvisor.steamLaunchSuggestions(app, game: entry, executable: launcher).map(\.action) == [.argument("-skipintro"), .argument("-config=a b")])
        // The game a launcher starts is fine as it is.
        #expect(CompatAdvisor.steamLaunchSuggestions(app, game: entry, executable: game).isEmpty)
    }
}

struct WikiTests {
    static let pcGamingWiki = """
    {{Infobox game
    |cover        = Fallout New Vegas cover.jpg
    |engines      =
    {{Infobox game/row/engine|Gamebryo (TES Engine)}}
    |steam appid  = 22380
    |steam appid side = 2028016,72840
    }}
    {{API
    |direct3d versions      = 9.0c
    |direct3d notes         = <ref>{{Refcheck|user=Aemony|date=2022-11-30|comment=Fullscreen | more}}</ref>
    |windows 32-bit exe     = true
    |windows 64-bit exe     = false
    }}
    """

    @Test func readsPCGamingWikiInfoboxes() {
        let info = WikiGameInfo(page: "Fallout: New Vegas", wikitext: Self.pcGamingWiki)
        #expect(info.engines == ["Gamebryo (TES Engine)"])
        #expect(info.engine?.0 == .gamebryo)
        #expect(info.steamAppIDs == [22380])
        #expect(info.direct3DVersions == ["9.0c"])
        #expect(info.has32BitExecutable == true && info.has64BitExecutable == false)
        #expect(CompatAdvisor.wikiSuggestions(info, is64Bit: false).map(\.action) == [.direct3D9(.d9vk)])

        let modern = WikiGameInfo(page: "X", wikitext: "{{Infobox game\n|engines = {{Infobox game/row/engine|Unreal Engine 5}}\n}}\n{{API\n|direct3d versions = 11, 12\n}}")
        #expect(modern.engine?.0 == .unreal && modern.engine?.1 == "5")
        #expect(CompatAdvisor.wikiSuggestions(modern, is64Bit: true).map(\.action) == [.renderer(.d3dmetal)])
        #expect(CompatAdvisor.wikiSuggestions(modern, is64Bit: false).map(\.action) == [.renderer(.dxmt)])
    }

    @Test func readsAppleGamingWikiVerdicts() {
        let text = """
        {{Compatibility/macOS
        |native               = na
        |native notes         =
        |crossover            = playable
        |crossover notes      = Using [[CrossOver]] 21.2, sluggish performance (15fps-ish) on base M1 Mac Mini.<ref>{{Refcheck|user=X}}</ref>
        |wine                 = playable
        |wine notes           = Playable via '''porting kit'''.
        |parallels            = perfect
        }}
        """
        let mac = MacCompatibility(page: "Fallout: New Vegas", wikitext: text)
        #expect(mac.entries.map(\.method) == ["CrossOver", "Wine"])
        #expect(mac.notes.first?.text == "CrossOver: Playable. Using CrossOver 21.2, sluggish performance (15fps-ish) on base M1 Mac Mini.")
        #expect(mac.notes.last?.text == "Wine: Playable. Playable via porting kit.")
        #expect(mac.notes.allSatisfy { $0.kind == .info && $0.source == .appleGamingWiki("Fallout: New Vegas") })
        #expect(WikiText.template("API", in: "{{APIs|x=1}}") == nil)
    }
}
