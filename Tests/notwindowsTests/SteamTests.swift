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

struct ProtocolRegistryTests {
    @Test func findsLauncherSchemesAndSkipsWineBuiltins() {
        let registry = #"""
        WINE REGISTRY Version 2

        [Software\\Classes\\microbot-launcher] 1791420573
        #time=1dd56bee2943ee2
        @="URL:Microbot Launcher"
        "URL Protocol"=""

        [Software\\Classes\\microbot-launcher\\shell\\open\\command] 1791420573
        @="\"C:\\users\\ali\\AppData\\Local\\Microbot\\Launcher\\MicrobotLauncher.exe\" \"%1\""

        [Software\\Classes\\https] 1791420553
        "URL Protocol"=""

        [Software\\Classes\\https\\shell\\open\\command] 1791420553
        @="\"C:\\windows\\system32\\winebrowser.exe\" \"%1\""

        [Software\\Classes\\com.epicgames.launcher] 1791420553
        "URL Protocol"=""

        [Software\\Classes\\com.epicgames.launcher\\shell\\open\\command] 1791420553
        @="\"C:\\Program Files (x86)\\Epic Games\\Launcher\\Portal\\Binaries\\Win64\\EpicGamesLauncher.exe\" %1"

        [Software\\Classes\\txtfile\\shell\\open\\command] 1791420553
        @="notepad.exe %1"

        [Software\\Classes\\noprotocol] 1791420553
        @="Not a URL handler"

        [Software\\Classes\\noprotocol\\shell\\open\\command] 1791420553
        @="foo.exe %1"
        """#
        let protocols = ProtocolRegistry.parse(registry)
        #expect(protocols.map(\.scheme) == ["com.epicgames.launcher", "microbot-launcher"])
        let microbot = protocols[1]
        #expect(microbot.description == "URL:Microbot Launcher")
        #expect(microbot.command == #""C:\users\ali\AppData\Local\Microbot\Launcher\MicrobotLauncher.exe" "%1""#)
        #expect(microbot.programName == "MicrobotLauncher.exe")
        #expect(protocols[0].programName == "EpicGamesLauncher.exe")
    }

    @Test func validatesSchemes() {
        #expect(ProtocolRegistry.isValidScheme("com.epicgames.launcher"))
        #expect(ProtocolRegistry.isValidScheme("battlenet"))
        #expect(!ProtocolRegistry.isValidScheme("*"))
        #expect(!ProtocolRegistry.isValidScheme(".txt"))
        #expect(!ProtocolRegistry.isValidScheme("1abc"))
    }
}

struct ProtocolCommandTests {
    @Test func substitutesTheLink() {
        let quoted = RegisteredProtocol(scheme: "m", description: nil, command: #""C:\Apps\Launcher.exe" "%1""#)
        #expect(quoted.arguments(for: "m://login?code=a&b=c") == [#"C:\Apps\Launcher.exe"#, "m://login?code=a&b=c"])
        let bare = RegisteredProtocol(scheme: "e", description: nil, command: #""C:\Epic\Launcher.exe" %1"#)
        #expect(bare.arguments(for: "e://x") == [#"C:\Epic\Launcher.exe"#, "e://x"])
        let flagged = RegisteredProtocol(scheme: "b", description: nil, command: #""C:\B\B.exe" --uri="%1" --silent"#)
        #expect(flagged.arguments(for: "b://y") == [#"C:\B\B.exe"#, "--uri=b://y", "--silent"])
        let missing = RegisteredProtocol(scheme: "n", description: nil, command: #""C:\N\N.exe""#)
        #expect(missing.arguments(for: "n://z") == [#"C:\N\N.exe"#, "n://z"])
    }
}

struct SteamClientStateTests {
    @Test func readsTheSignedInUserFromRegQuery() {
        let output = """

        HKEY_CURRENT_USER\\Software\\Valve\\Steam\\ActiveProcess
            ActiveUser    REG_DWORD    0x210b7e9
            pid    REG_DWORD    0x20
            installed path    REG_SZ    C:\\Program Files (x86)\\Fallout New Vegas\\

        """
        #expect(WineSession.registryValue(named: "ActiveUser", in: output) == "0x210b7e9")
        #expect(WineSession.registryValue(named: "activeuser", in: output) == "0x210b7e9")
        #expect(WineSession.registryValue(named: "installed path", in: output) == #"C:\Program Files (x86)\Fallout New Vegas\"#)
        #expect(WineSession.registryValue(named: "SteamClientDll", in: output) == nil)
    }
}

struct SteamInstallScriptTests {
    static let falloutNewVegas = #"""
    "installscript"
    {
    	"registry"
    	{
    		"hkey_local_machine\\software\\bethesda softworks\\falloutnv"
    		{
    			"string"
    			{
    				"installed path"		"%INSTALLDIR%\\"
    			}
    		}
    	}
    	"Run Process"
    	{
    		"visualcredist"
    		{
    			"hasrunkey"		"HKEY_LOCAL_MACHINE\\Software\\Valve\\Steam\\Apps\\22380"
    			"process 1"		"%INSTALLDIR%\\Redists\\vcredist_x86.exe"
    			"command 1"		"/q"
    			"nocleanup"		"1"
    		}
    	}
    }
    """#

    @Test func writesRegistryKeysWhereSteamWould() {
        let folder = URL(fileURLWithPath: "/P/drive_c/Program Files (x86)/Steam/steamapps/common/Fallout New Vegas")
        let windows = #"C:\Program Files (x86)\Steam\steamapps\common\Fallout New Vegas"#
        let script = SteamInstallScript(Self.falloutNewVegas, installDirectory: folder, windowsInstallDirectory: windows, wow64: true)
        #expect(script.registryDocument.contains(#"[HKEY_LOCAL_MACHINE\software\Wow6432Node\bethesda softworks\falloutnv]"#))
        #expect(script.registryDocument.contains(#""installed path"="C:\\Program Files (x86)\\Steam\\steamapps\\common\\Fallout New Vegas\\""#))

        let process = try! #require(script.processes.first)
        #expect(process.name == "visualcredist")
        #expect(process.hasRunKey == #"HKEY_LOCAL_MACHINE\Software\Wow6432Node\Valve\Steam\Apps\22380"#)
        #expect(process.commands.first?.executable == folder.path + "/Redists/vcredist_x86.exe")
        #expect(process.commands.first?.arguments == "/q")

        let win32 = SteamInstallScript(Self.falloutNewVegas, installDirectory: folder, windowsInstallDirectory: windows, wow64: false)
        #expect(win32.registryDocument.contains(#"[HKEY_LOCAL_MACHINE\software\bethesda softworks\falloutnv]"#))
    }

    @Test func convertsPrefixPathsToWindowsPaths() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-\(UUID().uuidString)", isDirectory: true)
        let game = prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/common/Game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try FileManager.default.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        #expect(SteamLibraryScanner.windowsPath(of: game, prefix: prefix) == #"C:\Program Files (x86)\Steam\steamapps\common\Game"#)
        #expect(SteamLibraryScanner.windowsPath(of: URL(fileURLWithPath: "/Volumes/Games"), prefix: prefix) == #"Z:\Volumes\Games"#)
    }
}
