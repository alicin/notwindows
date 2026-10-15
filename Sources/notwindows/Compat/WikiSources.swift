import Foundation

/// Just enough MediaWiki markup reading for the infobox templates PCGamingWiki and AppleGamingWiki pages share.
enum WikiText {
    /// The named parameters of the first `{{name …}}` template, with keys lowercased.
    static func template(_ name: String, in text: String) -> [String: String]? {
        guard let start = text.range(of: "{{" + name, options: .caseInsensitive) else { return nil }
        // The name must end there, so "{{API" doesn't match "{{APIs".
        if let next = text[start.upperBound...].first, !(next == "|" || next == "}" || next.isWhitespace) { return nil }
        var depth = 0
        var index = start.lowerBound
        var body = ""
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("{{") || rest.hasPrefix("[[") {
                depth += 1
                if depth > 1 { body += rest.prefix(2) }
                index = text.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("}}") || rest.hasPrefix("]]") {
                depth -= 1
                if depth == 0 { break }
                body += rest.prefix(2)
                index = text.index(index, offsetBy: 2)
                continue
            }
            body.append(text[index])
            index = text.index(after: index)
        }
        var parameters: [String: String] = [:]
        for part in splitTopLevel(String(body.dropFirst(name.count))).dropFirst() {
            guard let equals = part.firstIndex(of: "=") else { continue }
            let key = part[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            parameters[key] = part[part.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return parameters
    }

    /// Splits on `|` outside nested templates and links.
    static func splitTopLevel(_ text: String) -> [String] {
        var parts = [""]
        var depth = 0
        var previous: Character?
        for character in text {
            if (character == "{" || character == "[") && previous == character { depth += 1 }
            if (character == "}" || character == "]") && previous == character { depth -= 1 }
            if character == "|" && depth == 0 { parts.append("") } else { parts[parts.count - 1].append(character) }
            previous = character
        }
        return parts
    }

    /// The first positional argument of every `{{name|value…}}` row template, e.g. each engine of an infobox.
    static func rows(_ name: String, in text: String) -> [String] {
        text.components(separatedBy: "{{").dropFirst().compactMap { piece in
            let inner = piece.components(separatedBy: "}}").first ?? piece
            let fields = inner.components(separatedBy: "|")
            guard fields.count > 1, fields[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Readable text: references, templates and markup removed, links reduced to their labels.
    static func plain(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"(?s)<ref[^>]*/>"#, ""), (#"(?s)<ref[^>]*>.*?</ref>"#, ""), (#"(?s)<[^>]+>"#, ""),
            (#"\{\{[^{}]*\}\}"#, ""), (#"\[\[(?:[^|\]]*\|)?([^\]]*)\]\]"#, "$1"), (#"\[https?://\S+ ([^\]]*)\]"#, "$1"),
            (#"'{2,}"#, ""), (#"\s+"#, " "),
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// What PCGamingWiki's infobox and API table say about a game.
struct WikiGameInfo: Equatable {
    var page: String
    var engines: [String] = []
    var direct3DVersions: [String] = []
    var has64BitExecutable: Bool?
    var has32BitExecutable: Bool?
    var steamAppIDs: [Int] = []

    init(page: String, wikitext: String) {
        self.page = page
        if let infobox = WikiText.template("Infobox game", in: wikitext) {
            engines = WikiText.rows("Infobox game/row/engine", in: infobox["engines"] ?? "")
            steamAppIDs = (infobox["steam appid"] ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        if let api = WikiText.template("API", in: wikitext) {
            direct3DVersions = (api["direct3d versions"] ?? "").split(separator: ",").map { WikiText.plain(String($0)) }.filter { !$0.isEmpty }
            has64BitExecutable = api["windows 64-bit exe"].flatMap(Self.flag)
            has32BitExecutable = api["windows 32-bit exe"].flatMap(Self.flag)
        }
    }

    private static func flag(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    /// The engine as notwindows names it, e.g. "Gamebryo (TES Engine)" → Gamebryo.
    var engine: (ExecutableReport.GameEngine, String?)? {
        for name in engines {
            let lower = name.lowercased()
            if lower.hasPrefix("unreal engine") {
                return (.unreal, lower.dropFirst("unreal engine".count).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first.flatMap { $0.isEmpty ? nil : $0 })
            }
            if lower.hasPrefix("id tech") { return (.idTech, lower.dropFirst("id tech".count).trimmingCharacters(in: .whitespaces).nilIfEmpty) }
            let known: [(String, ExecutableReport.GameEngine)] = [
                ("gamebryo", .gamebryo), ("netimmerse", .gamebryo), ("creation engine", .creation), ("unity", .unity), ("source", .source),
                ("cryengine", .cryEngine), ("renderware", .renderWare), ("gamemaker", .gameMaker), ("ren'py", .renPy), ("rpg maker", .rpgMaker),
            ]
            if let (_, engine) = known.first(where: { lower.hasPrefix($0.0) }) { return (engine, nil) }
        }
        return nil
    }
}

/// AppleGamingWiki's verdicts on running a game on a Mac, from its `{{Compatibility/macOS}}` table.
struct MacCompatibility: Equatable {
    struct Entry: Equatable {
        let method: String
        let rating: String
        let notes: String
    }

    var page: String
    var entries: [Entry]

    /// Methods worth showing next to notwindows, in this order: a native or Apple Silicon build trumps everything.
    private static let methods: [(key: String, title: String)] = [
        ("native", "Native Mac version"), ("rosetta 2", "Native Intel version (Rosetta 2)"), ("crossover", "CrossOver"),
        ("wine", "Wine"), ("whisky", "Whisky"), ("gptk", "Game Porting Toolkit"), ("porting kit", "Porting Kit"), ("cxpatcher", "CXPatcher"),
    ]

    init(page: String, wikitext: String) {
        self.page = page
        let table = WikiText.template("Compatibility/macOS", in: wikitext) ?? [:]
        entries = Self.methods.compactMap { key, title in
            guard let rating = table[key].map(WikiText.plain), !rating.isEmpty, !["na", "n/a", "unknown", "?"].contains(rating.lowercased()) else { return nil }
            return Entry(method: title, rating: rating, notes: table["\(key) notes"].map(WikiText.plain) ?? "")
        }
    }

    var notes: [CompatNote] {
        entries.map { entry in
            let text = "\(entry.method): \(entry.rating.capitalizedFirst)" + (entry.notes.isEmpty ? "" : ". \(entry.notes)")
            return CompatNote(text: text, source: .appleGamingWiki(page), kind: .info)
        }
    }
}

extension StringProtocol {
    var nilIfEmpty: String? { isEmpty ? nil : String(self) }
}
