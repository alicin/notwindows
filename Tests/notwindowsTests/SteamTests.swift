import Foundation
import Testing
@testable import notwindows

struct SteamLibraryTests {
    @Test func parsesVDF() {
        let vdf = VDF.parse("""
        "AppState"
        {
            "appid"     "292030"
            "name"      "The Witcher 3: Wild \\"Hunt\\""
            // comment
            "UserConfig" { "language" "english" }
        }
        """)
        #expect(vdf["AppState"]?["appid"]?.string == "292030")
        #expect(vdf["appstate"]?["name"]?.string == #"The Witcher 3: Wild "Hunt""#)
        #expect(vdf["AppState"]?["UserConfig"]?["language"]?.string == "english")
    }

    @Test func convertsWindowsPaths() {
        let prefix = URL(fileURLWithPath: "/P")
        #expect(SteamLibraryScanner.unixPath(fromWindows: "C:\\\\Program Files (x86)\\\\Steam", prefix: prefix)?.path == "/P/drive_c/Program Files (x86)/Steam")
        #expect(SteamLibraryScanner.unixPath(fromWindows: "C:\\Games", prefix: prefix)?.path == "/P/drive_c/Games")
        #expect(SteamLibraryScanner.unixPath(fromWindows: "relative", prefix: prefix) == nil)
    }

    @Test func scansLibrariesAcrossDrives() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let steam = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam", isDirectory: true)
        let mainApps = steam.appendingPathComponent("steamapps", isDirectory: true)
        let otherDrive = root.appendingPathComponent("external", isDirectory: true)
        let otherApps = otherDrive.appendingPathComponent("SteamLibrary/steamapps", isDirectory: true)
        try fm.createDirectory(at: mainApps, withIntermediateDirectories: true)
        try fm.createDirectory(at: otherApps, withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: prefix.appendingPathComponent("dosdevices/d:"), withDestinationURL: otherDrive)

        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" }
            "1" { "path" "D:\\\\SteamLibrary" }
        }
        """.write(to: mainApps.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)

        func manifest(_ dir: URL, id: Int, name: String, folder: String, flags: Int) throws {
            try """
            "AppState"
            {
                "appid" "\(id)"
                "name" "\(name)"
                "installdir" "\(folder)"
                "StateFlags" "\(flags)"
            }
            """.write(to: dir.appendingPathComponent("appmanifest_\(id).acf"), atomically: true, encoding: .utf8)
        }
        try manifest(mainApps, id: 244210, name: "Assetto Corsa", folder: "assettocorsa", flags: 4)
        try manifest(otherApps, id: 70, name: "Half-Life", folder: "Half-Life", flags: 4)
        try manifest(otherApps, id: 400, name: "Portal", folder: "Portal", flags: 1026)
        try manifest(mainApps, id: 228980, name: "Steamworks Common Redistributables", folder: "Steamworks Shared", flags: 4)

        let gameFolder = mainApps.appendingPathComponent("common/assettocorsa", isDirectory: true)
        try fm.createDirectory(at: gameFolder.appendingPathComponent("_CommonRedist"), withIntermediateDirectories: true)
        try Data(count: 3_000_000).write(to: gameFolder.appendingPathComponent("AssettoCorsa.exe"))
        try Data(count: 100_000).write(to: gameFolder.appendingPathComponent("UnityCrashHandler64.exe"))
        try Data(count: 9_000_000).write(to: gameFolder.appendingPathComponent("_CommonRedist/vcredist_x64.exe"))

        #expect(SteamLibraryScanner.steamRoot(in: prefix)?.lastPathComponent == "Steam")
        let apps = SteamLibraryScanner.installedApps(in: prefix)
        #expect(apps.map(\.appID).sorted() == [70, 400, 244210])
        #expect(apps.filter(\.isFullyInstalled).map(\.appID).sorted() == [70, 244210])
        let assetto = try #require(apps.first { $0.appID == 244210 })
        #expect(SteamLibraryScanner.mainExecutable(in: assetto.installDirectory, name: assetto.name)?.lastPathComponent == "AssettoCorsa.exe")
        let halfLife = try #require(apps.first { $0.appID == 70 })
        #expect(halfLife.installDirectory.resolvingSymlinksInPath().path.hasSuffix("external/SteamLibrary/steamapps/common/Half-Life"))
    }
}

struct SteamNamingTests {
    @Test func namesTheSteamClient() {
        #expect(GameLibrary.suggestedName(for: URL(fileURLWithPath: "/x/Program Files (x86)/Steam/steam.exe")) == "Steam")
    }
}
