import Foundation

enum WineTool: String, CaseIterable, Identifiable {
    case winecfg, regedit, taskmgr, control, explorer, cmd, uninstaller
    var id: String { rawValue }

    var title: String {
        switch self {
        case .winecfg: "Wine Configuration"
        case .regedit: "Registry Editor"
        case .taskmgr: "Task Manager"
        case .control: "Control Panel"
        case .explorer: "File Explorer"
        case .cmd: "Command Prompt"
        case .uninstaller: "Uninstall Programs"
        }
    }

    var symbol: String {
        switch self {
        case .winecfg: "wrench.and.screwdriver"
        case .regedit: "list.bullet.indent"
        case .taskmgr: "chart.bar.doc.horizontal"
        case .control: "switch.2"
        case .explorer: "folder"
        case .cmd: "terminal"
        case .uninstaller: "trash"
        }
    }

    var arguments: [String] {
        switch self {
        case .cmd: ["start", "cmd"]
        case .explorer: ["explorer", "C:\\"]
        default: [rawValue]
        }
    }
}

/// Everything needed to run Wine for one game: its prefix, engine, runtime and settings.
struct WineSession {
    let game: Game
    let engine: Engine
    let runtime: Runtime
    /// Set when the game runs through rosettax87.
    var x87Loader: URL?
    /// Set when other games share the prefix, so registry settings go to this game's AppDefaults key.
    var scopesRegistryToApp = false

    var environment: [String: String] {
        var env = WineEnvironment.make(
            engine: engine,
            runtime: runtime,
            prefix: game.prefixURL,
            settings: game.settings,
            cacheDirectory: game.cacheDirectory
        )
        if let x87Loader { env["ROSETTA_X87_PATH"] = x87Loader.path }
        if game.isSteamGame, let appID = game.steamAppID {
            // Tells Steamworks which app this is, so it doesn't relaunch the game through the Steam client.
            env["SteamAppId"] = String(appID)
            env["SteamGameId"] = String(appID)
        }
        return env
    }

    func initializePrefix(log: URL) async throws {
        try FileManager.default.createDirectory(at: game.prefixURL, withIntermediateDirectories: true)
        var env = environment
        env["WINEDEBUG"] = "-all"
        let status = try await ProcessRunner.run(engine.loader, ["wineboot", "--init"], environment: env, log: log)
        await waitUntilIdle(environment: env)
        guard status == 0, game.isPrefixInitialized else {
            throw ProcessRunner.Failure(command: "wineboot --init", status: status, output: (try? String(contentsOf: log, encoding: .utf8)) ?? "")
        }
    }

    func applyRegistry(log: URL) async throws {
        let scope = scopesRegistryToApp ? game.executableURL?.lastPathComponent : nil
        try await importRegistry(RegistryWriter.document(for: game.settings, appExecutable: scope), log: log)
    }

    /// Imports a .reg document into the prefix with regedit.
    func importRegistry(_ document: String, log: URL) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notwindows-\(UUID().uuidString).reg")
        try document.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        var env = environment
        env["WINEDEBUG"] = "-all"
        let status = try await ProcessRunner.run(engine.loader, ["regedit", "/S", file.path], environment: env, log: log)
        if status != 0 { throw ProcessRunner.Failure(command: "regedit", status: status, output: "") }
    }

    func launchArguments(for executable: URL, arguments: String) -> [String] {
        let args = CommandLineSplitter.split(arguments)
        switch executable.pathExtension.lowercased() {
        case "msi": return ["msiexec", "/i", executable.path] + args
        case "bat", "cmd", "lnk": return ["start", "/wait", "/unix", executable.path] + args
        default: return [executable.path] + args
        }
    }

    func launch(executable: URL, arguments: String, directory: URL?, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        try ProcessRunner.start(
            engine.loader,
            launchArguments(for: executable, arguments: arguments),
            environment: environment,
            directory: directory,
            log: log,
            onExit: onExit
        )
    }

    func run(executable: URL, arguments: String = "", log: URL) async throws -> Int32 {
        try await ProcessRunner.run(
            engine.loader,
            launchArguments(for: executable, arguments: arguments),
            environment: environment,
            directory: executable.deletingLastPathComponent(),
            log: log
        )
    }

    func open(_ tool: WineTool, log: URL) throws {
        try ProcessRunner.start(engine.loader, tool.arguments, environment: environment, directory: game.driveC, log: log)
    }

    /// Reads a value from the prefix's live registry, through whatever wineserver is already running for it.
    func registryValue(key: String, name: String) async -> String? {
        var env = environment
        env["WINEDEBUG"] = "-all"
        guard let output = try? await ProcessRunner.output(engine.loader, ["reg", "query", key, "/v", name], environment: env) else { return nil }
        return Self.registryValue(named: name, in: output)
    }

    /// Picks a value out of `reg query` output, whose lines look like "    ActiveUser    REG_DWORD    0x210b7e9". Names
    /// and values can contain spaces, so the type column is what splits them.
    static func registryValue(named name: String, in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let type = line.range(of: #"\s{2,}REG_[A-Z_]+(\s{2,}|$)"#, options: .regularExpression) else { continue }
            let key = line[..<type.lowerBound].trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare(name) == .orderedSame { return String(line[type.upperBound...]) }
        }
        return nil
    }

    /// Blocks until every process in the prefix has exited.
    func waitUntilIdle(environment env: [String: String]? = nil) async {
        _ = try? await ProcessRunner.run(engine.wineserver, ["-w"], environment: env ?? environment)
    }

    func killAll() async {
        _ = try? await ProcessRunner.run(engine.wineserver, ["-k"], environment: environment)
    }

    func startWinetricks(script: URL, verbs: [String], force: Bool, unattended: Bool, log: URL,
                         onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        var env = environment
        // bash is SIP-protected and drops DYLD_* before winetricks can pass them on, so Wine is reached through
        // small shims that restore the library path.
        env["NOTWINDOWS_DYLD_FALLBACK_LIBRARY_PATH"] = env["DYLD_FALLBACK_LIBRARY_PATH"]
        env["NOTWINDOWS_WINE"] = engine.loader.path
        env["NOTWINDOWS_WINESERVER"] = engine.wineserver.path
        env["WINE"] = try Self.shim(named: "wine", target: "NOTWINDOWS_WINE").path
        // winetricks derives the 64-bit loader by renaming "wine" to "wine64" next to it.
        _ = try Self.shim(named: "wine64", target: "NOTWINDOWS_WINE")
        env["WINESERVER"] = try Self.shim(named: "wineserver", target: "NOTWINDOWS_WINESERVER").path
        env["PATH"] = try Self.writeShim(named: "sed", script: Self.gnuSedShim).deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        env["W_NO_WIN64_WARNINGS"] = "1"
        env["WINETRICKS_LATEST_VERSION_CHECK"] = "disabled"
        var flags = ["--no-isolate"]
        if unattended { flags.append("--unattended") }
        if force { flags.append("--force") }
        return try ProcessRunner.start(
            URL(fileURLWithPath: "/bin/bash"),
            [script.path] + flags + verbs,
            environment: env,
            directory: game.driveC,
            log: log,
            onExit: onExit
        )
    }

    private static func shim(named name: String, target variable: String) throws -> URL {
        try writeShim(named: name, script: """
        #!/bin/sh
        export DYLD_FALLBACK_LIBRARY_PATH="$NOTWINDOWS_DYLD_FALLBACK_LIBRARY_PATH"
        exec "$\(variable)" "$@"

        """)
    }

    /// winetricks expects GNU sed: a bare -i edits in place (BSD sed takes the next argument as a backup suffix),
    /// and verbs such as wmp9 patch binaries, which BSD sed rejects under a UTF-8 locale.
    private static let gnuSedShim = """
    #!/bin/sh
    for arg do
        shift
        if [ "$arg" = "-i" ]; then set -- "$@" -i ""; else set -- "$@" "$arg"; fi
    done
    LC_ALL=C exec /usr/bin/sed "$@"

    """

    private static func writeShim(named name: String, script: String) throws -> URL {
        let directory = Paths.tools.appendingPathComponent("shims", isDirectory: true)
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

enum CommandLineSplitter {
    /// Splits a Windows-style argument string, honouring double quotes.
    static func split(_ string: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for ch in string {
            if ch == "\"" {
                inQuotes.toggle()
                hasToken = true
            } else if ch.isWhitespace && !inQuotes {
                if hasToken { result.append(current); current = ""; hasToken = false }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }
}
