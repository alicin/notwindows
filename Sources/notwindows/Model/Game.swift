import Foundation

struct Game: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Unix path to the Windows executable. Usually inside the prefix, but may live anywhere on disk.
    var executablePath: String = ""
    var arguments: String = ""
    var workingDirectory: String?
    /// Set for games imported in place (e.g. from a Sikarugir wrapper); otherwise the managed prefix is used.
    var externalPrefixPath: String?
    /// nil follows the library's default engine.
    var engineName: String?
    var settings = GameSettings()
    var addedAt = Date()
    var lastPlayedAt: Date?
    var totalPlaytime: TimeInterval = 0
    var isFavorite = false
    var appliedRegistryFingerprint: String?
    var appliedRegistryEngine: String?
    /// Set for games found in a Steam library; they share the Steam launcher's prefix and Wine server.
    var launcherID: UUID?
    var steamAppID: Int?
    var installDirectory: String?

    init(name: String, executablePath: String = "", settings: GameSettings = GameSettings()) {
        self.name = name
        self.executablePath = executablePath
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        executablePath = try c.decodeIfPresent(String.self, forKey: .executablePath) ?? ""
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        externalPrefixPath = try c.decodeIfPresent(String.self, forKey: .externalPrefixPath)
        engineName = try c.decodeIfPresent(String.self, forKey: .engineName)
        settings = try c.decodeIfPresent(GameSettings.self, forKey: .settings) ?? GameSettings()
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        totalPlaytime = try c.decodeIfPresent(TimeInterval.self, forKey: .totalPlaytime) ?? 0
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        appliedRegistryFingerprint = try c.decodeIfPresent(String.self, forKey: .appliedRegistryFingerprint)
        appliedRegistryEngine = try c.decodeIfPresent(String.self, forKey: .appliedRegistryEngine)
        launcherID = try c.decodeIfPresent(UUID.self, forKey: .launcherID)
        steamAppID = try c.decodeIfPresent(Int.self, forKey: .steamAppID)
        installDirectory = try c.decodeIfPresent(String.self, forKey: .installDirectory)
    }

    var directory: URL { Paths.games.appendingPathComponent(id.uuidString, isDirectory: true) }
    var manifestURL: URL { directory.appendingPathComponent("game.json") }
    var iconURL: URL { directory.appendingPathComponent("icon.png") }
    var logsDirectory: URL { directory.appendingPathComponent("Logs", isDirectory: true) }
    var lastLogURL: URL { logsDirectory.appendingPathComponent("last-run.log") }
    var cacheDirectory: URL { directory.appendingPathComponent("Cache", isDirectory: true) }

    var prefixURL: URL {
        if let externalPrefixPath { return URL(fileURLWithPath: externalPrefixPath, isDirectory: true) }
        return directory.appendingPathComponent("prefix", isDirectory: true)
    }

    var driveC: URL { prefixURL.appendingPathComponent("drive_c", isDirectory: true) }

    var isSteamLauncher: Bool { launcherID == nil && executableURL?.lastPathComponent.lowercased() == "steam.exe" }
    var isSteamGame: Bool { launcherID != nil }
    var isPrefixInitialized: Bool { prefixURL.appendingPathComponent("system.reg").exists }

    /// Whether the existing prefix is 32-bit, read from the `#arch=` line Wine writes at the top of system.reg.
    var isPrefix32Bit: Bool? {
        guard let handle = try? FileHandle(forReadingFrom: prefixURL.appendingPathComponent("system.reg")) else { return nil }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 512)) ?? Data(), as: UTF8.self)
        if head.contains("#arch=win32") { return true }
        if head.contains("#arch=win64") { return false }
        return nil
    }
    var executableURL: URL? { executablePath.isEmpty ? nil : URL(fileURLWithPath: executablePath) }

    /// Steam's install folder for the game, or else the executable's folder.
    var installFolder: URL? {
        installDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? executableURL?.deletingLastPathComponent()
    }

    /// An existing file in the install folder, matching each part of `path` (either slash) regardless of case.
    func installFile(_ path: String) -> URL? {
        guard let folder = installFolder else { return nil }
        let url = Self.resolve(path, in: folder)
        return url.exists ? url : nil
    }

    /// The prefix user's Documents folder, which Wine links to the Mac's own Documents.
    var documentsFolder: URL? {
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []).filter { $0 != "Public" }
        let user = names.contains(NSUserName()) ? NSUserName() : names.sorted().first
        guard let user else { return nil }
        let home = users.appendingPathComponent(user, isDirectory: true)
        // Wine before 5.0 called it "My Documents".
        return ["Documents", "My Documents"].map { home.appendingPathComponent($0, isDirectory: true) }.first(where: \.exists)
    }

    /// The Mac path of a %DOCUMENTS% or %INSTALLDIR% Windows path, or nil when the folder it starts from is unknown.
    func path(forWindowsPath path: String) -> URL? {
        for (placeholder, folder) in [("%DOCUMENTS%", documentsFolder), ("%INSTALLDIR%", installFolder)]
        where path.range(of: placeholder, options: [.anchored, .caseInsensitive]) != nil {
            guard let folder else { return nil }
            return Self.resolve(String(path.dropFirst(placeholder.count)), in: folder)
        }
        return nil
    }

    /// Follows `path` (either slash) from `folder`, matching each existing part regardless of case as Windows does.
    static func resolve(_ path: String, in folder: URL) -> URL {
        var url = folder
        for part in path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            url.appendPathComponent(names.first { $0.caseInsensitiveCompare(part) == .orderedSame } ?? part)
        }
        return url
    }

    var resolvedWorkingDirectory: URL? {
        if let workingDirectory, !workingDirectory.isEmpty {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }
        return executableURL?.deletingLastPathComponent()
    }

    /// Path shown to users, in Windows form when it lives inside the prefix.
    var displayExecutablePath: String {
        guard !executablePath.isEmpty else { return "Not set" }
        let drive = driveC.path
        if executablePath.hasPrefix(drive + "/") {
            return "C:" + executablePath.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
        }
        return (executablePath as NSString).abbreviatingWithTildeInPath
    }
}
