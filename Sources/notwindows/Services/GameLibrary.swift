import AppKit
import Observation

enum RunState: Equatable {
    case idle
    case preparing(String)
    case running(since: Date)

    var isBusy: Bool { self != .idle }
    var isRunning: Bool { if case .running = self { true } else { false } }
}

struct WinetricksJob {
    enum Status: Equatable {
        case preparing, running, succeeded, cancelled
        case failed(Int32)
    }

    let verbs: [String]
    let log: URL
    var status: Status
    var process: Process?

    var isRunning: Bool { status == .preparing || status == .running }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
@Observable
final class GameLibrary {
    private(set) var games: [Game] = []
    private(set) var states: [UUID: RunState] = [:]
    private(set) var icons: [UUID: NSImage] = [:]
    private(set) var palettes: [UUID: IconPalette] = [:]
    private(set) var backdrops: [UUID: NSImage] = [:]
    private(set) var toast: (toast: Toast, gameID: UUID?)?
    private(set) var candidates: [UUID: [ExecutableScanner.Candidate]] = [:]
    private(set) var winetricksJobs: [UUID: WinetricksJob] = [:]
    var alert: AppAlert?

    let engines: EngineManager
    let runtime: RuntimeManager

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(engines: EngineManager, runtime: RuntimeManager) {
        self.engines = engines
        self.runtime = runtime
        Paths.ensureDirectories()
        load()
    }

    // MARK: Library

    func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Paths.games, includingPropertiesForKeys: nil)) ?? []
        games = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("game.json")) else { return nil }
            return try? Self.decoder.decode(Game.self, from: data)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for game in games {
            if let image = NSImage(contentsOf: game.iconURL) {
                icons[game.id] = image
                palettes[game.id] = image.palette()
                backdrops[game.id] = image.backdrop()
            }
        }
    }

    func game(_ id: UUID?) -> Game? {
        guard let id else { return nil }
        return games.first { $0.id == id }
    }

    func state(of id: UUID) -> RunState { states[id] ?? .idle }

    func save(_ game: Game) {
        do {
            try FileManager.default.createDirectory(at: game.directory, withIntermediateDirectories: true)
            try Self.encoder.encode(game).write(to: game.manifestURL, options: .atomic)
        } catch {
            report("Couldn't save \(game.name)", error)
        }
        if let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index] = game
        } else {
            games.append(game)
            games.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func update(_ id: UUID, _ change: (inout Game) -> Void) {
        guard var game = game(id) else { return }
        change(&game)
        save(game)
    }

    func remove(_ game: Game) {
        do {
            try FileManager.default.trashItem(at: game.directory, resultingItemURL: nil)
        } catch {
            report("Couldn't move \(game.name) to the Trash", error)
            return
        }
        games.removeAll { $0.id == game.id }
        icons[game.id] = nil
        palettes[game.id] = nil
        backdrops[game.id] = nil
        states[game.id] = nil
    }

    func setIcon(_ image: NSImage?, for id: UUID) {
        guard let game = game(id) else { return }
        if let image, let png = image.pngData() {
            try? FileManager.default.createDirectory(at: game.directory, withIntermediateDirectories: true)
            try? png.write(to: game.iconURL)
            let stored = NSImage(data: png)
            icons[id] = stored
            palettes[id] = stored?.palette()
            backdrops[id] = stored?.backdrop()
        } else {
            try? FileManager.default.removeItem(at: game.iconURL)
            icons[id] = nil
            palettes[id] = nil
            backdrops[id] = nil
        }
    }

    func refreshIconFromExecutable(_ id: UUID) {
        guard let url = game(id)?.executableURL, let image = PEIconExtractor.image(fromExecutableAt: url) else { return }
        setIcon(image, for: id)
    }

    // MARK: Adding games

    @discardableResult
    func addGame(executable: URL, name: String? = nil) -> Game {
        var game = Game(name: name ?? Self.suggestedName(for: executable), executablePath: executable.path)
        if WineRosetta.isLegacyWoW(executable) {
            game.settings.wineRosetta = true
            game.settings.direct3D9Backend = .d9vk
        }
        save(game)
        refreshIconFromExecutable(game.id)
        Task { await prepare(game.id) }
        return game
    }

    @discardableResult
    func installGame(setup: URL, name: String) -> Game {
        let game = Game(name: name)
        save(game)
        if let image = PEIconExtractor.image(fromExecutableAt: setup) { setIcon(image, for: game.id) }
        Task {
            guard await prepare(game.id), let session = session(for: game.id) else { return }
            states[game.id] = .preparing("Running installer…")
            do {
                _ = try await session.run(executable: setup, log: game.lastLogURL)
                states[game.id] = .preparing("Waiting for installer to finish…")
                await session.waitUntilIdle()
            } catch {
                report("The installer couldn't start", error)
            }
            states[game.id] = .idle
            scanForExecutables(game.id)
            show(Toast(symbol: "checkmark.circle.fill", title: "Installer finished", detail: "Pick \(name)'s executable to finish adding it.", tint: .green), for: game.id)
        }
        return game
    }

    func importWrapper(_ app: URL) {
        do {
            let result = try WrapperImporter.importWrapper(at: app)
            save(result.game)
            if result.game.executableURL.map({ PEIconExtractor.image(fromExecutableAt: $0) }) != nil {
                refreshIconFromExecutable(result.game.id)
            } else if let icon = result.icon {
                setIcon(icon, for: result.game.id)
            }
            if result.game.executablePath.isEmpty { scanForExecutables(result.game.id) }
        } catch {
            report("Couldn't import \(app.lastPathComponent)", error)
        }
    }

    func scanForExecutables(_ id: UUID) {
        guard let game = game(id) else { return }
        let driveC = game.driveC
        Task.detached(priority: .userInitiated) {
            let found = ExecutableScanner.scan(driveC)
            await MainActor.run { self.candidates[id] = found }
        }
    }

    func chooseExecutable(_ url: URL, for id: UUID) {
        update(id) { game in
            game.executablePath = url.path
            game.workingDirectory = nil
            if game.name.isEmpty || game.name == "New Game" { game.name = Self.suggestedName(for: url) }
        }
        candidates[id] = nil
        if icons[id] == nil || PEIconExtractor.image(fromExecutableAt: url) != nil { refreshIconFromExecutable(id) }
    }

    nonisolated static func suggestedName(for executable: URL) -> String {
        let stem = executable.deletingPathExtension().lastPathComponent
        let generic = ["game", "launcher", "start", "play", "setup", "install", "main", "bin", "win64", "win32", "x64", "binaries"]
        var name = stem
        var folder = executable.deletingLastPathComponent()
        while generic.contains(where: { name.lowercased().hasPrefix($0) }) || generic.contains(name.lowercased()) {
            let candidate = folder.lastPathComponent
            guard !candidate.isEmpty, candidate != "/", candidate != "drive_c" else { break }
            name = candidate
            folder = folder.deletingLastPathComponent()
        }
        return name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"(?i)[ -]?(win64[- ]shipping|setup|installer)$"#, with: "", options: .regularExpression)
    }

    // MARK: Running

    func session(for id: UUID) -> WineSession? {
        guard let game = game(id) else { return nil }
        guard let runtime = runtime.current else {
            alert = AppAlert(title: "Runtime not installed", message: "Install the Sikarugir runtime from Settings › Runtime before running games.")
            return nil
        }
        guard let engine = engines.engine(named: game.engineName) else {
            let message = game.engineName.map { "The engine “\($0)” isn't installed. Pick another one in the game's settings or install it from Settings › Engines." }
                ?? "Install a Wine engine from Settings › Engines before running games."
            alert = AppAlert(title: "No Wine engine", message: message)
            return nil
        }
        guard self.runtime.isRosettaInstalled else {
            alert = AppAlert(title: "Rosetta is required", message: "Wine engines are Intel builds. Install Rosetta by running:\n\nsoftwareupdate --install-rosetta --agree-to-license")
            return nil
        }
        return WineSession(game: game, engine: engine, runtime: runtime)
    }

    /// Creates the prefix and syncs registry-backed settings. Returns false if something failed.
    @discardableResult
    func prepare(_ id: UUID) async -> Bool {
        guard let session = session(for: id) else { return false }
        let previous = state(of: id)
        defer { states[id] = previous }

        do {
            if !session.game.isPrefixInitialized {
                states[id] = .preparing("Setting up Windows…")
                try? FileManager.default.removeItem(at: session.game.lastLogURL)
                try await session.initializePrefix(log: session.game.lastLogURL)
            }
            let fingerprint = session.game.settings.registryFingerprint
            if session.game.appliedRegistryFingerprint != fingerprint || session.game.appliedRegistryEngine != session.engine.name {
                states[id] = .preparing("Applying settings…")
                try await session.applyRegistry(log: session.game.lastLogURL)
                update(id) {
                    $0.appliedRegistryFingerprint = fingerprint
                    $0.appliedRegistryEngine = session.engine.name
                }
            }
            return true
        } catch {
            report("Couldn't prepare \(session.game.name)", error)
            return false
        }
    }

    func play(_ id: UUID) {
        guard state(of: id) == .idle, let game = game(id) else { return }
        guard let executable = game.executableURL, executable.exists else {
            alert = AppAlert(title: "Executable not found", message: "Choose the game's executable in its General settings.")
            return
        }
        states[id] = .preparing("Starting…")
        Task {
            guard await prepare(id), let session = session(for: id) else {
                states[id] = .idle
                return
            }
            let log = session.game.lastLogURL
            try? FileManager.default.removeItem(at: log)
            writeLogHeader(session, to: log)

            do {
                try WineRosetta.sync(
                    directory: executable.deletingLastPathComponent(),
                    enabled: session.game.settings.wineRosetta,
                    dll: WineRosetta.bundledDLL,
                    d9vk: session.game.settings.direct3D9Backend == .d9vk ? WineRosetta.d9vkDLL(in: session.runtime) : nil
                )
            } catch {
                states[id] = .idle
                report("Couldn't set up winerosetta", error)
                return
            }

            let started = Date()
            do {
                _ = try session.launch(executable: executable, arguments: session.game.arguments,
                                       directory: session.game.resolvedWorkingDirectory, log: log) { _ in
                    Task { @MainActor in
                        await session.waitUntilIdle()
                        self.finishRun(id, started: started)
                    }
                }
                states[id] = .running(since: started)
                update(id) { $0.lastPlayedAt = started }
                show(Toast(symbol: "play.fill", title: "Launching \(game.name)", detail: game.settings.direct3DBackend.title), for: id)
            } catch {
                states[id] = .idle
                report("Couldn't launch \(game.name)", error)
            }
        }
    }

    private func finishRun(_ id: UUID, started: Date) {
        guard state(of: id).isRunning else { return }
        states[id] = .idle
        let elapsed = Date().timeIntervalSince(started)
        update(id) { $0.totalPlaytime += elapsed }
        if let game = game(id) {
            let session = elapsed < 60 ? "a quick session" : Format.playtime(elapsed)
            show(Toast(symbol: "flag.checkered", title: "Finished \(game.name)", detail: "Played \(session) · \(Format.playtime(game.totalPlaytime)) total"), for: id)
        }
    }

    func stop(_ id: UUID) {
        guard let session = session(for: id) else { return }
        Task { await session.killAll() }
    }

    func stopAll() {
        for (id, state) in states where state.isBusy { stop(id) }
    }

    var runningCount: Int { states.values.filter(\.isRunning).count }

    func open(_ tool: WineTool, for id: UUID) {
        Task {
            guard await prepare(id), let session = session(for: id) else { return }
            do { try session.open(tool, log: session.game.logsDirectory.appendingPathComponent("tools.log")) }
            catch { report("Couldn't open \(tool.title)", error) }
        }
    }

    /// Runs a one-off program (patch, installer, mod tool) inside the game's prefix.
    func runInPrefix(_ executable: URL, for id: UUID) {
        Task {
            guard await prepare(id), let session = session(for: id) else { return }
            states[id] = .preparing("Running \(executable.lastPathComponent)…")
            _ = try? await session.run(executable: executable, log: session.game.logsDirectory.appendingPathComponent("tools.log"))
            await session.waitUntilIdle()
            states[id] = .idle
        }
    }

    func startWinetricks(_ verbs: [String], force: Bool, unattended: Bool, for id: UUID) {
        guard !verbs.isEmpty, winetricksJobs[id]?.isRunning != true else { return }
        let log = game(id)?.logsDirectory.appendingPathComponent("winetricks.log")
            ?? Paths.tools.appendingPathComponent("winetricks.log")
        try? FileManager.default.removeItem(at: log)
        winetricksJobs[id] = WinetricksJob(verbs: verbs, log: log, status: .preparing)

        Task {
            guard await prepare(id), let session = session(for: id) else {
                winetricksJobs[id]?.status = .failed(-1)
                return
            }
            let previous = state(of: id)
            states[id] = .preparing("Winetricks: \(verbs.joined(separator: " "))…")
            do {
                let script = try await runtime.winetricksScript()
                let process = try session.startWinetricks(script: script, verbs: verbs, force: force, unattended: unattended, log: log) { status in
                    Task { @MainActor in
                        await session.waitUntilIdle()
                        self.finishWinetricks(id, status: status, restoring: previous)
                    }
                }
                winetricksJobs[id]?.process = process
                winetricksJobs[id]?.status = .running
            } catch {
                winetricksJobs[id]?.status = .failed(-1)
                states[id] = previous
                report("Winetricks failed", error)
            }
        }
    }

    private func finishWinetricks(_ id: UUID, status: Int32, restoring previous: RunState) {
        guard var job = winetricksJobs[id] else { return }
        if job.status != .cancelled { job.status = status == 0 ? .succeeded : .failed(status) }
        job.process = nil
        winetricksJobs[id] = job
        if state(of: id).isRunning == false { states[id] = previous.isRunning ? .idle : previous }
        let name = game(id)?.name ?? "game"
        switch job.status {
        case .succeeded:
            show(Toast(symbol: "checkmark.circle.fill", title: "Winetricks finished", detail: "Installed \(job.verbs.joined(separator: ", ")) into \(name)", tint: .green), for: id)
        case .failed(let code):
            show(Toast(symbol: "exclamationmark.triangle.fill", title: "Winetricks failed", detail: "Exit status \(code). Check the log for details.", tint: .orange), for: id)
        default:
            break
        }
    }

    /// Stops a running winetricks job, including any installer it spawned inside the prefix.
    func cancelWinetricks(_ id: UUID) {
        guard let job = winetricksJobs[id], job.isRunning else { return }
        winetricksJobs[id]?.status = .cancelled
        job.process?.terminate()
        if let session = session(for: id) { Task { await session.killAll() } }
    }

    func clearWinetricksJob(_ id: UUID) {
        if winetricksJobs[id]?.isRunning != true { winetricksJobs[id] = nil }
    }

    /// Wipes and recreates a managed prefix. Installed games inside it are lost.
    func resetPrefix(_ id: UUID) {
        guard let game = game(id), game.externalPrefixPath == nil else { return }
        Task {
            if let session = session(for: id) { await session.killAll() }
            try? FileManager.default.trashItem(at: game.prefixURL, resultingItemURL: nil)
            update(id) { $0.appliedRegistryFingerprint = nil }
            await prepare(id)
        }
    }

    private func writeLogHeader(_ session: WineSession, to log: URL) {
        let env = session.environment
        let keys = env.keys.sorted().filter { !["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"].contains($0) }
        var header = "notwindows launch \(ISO8601DateFormatter().string(from: Date()))\n"
        header += "Game: \(session.game.name)\nEngine: \(session.engine.name)\nRuntime: \(session.runtime.name)\n"
        header += "Executable: \(session.game.executablePath) \(session.game.arguments)\n\n"
        header += keys.map { "\($0)=\(env[$0] ?? "")" }.joined(separator: "\n") + "\n\n"
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? header.write(to: log, atomically: true, encoding: .utf8)
    }

    func show(_ toast: Toast, for id: UUID? = nil) {
        self.toast = (toast, id)
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            if self.toast?.toast.id == toast.id { self.toast = nil }
        }
    }

    func report(_ title: String, _ error: Error) {
        alert = AppAlert(title: title, message: error.localizedDescription)
    }
}
