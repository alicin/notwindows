import Foundation

enum TitleMatcher {
    private static let noise: Set<String> = ["the", "a", "an", "of", "edition", "goty", "game", "year", "definitive", "remastered", "enhanced", "complete", "deluxe", "hd"]

    static func tokens(_ title: String) -> [String] {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        let spaced = folded
            .replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"[^A-Za-z0-9]+"#, with: " ", options: .regularExpression)
            .lowercased()
        return spaced.split(separator: " ").map(String.init).filter { !noise.contains($0) }
    }

    /// 0...1 similarity between two titles, tolerant of subtitles, punctuation and roman numerals.
    static func score(_ a: String, _ b: String) -> Double {
        let ta = tokens(a).map(normalizeNumeral), tb = tokens(b).map(normalizeNumeral)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if ta == tb { return 1 }
        let joinedA = ta.joined(), joinedB = tb.joined()
        if joinedA == joinedB { return 0.98 }
        let setA = Set(ta), setB = Set(tb)
        let jaccard = Double(setA.intersection(setB).count) / Double(setA.union(setB).count)
        if setA.isSubset(of: setB) || setB.isSubset(of: setA) { return max(jaccard, 0.75) }
        if joinedA.hasPrefix(joinedB) || joinedB.hasPrefix(joinedA) { return max(jaccard, 0.7) }
        return jaccard
    }

    private static func normalizeNumeral(_ token: String) -> String {
        ["i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"][token] ?? token
    }
}

struct UMUEntry: Hashable {
    let title: String
    let store: String
    let codename: String
    let umuID: String
    let acronym: String
    let exeStrings: [String]
}

/// Network lookups for compatibility data, cached under the library's Cache folder.
actor CompatSources {
    static let shared = CompatSources()

    private let protonFixesBase = "https://raw.githubusercontent.com/Open-Wine-Components/umu-protonfixes/master"
    private let umuDatabaseURL = URL(string: "https://raw.githubusercontent.com/Open-Wine-Components/umu-database/main/umu-database.csv")!
    private var umuEntries: [UMUEntry]?

    private var cacheDirectory: URL {
        let url = Paths.root.appendingPathComponent("Cache/compat", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Cached fetch

    /// Returns cached data younger than `maxAge`, otherwise fetches. A 404 is cached as an empty body, and so is a
    /// response `isUsable` turns down.
    private func fetch(_ url: URL, cacheName: String, maxAge: TimeInterval = 3 * 86_400, isUsable: ((Data) -> Bool)? = nil) async throws -> Data? {
        let file = cacheDirectory.appendingPathComponent(cacheName)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < maxAge,
           let data = try? Data(contentsOf: file) {
            return data.isEmpty ? nil : data
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("notwindows/0.1 (+https://github.com/alicin/notwindows)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                try? Data().write(to: file)
                return nil
            }
            guard (200..<300).contains(status) else {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "\(url.host() ?? "Server") returned HTTP \(status)"])
            }
            if let isUsable, !isUsable(data) { return nil }
            try? data.write(to: file)
            return data
        } catch {
            if let stale = try? Data(contentsOf: file) { return stale.isEmpty ? nil : stale }
            throw error
        }
    }

    // MARK: Mac rules

    /// The newer of the bundled rules and the latest on GitHub. Offline, the bundled copy is enough.
    func macRules() async -> MacRuleDatabase? {
        let bundled = MacRuleDatabase.bundled
        guard let data = try? await fetch(MacRuleDatabase.remoteURL, cacheName: "mac-rules.json", maxAge: 86_400),
              let remote = try? MacRuleDatabase.decode(data), remote.revision > bundled?.revision ?? -1 else { return bundled }
        return remote
    }

    // MARK: umu-database

    func umuDatabase() async throws -> [UMUEntry] {
        if let umuEntries { return umuEntries }
        guard let data = try await fetch(umuDatabaseURL, cacheName: "umu-database.csv", maxAge: 86_400) else { return [] }
        let entries = Self.parseUMUDatabase(String(decoding: data, as: UTF8.self))
        umuEntries = entries
        return entries
    }

    static func parseUMUDatabase(_ csv: String) -> [UMUEntry] {
        var rows = parseCSV(csv)
        guard !rows.isEmpty else { return [] }
        rows.removeFirst()
        return rows.compactMap { row in
            guard row.count >= 4, !row[0].isEmpty, !row[3].isEmpty else { return nil }
            return UMUEntry(
                title: row[0], store: row[1], codename: row[2], umuID: row[3],
                acronym: row.count > 4 ? row[4] : "",
                exeStrings: row.count > 6 ? row[6].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } : []
            )
        }
    }

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?
        while let ch = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else { inQuotes = false }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
            } else if ch == "," {
                row.append(field); field = ""
            } else if ch == "\n" || ch == "\r\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else if ch != "\r" {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Steam

    struct SteamApp: Hashable {
        let id: Int
        let name: String
    }

    func steamSearch(_ term: String) async throws -> [SteamApp] {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch")!
        components.queryItems = [.init(name: "term", value: term), .init(name: "cc", value: "us"), .init(name: "l", value: "en")]
        let key = "steam-" + term.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression) + ".json"
        guard let data = try await fetch(components.url!, cacheName: key, maxAge: 7 * 86_400),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard item["type"] as? String == "app", let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return SteamApp(id: id, name: name)
        }
    }

    // MARK: Fixes

    /// Looks up a protonfix by Steam app ID or umu ID and returns (file name, source).
    func protonFix(steamAppID: Int?, umuID: String?) async throws -> (file: String, script: String)? {
        var candidates: [String] = []
        if let steamAppID { candidates.append("gamefixes-steam/\(steamAppID).py") }
        if let umuID {
            candidates.append("gamefixes-umu/\(umuID).py")
            if let number = Int(umuID.replacingOccurrences(of: "umu-", with: "")), number != steamAppID {
                candidates.append("gamefixes-steam/\(number).py")
            }
        }
        for path in candidates {
            let url = URL(string: "\(protonFixesBase)/\(path)")!
            if let data = try await fetch(url, cacheName: "fix-" + path.replacingOccurrences(of: "/", with: "_")) {
                return (path, String(decoding: data, as: UTF8.self))
            }
        }
        return nil
    }

    // MARK: Lutris

    func lutrisScripts(for title: String) async throws -> [(slug: String, script: [String: Any])] {
        var components = URLComponents(string: "https://lutris.net/api/games")!
        components.queryItems = [.init(name: "search", value: title)]
        let key = "lutris-search-" + title.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression) + ".json"
        guard let data = try await fetch(components.url!, cacheName: key, maxAge: 7 * 86_400),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        let best = results
            .compactMap { r -> (slug: String, score: Double)? in
                guard let name = r["name"] as? String, let slug = r["slug"] as? String else { return nil }
                return (slug, TitleMatcher.score(name, title))
            }
            .filter { $0.score >= 0.75 }
            .max { $0.score < $1.score }
        guard let slug = best?.slug,
              let installersData = try await fetch(URL(string: "https://lutris.net/api/installers/\(slug)")!, cacheName: "lutris-\(slug).json", maxAge: 7 * 86_400),
              let installers = try JSONSerialization.jsonObject(with: installersData) as? [String: Any],
              let list = installers["results"] as? [[String: Any]] else { return [] }

        return list.compactMap { installer in
            guard installer["runner"] as? String == "wine", let script = installer["script"] as? [String: Any] else { return nil }
            return ((installer["slug"] as? String) ?? slug, script)
        }
    }

    // MARK: Wikis

    static let pcGamingWikiAPI = "https://www.pcgamingwiki.com/w/api.php"
    static let appleGamingWikiAPI = "https://www.applegamingwiki.com/w/api.php"

    /// PCGamingWiki's infobox for a game, found by Steam app ID or else by title. Cargo queries need an account since
    /// August 2026, so this reads the page's wikitext.
    func pcGamingWiki(steamAppID: Int?, title: String?) async throws -> WikiGameInfo? {
        guard let page = try await wikiPage(api: Self.pcGamingWikiAPI, cache: "pcgw", steamAppID: steamAppID, title: title, maxAge: 30 * 86_400) else { return nil }
        return WikiGameInfo(page: page.title, wikitext: page.wikitext)
    }

    func appleGamingWiki(steamAppID: Int?, title: String?) async throws -> MacCompatibility? {
        guard let page = try await wikiPage(api: Self.appleGamingWikiAPI, cache: "agw", steamAppID: steamAppID, title: title, maxAge: 7 * 86_400) else { return nil }
        return MacCompatibility(page: page.title, wikitext: page.wikitext)
    }

    private func wikiPage(api: String, cache: String, steamAppID: Int?, title: String?, maxAge: TimeInterval) async throws -> (title: String, wikitext: String)? {
        func url(_ items: [String: String]) -> URL {
            var components = URLComponents(string: api)!
            components.queryItems = (items.merging(["format": "json", "formatversion": "2"]) { a, _ in a }).sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return components.url!
        }
        func slug(_ text: String) -> String { text.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression) }
        // MediaWiki reports errors, like a lookup that's down for a while, inside a successful response.
        let noError: (Data) -> Bool = { data in ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] == nil }

        var page: String?
        if let steamAppID,
           let data = try await fetch(url(["action": "idlookup", "field": "steamappid", "value": String(steamAppID)]), cacheName: "\(cache)-id-\(steamAppID).json", maxAge: maxAge, isUsable: noError),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["idlookup"] as? [[String: Any]] {
            page = results.lazy.compactMap { ($0["title"] as? [String: Any])?["Page"] as? String }.first
        }
        if page == nil, let title, !title.isEmpty,
           let data = try await fetch(url(["action": "query", "list": "search", "srsearch": title, "srlimit": "5"]), cacheName: "\(cache)-search-\(slug(title)).json", maxAge: maxAge, isUsable: noError),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hits = (json["query"] as? [String: Any])?["search"] as? [[String: Any]] {
            page = hits.compactMap { $0["title"] as? String }
                .map { ($0, TitleMatcher.score($0, title)) }
                .filter { $0.1 >= 0.85 }
                .max { $0.1 < $1.1 }?.0
        }
        guard let page,
              let data = try await fetch(url(["action": "parse", "page": page, "prop": "wikitext", "redirects": "1"]), cacheName: "\(cache)-page-\(slug(page)).json", maxAge: maxAge, isUsable: noError),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = json["parse"] as? [String: Any], let wikitext = parsed["wikitext"] as? String else { return nil }
        // A page found by title has to be the same Steam app, when both sides know it.
        if let steamAppID, let infobox = WikiText.template("Infobox game", in: wikitext), let ids = infobox["steam appid"], !ids.isEmpty,
           !ids.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == String(steamAppID) }) {
            return nil
        }
        return ((parsed["title"] as? String) ?? page, wikitext)
    }

    // MARK: ProtonDB

    func protonDBTier(steamAppID: Int) async -> String? {
        guard let data = try? await fetch(URL(string: "https://www.protondb.com/api/v1/reports/summaries/\(steamAppID).json")!,
                                          cacheName: "protondb-\(steamAppID).json", maxAge: 7 * 86_400),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["tier"] as? String
    }

    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        umuEntries = nil
    }
}
