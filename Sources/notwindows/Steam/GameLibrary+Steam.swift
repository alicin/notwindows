import AppKit

/// Wine processes as seen by `ps`; their command lines carry Windows paths.
enum WineProcesses {
    static func list() async -> [(pid: Int32, command: String)] {
        guard let output = try? await ProcessRunner.output(URL(fileURLWithPath: "/bin/ps"), ["-axww", "-o", "pid=,command="]) else { return [] }
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { return nil }
            return (pid, String(trimmed[space...]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// PIDs whose command line contains `fragment`, written with `/` separators. Processes started from a Mac
    /// path show `/`, ones Wine spawned itself show `\`, so both forms are checked.
    static func matching(_ fragment: String) async -> [Int32] {
        let unix = fragment.lowercased()
        let windows = unix.replacingOccurrences(of: "/", with: "\\")
        return await list().filter {
            let command = $0.command.lowercased()
            return command.contains(unix) || command.contains(windows)
        }.map(\.pid)
    }
}

extension GameLibrary {
    func launcher(of game: Game) -> Game? { game.launcherID.flatMap { self.game($0) } }

    func steamGames(of launcherID: UUID) -> [Game] {
        games.filter { $0.launcherID == launcherID }
    }

    /// Fragment of a Steam game's Windows command line that identifies its processes.
    func processFragment(for game: Game) -> String? {
        guard let folder = game.installDirectory.map({ URL(fileURLWithPath: $0).lastPathComponent }) else { return nil }
        return "/steamapps/common/\(folder)/"
    }

    // MARK: Library sync

    /// Mirrors the games Windows Steam has installed into library entries that share Steam's prefix.
    func syncSteamLibrary(_ launcherID: UUID, announce: Bool = true) {
        guard let launcher = game(launcherID), launcher.isSteamLauncher else { return }
        let prefix = launcher.prefixURL
        Task.detached(priority: .utility) {
            let apps = SteamLibraryScanner.installedApps(in: prefix).filter(\.isFullyInstalled)
            let executables = apps.map { app in
                (app, SteamLibraryScanner.mainExecutable(in: app.installDirectory, name: app.name))
            }
            await MainActor.run { self.applySteamScan(executables, launcherID: launcherID, announce: announce) }
        }
    }

    private func applySteamScan(_ scan: [(SteamInstalledApp, URL?)], launcherID: UUID, announce: Bool) {
        guard let launcher = game(launcherID) else { return }
        let existing = steamGames(of: launcherID)
        var added: [Game] = []

        for (app, executable) in scan {
            if var current = existing.first(where: { $0.steamAppID == app.appID }) {
                var changed = false
                if current.installDirectory != app.installDirectory.path {
                    current.installDirectory = app.installDirectory.path
                    changed = true
                }
                if current.executableURL?.exists != true, let executable {
                    current.executablePath = executable.path
                    changed = true
                }
                if changed { save(current) }
                continue
            }
            var game = Game(name: app.name, executablePath: executable?.path ?? "")
            game.launcherID = launcherID
            game.steamAppID = app.appID
            game.installDirectory = app.installDirectory.path
            game.externalPrefixPath = launcher.prefixURL.path
            game.settings.msync = launcher.settings.msync
            game.settings.esync = launcher.settings.esync
            if let executable, WineRosetta.isLegacyWoW(executable) {
                game.settings.wineRosetta = true
                game.settings.direct3D9Backend = .d9vk
            }
            save(game)
            if executable != nil { refreshIconFromExecutable(game.id) }
            added.append(game)
        }

        let installedIDs = Set(scan.map(\.0.appID))
        let removed = existing.filter { $0.steamAppID.map { !installedIDs.contains($0) } ?? false }
        for game in removed where !state(of: game.id).isBusy { remove(game) }

        if announce && (!added.isEmpty || !removed.isEmpty) {
            var parts: [String] = []
            if !added.isEmpty { parts.append("Added \(added.map(\.name).prefix(3).joined(separator: ", "))\(added.count > 3 ? " and \(added.count - 3) more" : "")") }
            if !removed.isEmpty { parts.append("removed \(removed.count) uninstalled") }
            show(Toast(symbol: "cloud.fill", title: "Steam library updated", detail: parts.joined(separator: " · ").capitalizedFirst, tint: .blue), for: added.count == 1 ? added[0].id : nil)
        }
        for game in added where game.executableURL != nil {
            Task { await analyzeCompatibility(game.id, autoApply: autoApplyCompat) }
        }
    }

    func syncAllSteamLibraries(announce: Bool = true) {
        for launcher in games where launcher.isSteamLauncher {
            syncSteamLibrary(launcher.id, announce: announce)
        }
    }

    /// Picks up games installed or removed in Steam while notwindows is open.
    func startSteamLibraryWatcher() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                self.syncAllSteamLibraries()
            }
        }
    }

    // MARK: Launching

    /// Starts Steam in the background if it isn't running, and waits for the client to come up.
    func ensureSteamRunning(for game: Game) async -> Bool {
        guard let launcher = launcher(of: game) else {
            alert = AppAlert(title: "Steam not found", message: "This game's Steam entry was removed from the library.")
            return false
        }
        if !state(of: launcher.id).isBusy {
            states[launcher.id] = .preparing("Starting…")
            guard await launch(launcher.id, extraArguments: "-silent") else { return false }
        }
        for _ in 0..<45 {
            if !(await WineProcesses.matching("/steam.exe").isEmpty) {
                // Give the client a moment to log in before the game asks for it.
                try? await Task.sleep(for: .seconds(4))
                return true
            }
            try? await Task.sleep(for: .seconds(2))
        }
        return state(of: launcher.id).isBusy
    }

    func writeSteamAppIDFile(for game: Game) {
        guard let appID = game.steamAppID, let directory = game.executableURL?.deletingLastPathComponent() else { return }
        let file = directory.appendingPathComponent("steam_appid.txt")
        if !file.exists { try? "\(appID)\n".write(to: file, atomically: true, encoding: .utf8) }
    }

    /// Waits until no process from the game's install folder is left. The Steam client keeps the
    /// prefix's Wine server alive, so `wineserver -w` can't be used for these games.
    func waitForSteamGameExit(_ game: Game) async {
        guard let fragment = processFragment(for: game) else { return }
        var misses = 0
        while misses < 2 {
            try? await Task.sleep(for: .seconds(3))
            misses = await WineProcesses.matching(fragment).isEmpty ? misses + 1 : 0
        }
    }

    func stopSteamGame(_ game: Game) {
        guard let fragment = processFragment(for: game) else { return }
        Task {
            for pid in await WineProcesses.matching(fragment) { kill(pid, SIGKILL) }
        }
    }
}
