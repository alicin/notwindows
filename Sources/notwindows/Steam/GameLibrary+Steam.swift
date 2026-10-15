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
                self.refreshLinkHandlers()
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
        guard let session = session(for: launcher.id) else { return false }
        // Steam's DRM and Steamworks refuse to start a game ("Application load error 5:0000065434") until the client
        // has signed in, which it records as ActiveUser. From a cold start that takes 10–30 seconds.
        states[game.id] = .preparing("Waiting for Steam…")
        for _ in 0..<90 {
            if let user = await session.registryValue(key: #"HKCU\Software\Valve\Steam\ActiveProcess"#, name: "ActiveUser"),
               let id = UInt64(user.replacingOccurrences(of: "0x", with: ""), radix: 16), id != 0 {
                return true
            }
            guard state(of: launcher.id).isBusy else { return false }
            try? await Task.sleep(for: .seconds(1))
        }
        alert = AppAlert(title: "Steam isn't signed in",
                         message: "\(game.name) needs Steam to be signed in before it starts. Sign in to Steam, then press Play again.")
        return false
    }

    /// Does what Steam does before it first starts a game: its installscript.vdf's registry keys and redistributables.
    /// Bethesda's launchers, for one, say the game isn't installed without the key.
    func applySteamInstallScript(for game: Game, session: WineSession) async {
        guard let folder = game.installDirectory.map({ URL(fileURLWithPath: $0, isDirectory: true) }),
              let file = SteamInstallScript.find(in: folder),
              let text = try? String(contentsOf: file, encoding: .utf8),
              let windowsFolder = SteamLibraryScanner.windowsPath(of: folder, prefix: game.prefixURL) else { return }
        let script = SteamInstallScript(text, installDirectory: folder, windowsInstallDirectory: windowsFolder,
                                        wow64: game.isPrefix32Bit != true)
        let log = game.logsDirectory.appendingPathComponent("installscript.log")
        try? FileManager.default.createDirectory(at: game.logsDirectory, withIntermediateDirectories: true)
        if !script.registryDocument.isEmpty {
            do { try await session.importRegistry(script.registryDocument, log: log) } catch { report("Couldn't apply \(game.name)'s Steam setup", error) }
        }
        for process in script.processes {
            if await session.registryValue(key: process.hasRunKey, name: process.name) == "0x1" { continue }
            states[game.id] = .preparing("Running first-time setup…")
            for command in process.commands where FileManager.default.fileExists(atPath: command.executable) {
                _ = try? await session.run(executable: URL(fileURLWithPath: command.executable), arguments: command.arguments, log: log)
            }
            try? await session.importRegistry(SteamInstallScript.doneDocument(for: process), log: log)
        }
    }

    func writeSteamAppIDFile(for game: Game) {
        guard let appID = game.steamAppID, let directory = game.executableURL?.deletingLastPathComponent() else { return }
        let file = directory.appendingPathComponent("steam_appid.txt")
        if !file.exists { try? "\(appID)\n".write(to: file, atomically: true, encoding: .utf8) }
    }
}
