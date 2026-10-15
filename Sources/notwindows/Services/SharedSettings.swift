import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let notwindowsSettings = UTType(exportedAs: "com.bunniesinc.notwindows.settings", conformingTo: .json)
}

/// A game's settings as a file someone else can import. Paths, the prefix and play history stay behind; only what
/// makes the game run well travels.
struct SharedSettings: Codable, Equatable {
    static let fileExtension = "notwindows"
    /// Format 2 added the Mac, macOS, game engine and note; format 1 files read the same, without them.
    static let currentFormat = 2

    var format = SharedSettings.currentFormat
    var game: String
    /// File name of the executable, used to recognise the same game on another Mac.
    var executable: String?
    var steamAppID: Int?
    var engine: String?
    var arguments: String
    /// Winetricks components installed in the exporter's prefix.
    var winetricks: [String]
    var settings: GameSettings
    /// The exporter's Mac model identifier, e.g. "Mac16,7".
    var mac: String?
    /// e.g. "Apple M5".
    var chip: String?
    var macOS: String?
    /// The game's engine as Smart Setup recognised it, e.g. "Gamebryo".
    var gameEngine: String?
    /// A few words from the exporter about how the game runs.
    var note: String?

    init(game: Game, winetricks: [String], gameEngine: String? = nil, note: String? = nil, machine: Machine = .current) {
        self.game = game.name
        executable = game.executableURL?.lastPathComponent
        steamAppID = game.steamAppID
        engine = game.engineName
        arguments = game.arguments
        self.winetricks = winetricks
        settings = game.settings
        mac = machine.model
        chip = machine.chip
        macOS = machine.macOS
        self.gameEngine = gameEngine
        self.note = note.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
    }

    /// "Apple M5 · macOS 26.1 · Gamebryo", leaving out what the file doesn't say.
    var summary: String {
        [chip ?? mac, macOS.map { "macOS \($0)" }, gameEngine].compactMap { $0 }.joined(separator: " · ")
    }

    struct Machine {
        var model: String?
        var chip: String?
        var macOS: String?

        static var current: Machine {
            func sysctl(_ name: String) -> String? {
                var size = 0
                guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
                var buffer = [CChar](repeating: 0, count: size)
                guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
                return String(cString: buffer).nilIfEmpty
            }
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let macOS = version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
                : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            return Machine(model: sysctl("hw.model"), chip: sysctl("machdep.cpu.brand_string"), macOS: macOS)
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> SharedSettings {
        let shared = try JSONDecoder().decode(SharedSettings.self, from: data)
        guard shared.format <= currentFormat else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "These settings were made by a newer version of notwindows."])
        }
        return shared
    }

    /// Whether these settings were exported from the same game: the same Steam app, or the same executable.
    func matches(_ game: Game) -> Bool {
        if let steamAppID, let other = game.steamAppID { return steamAppID == other }
        guard let executable, let other = game.executableURL?.lastPathComponent else { return false }
        return executable.caseInsensitiveCompare(other) == .orderedSame
    }
}

extension GameLibrary {
    struct ImportResult {
        /// The engine the settings asked for, when it isn't installed here.
        var missingEngine: String?
        var missingWinetricks: [String] = []
    }

    func sharedSettings(of id: UUID, note: String? = nil) -> SharedSettings? {
        game(id).map { SharedSettings(game: $0, winetricks: installedWinetricksVerbs(id).sorted(),
                                      gameEngine: compatReports[id]?.executable?.engineLabel, note: note) }
    }

    /// Takes over another player's settings. The engine is only switched when it's installed, and Steam games keep
    /// Steam's engine.
    @discardableResult
    func importSettings(_ shared: SharedSettings, into id: UUID) -> ImportResult {
        guard let game = game(id) else { return ImportResult() }
        var result = ImportResult()
        let engine = shared.engine.flatMap { name in engines.isInstalled(name) ? name : nil }
        if let name = shared.engine, engine == nil, !game.isSteamGame { result.missingEngine = Engine.displayName(for: name) }
        update(id) {
            $0.settings = shared.settings
            // .ini changes are made again on this Mac, where the files may not exist yet.
            for index in $0.settings.iniEdits.indices { $0.settings.iniEdits[index].isPending = true }
            $0.arguments = shared.arguments
            if !game.isSteamGame, shared.engine == nil || engine != nil { $0.engineName = engine }
        }
        applyIniEdits(id)
        let installed = installedWinetricksVerbs(id)
        result.missingWinetricks = shared.winetricks.filter { !installed.contains($0) }
        return result
    }
}
