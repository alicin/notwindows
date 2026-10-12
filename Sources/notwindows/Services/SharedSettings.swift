import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let notwindowsSettings = UTType(exportedAs: "com.bunniesinc.notwindows.settings", conformingTo: .json)
}

/// A game's settings as a file someone else can import. Paths, the prefix and play history stay behind; only what
/// makes the game run well travels.
struct SharedSettings: Codable, Equatable {
    static let fileExtension = "notwindows"
    static let currentFormat = 1

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

    init(game: Game, winetricks: [String]) {
        self.game = game.name
        executable = game.executableURL?.lastPathComponent
        steamAppID = game.steamAppID
        engine = game.engineName
        arguments = game.arguments
        self.winetricks = winetricks
        settings = game.settings
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

    func sharedSettings(of id: UUID) -> SharedSettings? {
        game(id).map { SharedSettings(game: $0, winetricks: installedWinetricksVerbs(id).sorted()) }
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
            $0.arguments = shared.arguments
            if !game.isSteamGame, shared.engine == nil || engine != nil { $0.engineName = engine }
        }
        let installed = installedWinetricksVerbs(id)
        result.missingWinetricks = shared.winetricks.filter { !installed.contains($0) }
        return result
    }
}
