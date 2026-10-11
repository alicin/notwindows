import Foundation

/// A prefix already in the library that a new game can run in instead of getting its own.
struct PrefixChoice: Identifiable, Hashable {
    let url: URL
    let gameNames: [String]

    var id: String { url.path }
    var title: String { gameNames.formatted(.list(type: .and)) }
}

extension GameLibrary {
    /// Other games running in the same prefix. Steam games are left out; they follow their launcher.
    func prefixMates(of game: Game) -> [Game] {
        guard !game.isSteamGame else { return [] }
        let prefix = Self.key(game.prefixURL)
        return games.filter { $0.id != game.id && !$0.isSteamGame && Self.key($0.prefixURL) == prefix }
    }

    /// The game whose own folder holds this game's prefix.
    func prefixOwner(of game: Game) -> Game? {
        guard game.externalPrefixPath != nil else { return nil }
        return prefixMates(of: game).first { $0.externalPrefixPath == nil }
    }

    /// Joins a prefix that isn't the game's own. Wine processes sharing a prefix share one Wine server, which only
    /// accepts the engine and sync mode it was started with, so those follow the prefix's existing games.
    func shareGame(_ game: inout Game, prefix: URL) {
        game.externalPrefixPath = prefix.standardizedFileURL.path
        guard let mate = prefixMates(of: game).first(where: { $0.externalPrefixPath == nil }) ?? prefixMates(of: game).first else { return }
        game.engineName = mate.engineName
        game.settings.msync = mate.settings.msync
        game.settings.esync = mate.settings.esync
    }

    var prefixChoices: [PrefixChoice] {
        var names: [String: (url: URL, names: [String])] = [:]
        for game in games where !game.isSteamGame {
            names[Self.key(game.prefixURL), default: (game.prefixURL.standardizedFileURL, [])].names.append(game.name)
        }
        return names.values
            .map { PrefixChoice(url: $0.url, gameNames: $0.names) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The prefix whose C: drive holds `file`, if any.
    nonisolated static func containingPrefix(of file: URL) -> URL? {
        var url = file.standardizedFileURL.deletingLastPathComponent()
        while url.pathComponents.count > 1 {
            if url.lastPathComponent == "drive_c" {
                let prefix = url.deletingLastPathComponent()
                return isPrefix(prefix) ? prefix : nil
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }

    nonisolated static func isPrefix(_ url: URL) -> Bool {
        url.appendingPathComponent("system.reg").exists && url.appendingPathComponent("drive_c").exists
    }

    nonisolated static func key(_ prefix: URL) -> String {
        prefix.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Running side by side

    /// Fragment of the game's Windows command lines that tells its processes apart from others in the prefix.
    func processFragment(for game: Game) -> String? {
        if game.isSteamGame {
            guard let folder = game.installDirectory.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return nil }
            return "/steamapps/common/\(folder)/"
        }
        guard let executable = game.executableURL?.standardizedFileURL else { return nil }
        let folder = executable.deletingLastPathComponent().path
        let drive = game.driveC.standardizedFileURL.path
        let relative = folder.hasPrefix(drive + "/") ? String(folder.dropFirst(drive.count)) : folder
        return relative.isEmpty ? "/" + executable.lastPathComponent : relative + "/"
    }

    /// Waits until no process matching `fragment` is left. Another program keeps the prefix's Wine server alive,
    /// so `wineserver -w` can't tell when this one is done.
    func waitForExit(matching fragment: String) async {
        var misses = 0
        while misses < 2 {
            try? await Task.sleep(for: .seconds(3))
            misses = await WineProcesses.matching(fragment).isEmpty ? misses + 1 : 0
        }
    }

    func killProcesses(of game: Game) {
        guard let fragment = processFragment(for: game) else { return }
        Task {
            for pid in await WineProcesses.matching(fragment) { kill(pid, SIGKILL) }
        }
    }

    // MARK: Removing

    /// Moves a prefix other games still use into one of their folders, so removing its owner doesn't take it along.
    func handOffPrefix(of game: Game) throws {
        let mates = prefixMates(of: game)
        guard game.externalPrefixPath == nil, let heir = mates.first else { return }
        if let busy = ([game] + mates).first(where: { state(of: $0.id).isBusy }) {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Quit \(busy.name) first; it's using the prefix."])
        }
        let target = heir.directory.appendingPathComponent("prefix", isDirectory: true)
        guard !target.exists else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "\(heir.name) already has a prefix folder of its own."])
        }
        try FileManager.default.createDirectory(at: heir.directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: game.prefixURL, to: target)

        let old = game.prefixURL.standardizedFileURL.path
        let new = target.standardizedFileURL.path
        func moved(_ path: String?) -> String? {
            guard let path, path == old || path.hasPrefix(old + "/") else { return path }
            return new + path.dropFirst(old.count)
        }
        for mate in mates {
            update(mate.id) { mate in
                mate.externalPrefixPath = mate.id == heir.id ? nil : new
                mate.executablePath = moved(mate.executablePath) ?? ""
                mate.workingDirectory = moved(mate.workingDirectory)
            }
        }
    }
}
