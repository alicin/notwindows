import Foundation

struct WinetricksVerb: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case dlls, fonts, settings, apps, benchmarks
        var id: String { rawValue }

        var title: String {
            switch self {
            case .dlls: "DLLs & Components"
            case .fonts: "Fonts"
            case .settings: "Settings"
            case .apps: "Apps"
            case .benchmarks: "Benchmarks"
            }
        }

        var symbol: String {
            switch self {
            case .dlls: "shippingbox"
            case .fonts: "textformat"
            case .settings: "slider.horizontal.3"
            case .apps: "app.badge"
            case .benchmarks: "speedometer"
            }
        }
    }

    let name: String
    let category: Category
    let title: String
    let publisher: String?
    let year: String?
    let media: String?
    let conflicts: [String]

    var id: String { name }

    /// Drops the long "(a.dll,b.dll,…)" lists some titles carry.
    var displayTitle: String {
        guard let open = title.firstIndex(of: "("), title[open...].contains(".dll,") else { return title }
        return title[..<open].trimmingCharacters(in: .whitespaces)
    }

    var needsDownload: Bool { media == "download" }
    /// The user has to fetch the installer themselves (licensing); winetricks can't do it unattended.
    var needsManualDownload: Bool { media == "manual_download" }
}

enum WinetricksCatalog {
    /// Verbs that commonly fix games, shown first.
    static let recommended = [
        "vcrun2022", "d3dcompiler_47", "d3dx9", "d3dx11_43", "xact", "xinput", "physx", "faudio",
        "dotnet48", "dotnetdesktop8", "webview2", "corefonts", "vd=off",
    ]

    /// Parses the `w_metadata` blocks of a winetricks script.
    static func parse(_ script: String) -> [WinetricksVerb] {
        var verbs: [WinetricksVerb] = []
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard line.hasPrefix("w_metadata ") else { continue }
            let head = line.split(separator: " ", omittingEmptySubsequences: true)
            guard head.count >= 3, let category = WinetricksVerb.Category(rawValue: String(head[2])) else { continue }

            var fields: [String: String] = [:]
            var continues = line.hasSuffix("\\")
            while continues, index < lines.count {
                let field = lines[index].trimmingCharacters(in: .whitespaces)
                index += 1
                continues = field.hasSuffix("\\")
                let body = continues ? String(field.dropLast()).trimmingCharacters(in: .whitespaces) : field
                guard let equals = body.firstIndex(of: "=") else { continue }
                let key = String(body[..<equals])
                var value = String(body[body.index(after: equals)...])
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                fields[key] = value
            }

            verbs.append(WinetricksVerb(
                name: String(head[1]),
                category: category,
                title: fields["title"] ?? String(head[1]),
                publisher: fields["publisher"],
                year: fields["year"],
                media: fields["media"],
                conflicts: fields["conflicts"]?.split(separator: " ").map(String.init) ?? []
            ))
        }
        return verbs
    }

    /// Verbs winetricks has recorded as installed in a prefix, oldest first.
    static func installedVerbs(in prefix: URL) -> [String] {
        let log = (try? String(contentsOf: prefix.appendingPathComponent("winetricks.log"), encoding: .utf8)) ?? ""
        var seen = Set<String>()
        return log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("w_workaround") && seen.insert($0).inserted }
    }

    static var cacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/winetricks", isDirectory: true)
    }
}
