import Foundation

/// Combines the executable scan, macOS rules and online fix databases into one report for a game.
enum CompatAdvisor {
    private static let genericProductNames: Set<String> = [
        "wine", "microsoft® windows® operating system", "microsoft windows operating system", "unity", "unreal engine",
        "launcher", "game", "setup", "installer",
    ]

    static func titleCandidates(for game: Game, executable report: ExecutableReport?) -> [String] {
        var titles = [game.name]
        if let product = report?.productName, !genericProductNames.contains(product.lowercased()), product.count > 2 { titles.append(product) }
        if let folder = game.executableURL?.deletingLastPathComponent().lastPathComponent { titles.append(folder) }
        var seen = Set<String>()
        return titles.filter { !$0.isEmpty && seen.insert(TitleMatcher.tokens($0).joined(separator: " ")).inserted }
    }

    /// - Parameter appInfoFiles: the appinfo.vdf caches of the library's Windows Steam clients, for official launch options.
    static func analyze(game: Game, knownVerbs: Set<String>, preferredMatch: CompatMatch? = nil, supportsRosettaX87: Bool = true,
                        appInfoFiles: [URL] = []) async -> CompatReport {
        var report = CompatReport()
        guard let executable = game.executableURL, executable.exists else {
            report.errors.append("The game doesn't have an executable yet.")
            return report
        }

        var exe = await Task.detached(priority: .userInitiated) { ExecutableAnalyzer.analyze(executable) }.value
        report.executable = exe
        let context = MacRules.Context(installFolder: game.installFolder, prefix: game.prefixURL,
                                       supportsRosettaX87: supportsRosettaX87, isSteamGame: game.isSteamGame)
        report.warnings = MacRules.warnings(for: exe)
        report.notes = MacRules.notes(for: exe, context: context)
        let local = MacRules.suggestions(for: exe, executable: executable, context: context)

        // The Steam client itself isn't a game to look up; its games are matched by app ID instead.
        if executable.lastPathComponent.lowercased() == "steam.exe" {
            report.suggestions = local
            return report
        }

        let sources = CompatSources.shared
        let titles = titleCandidates(for: game, executable: exe)

        // Identify the game.
        var umuEntry: UMUEntry?
        do {
            let entries = try await sources.umuDatabase()
            let path = executable.path.lowercased()
            umuEntry = entries.first { entry in entry.exeStrings.contains { !$0.isEmpty && path.hasSuffix($0.lowercased()) } }
            if umuEntry == nil {
                umuEntry = entries
                    .map { entry in (entry, titles.map { TitleMatcher.score(entry.title, $0) }.max() ?? 0) }
                    .filter { $0.1 >= 0.9 }
                    .max { $0.1 < $1.1 }?.0
            }
        } catch {
            report.errors.append("umu-database: \(error.localizedDescription)")
        }

        if let preferredMatch {
            report.match = preferredMatch
        } else {
            var steamCandidates: [(app: CompatSources.SteamApp, score: Double)] = []
            for title in titles.prefix(2) {
                do {
                    let words = TitleMatcher.tokens(title).joined(separator: " ")
                    for app in try await sources.steamSearch(words.isEmpty ? title : words) {
                        let score = titles.map { TitleMatcher.score(app.name, $0) }.max() ?? 0
                        steamCandidates.append((app, score))
                    }
                } catch {
                    report.errors.append("Steam search: \(error.localizedDescription)")
                    break
                }
            }
            var seen = Set<Int>()
            let ranked = steamCandidates.sorted { $0.score > $1.score }.filter { seen.insert($0.app.id).inserted }
            report.alternatives = ranked.prefix(6).map { CompatMatch(title: $0.app.name, steamAppID: $0.app.id, umuID: nil, store: "steam") }

            if let best = ranked.first, best.score >= 0.75 {
                report.match = CompatMatch(title: best.app.name, steamAppID: best.app.id, umuID: umuEntry?.umuID, store: "steam")
            } else if let umuEntry {
                report.match = CompatMatch(title: umuEntry.title, steamAppID: Int(umuEntry.umuID.replacingOccurrences(of: "umu-", with: "")),
                                           umuID: umuEntry.umuID, store: umuEntry.store)
            }
        }

        let wikiTitle = report.match?.title ?? titles.first
        let appleLookup = Task { try await sources.appleGamingWiki(steamAppID: game.steamAppID ?? report.match?.steamAppID, title: wikiTitle) }

        // Packed or stub executables hide their imports, so PCGamingWiki fills in the engine, Direct3D version and
        // architecture, and can identify the game.
        let isUnreadable = exe.imports.isEmpty
        var wiki: [CompatSuggestion] = []
        if isUnreadable || exe.engine == nil {
            do {
                if let info = try await sources.pcGamingWiki(steamAppID: game.steamAppID ?? report.match?.steamAppID, title: wikiTitle) {
                    if exe.engine == nil, let (engine, detail) = info.engine {
                        exe.engine = engine
                        exe.engineDetail = detail
                    }
                    if isUnreadable {
                        if info.has64BitExecutable == true && info.has32BitExecutable != true { exe.is64Bit = true }
                        wiki = Self.wikiSuggestions(info, is64Bit: exe.is64Bit)
                    }
                    if report.match == nil, let id = info.steamAppIDs.first {
                        report.match = CompatMatch(title: info.page, steamAppID: id, umuID: nil, store: "steam")
                    }
                    report.executable = exe
                }
            } catch {
                report.errors.append("PCGamingWiki: \(error.localizedDescription)")
            }
        }

        // Game-specific fixes.
        var specific: [CompatSuggestion] = []
        if let match = report.match {
            do {
                if let fix = try await sources.protonFix(steamAppID: match.steamAppID, umuID: match.umuID ?? umuEntry?.umuID) {
                    let translated = ProtonFixTranslator.translate(fix.script, file: fix.file, knownVerbs: knownVerbs)
                    specific += translated.suggestions
                    report.notes += translated.notes
                }
            } catch {
                report.errors.append("umu-protonfixes: \(error.localizedDescription)")
            }
            if let appID = match.steamAppID { report.protonDBTier = await sources.protonDBTier(steamAppID: appID) }
        }
        if specific.isEmpty {
            let lutrisTitle = report.match?.title ?? titles.first ?? game.name
            do {
                let translated = try await sources.lutrisScripts(for: lutrisTitle)
                    .map { LutrisTranslator.translate($0.script, slug: $0.slug, knownVerbs: knownVerbs) }
                if let richest = translated.max(by: { $0.count < $1.count }) { specific += richest }
            } catch {
                report.errors.append("Lutris: \(error.localizedDescription)")
            }
        }

        let appID = game.steamAppID ?? report.match?.steamAppID
        let rules = Self.ruleSuggestions(await sources.macRules(), game: game, executable: executable, report: exe, steamAppID: appID, context: context)
        report.notes += rules.notes

        var steam: [CompatSuggestion] = []
        if let appID, let app = appInfoFiles.lazy.compactMap({ SteamAppInfo.apps([appID], in: $0)[appID] }).first {
            steam = Self.steamLaunchSuggestions(app, game: game, executable: executable)
        }

        do {
            if let mac = try await appleLookup.value { report.notes += mac.notes }
        } catch {
            report.errors.append("AppleGamingWiki: \(error.localizedDescription)")
        }
        do {
            report.communitySetups = try await sources.communitySetups(steamAppID: appID, executable: executable.lastPathComponent)
        } catch {
            report.errors.append("Community setups: \(error.localizedDescription)")
        }

        var naming: [CompatSuggestion] = []
        if let match = report.match, match.title != game.name {
            let similar = TitleMatcher.score(match.title, game.name) >= 0.95
            naming.append(CompatSuggestion(action: .rename(match.title),
                                           reason: similar ? "Official title from Steam." : "Matched title from Steam. Make sure it's the right game.",
                                           source: .macRules, recommended: similar))
        }
        // Mac rules come first: where they and a Linux fix disagree, the Mac rule wins.
        report.suggestions = rules.suggestions + steam + specific + wiki + local + naming
        report.deduplicate()
        return report
    }

    /// Steam starts games with its own launch options, which notwindows skips by starting the executable directly.
    static func steamLaunchSuggestions(_ app: VDF.Value, game: Game, executable: URL) -> [CompatSuggestion] {
        let options = SteamAppInfo.launchOptions(app)
        guard let folder = game.installFolder, let current = executable.relativePath(from: folder) else { return [] }
        func same(_ a: String, _ b: String) -> Bool {
            a.replacingOccurrences(of: "\\", with: "/").caseInsensitiveCompare(b.replacingOccurrences(of: "\\", with: "/")) == .orderedSame
        }
        if let option = options.first(where: { same($0.executable, current) }) {
            return CommandLineSplitter.split(option.arguments).map {
                CompatSuggestion(action: .argument($0), reason: "Steam starts the game with \(option.arguments). notwindows starts it directly, so it passes them on.",
                                 source: .steamAppInfo, recommended: true)
            }
        }
        // A launcher Steam starts doesn't need suggesting when the game it launches is already set.
        guard let official = options.first, let url = game.installFile(official.executable),
              ExecutableAnalyzer.launcherTarget(for: url)?.caseInsensitiveCompare(executable.lastPathComponent) != .orderedSame else { return [] }
        return [CompatSuggestion(action: .executable(official.executable), reason: "Steam starts \(CompatAction.fileName(official.executable)) for this game.",
                                 source: .steamAppInfo, recommended: true)]
    }

    /// Renderers for the Direct3D versions PCGamingWiki lists, for executables too packed to read.
    static func wikiSuggestions(_ info: WikiGameInfo, is64Bit: Bool) -> [CompatSuggestion] {
        let versions = Set(info.direct3DVersions.compactMap { Int($0.prefix { $0.isNumber }) })
        var suggestions: [CompatSuggestion] = []
        func add(_ action: CompatAction, _ reason: String) {
            suggestions.append(CompatSuggestion(action: action, reason: reason, source: .pcGamingWiki(info.page), recommended: true))
        }
        if versions.contains(12), is64Bit {
            add(.renderer(.d3dmetal), "Uses Direct3D 12, which runs through D3DMetal on macOS.")
        } else if versions.contains(11) || versions.contains(10) {
            add(.renderer(.dxmt), "Uses Direct3D \(versions.contains(11) ? 11 : 10). DXMT translates it straight to Metal.")
        }
        if versions.contains(9) || versions.contains(8) {
            add(.direct3D9(.d9vk), "Uses Direct3D \(versions.contains(9) ? 9 : 8). D9VK is faster than WineD3D for it.")
        }
        return suggestions
    }

    /// The Mac rules for a game, without changes that can't apply to it here.
    static func ruleSuggestions(_ database: MacRuleDatabase?, game: Game, executable: URL, report: ExecutableReport, steamAppID: Int?,
                                context: MacRules.Context) -> (suggestions: [CompatSuggestion], notes: [CompatNote]) {
        guard let database else { return ([], []) }
        let subject = MacRuleDatabase.Subject(steamAppID: steamAppID, executable: executable.lastPathComponent, engine: report.engine, is64Bit: report.is64Bit)
        var notes: [CompatNote] = []
        let suggestions = database.suggestions(for: subject).filter { suggestion in
            switch suggestion.action {
            case .executable(let path):
                return game.installFile(path) != nil
            case .engine(let choice) where game.isSteamGame:
                notes.append(CompatNote(text: "Runs best on \(choice.title), but Steam games run on Steam's engine. Install it outside Steam to use one.",
                                        source: suggestion.source, kind: .info))
                return false
            case .rosettaX87(true) where !context.supportsRosettaX87:
                notes.append(CompatNote(text: "Runs much faster with rosettax87, which this engine can't start games through.", source: suggestion.source, kind: .info))
                return false
            default:
                return true
            }
        }
        return (suggestions, notes)
    }
}
