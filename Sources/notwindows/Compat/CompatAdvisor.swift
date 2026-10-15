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

    static func analyze(game: Game, knownVerbs: Set<String>, preferredMatch: CompatMatch? = nil, supportsRosettaX87: Bool = true) async -> CompatReport {
        var report = CompatReport()
        guard let executable = game.executableURL, executable.exists else {
            report.errors.append("The game doesn't have an executable yet.")
            return report
        }

        let exe = await Task.detached(priority: .userInitiated) { ExecutableAnalyzer.analyze(executable) }.value
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

        let rules = Self.ruleSuggestions(await sources.macRules(), game: game, executable: executable, report: exe,
                                         steamAppID: game.steamAppID ?? report.match?.steamAppID, context: context)
        report.notes += rules.notes

        var naming: [CompatSuggestion] = []
        if let match = report.match, match.title != game.name {
            let similar = TitleMatcher.score(match.title, game.name) >= 0.95
            naming.append(CompatSuggestion(action: .rename(match.title),
                                           reason: similar ? "Official title from Steam." : "Matched title from Steam. Make sure it's the right game.",
                                           source: .macRules, recommended: similar))
        }
        // Mac rules come first: where they and a Linux fix disagree, the Mac rule wins.
        report.suggestions = rules.suggestions + specific + local + naming
        report.deduplicate()
        return report
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
