import Foundation

/// Parser for Valve's text KeyValues format (.vdf / .acf).
enum VDF {
    indirect enum Value: Equatable {
        case string(String)
        case object([(key: String, value: Value)])

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.string(let a), .string(let b)): a == b
            case (.object(let a), .object(let b)): a.map(\.key) == b.map(\.key) && zip(a, b).allSatisfy { $0.value == $1.value }
            default: false
            }
        }

        subscript(key: String) -> Value? {
            guard case .object(let pairs) = self else { return nil }
            return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }

        var string: String? { if case .string(let s) = self { s } else { nil } }
        var pairs: [(key: String, value: Value)] { if case .object(let p) = self { p } else { [] } }
    }

    static func parse(_ text: String) -> Value {
        var tokens = tokenize(text)[...]
        return .object(parseObject(&tokens))
    }

    private enum Token: Equatable { case string(String), open, close }

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.first {
            switch c {
            case "{": tokens.append(.open); chars.removeFirst()
            case "}": tokens.append(.close); chars.removeFirst()
            case "\"":
                chars.removeFirst()
                var value = String.UnicodeScalarView()
                while let d = chars.first, d != "\"" {
                    chars.removeFirst()
                    if d == "\\", let escaped = chars.first {
                        chars.removeFirst()
                        switch escaped {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        default: value.append(escaped)
                        }
                    } else {
                        value.append(d)
                    }
                }
                if !chars.isEmpty { chars.removeFirst() }
                tokens.append(.string(String(value)))
            case "/" where chars.dropFirst().first == "/":
                while let d = chars.first, d != "\n" { chars.removeFirst() }
            default:
                if CharacterSet.whitespacesAndNewlines.contains(c) {
                    chars.removeFirst()
                } else {
                    var value = String.UnicodeScalarView()
                    while let d = chars.first, !CharacterSet.whitespacesAndNewlines.contains(d), d != "{", d != "}", d != "\"" {
                        value.append(d); chars.removeFirst()
                    }
                    tokens.append(.string(String(value)))
                }
            }
        }
        return tokens
    }

    private static func parseObject(_ tokens: inout ArraySlice<Token>) -> [(key: String, value: Value)] {
        var pairs: [(key: String, value: Value)] = []
        while let token = tokens.popFirst() {
            guard case .string(let key) = token else { break }
            switch tokens.popFirst() {
            case .string(let value): pairs.append((key, .string(value)))
            case .open: pairs.append((key, .object(parseObject(&tokens))))
            default: return pairs
            }
        }
        return pairs
    }
}

/// A game Windows Steam has installed inside a prefix.
struct SteamInstalledApp: Hashable {
    let appID: Int
    let name: String
    let installDirectory: URL
    let isFullyInstalled: Bool
}

enum SteamLibraryScanner {
    static let steamFolderCandidates = ["Program Files (x86)/Steam", "Program Files/Steam"]

    /// The Steam client folder inside a prefix, if Steam is installed there.
    static func steamRoot(in prefix: URL) -> URL? {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        return steamFolderCandidates.map { driveC.appendingPathComponent($0, isDirectory: true) }
            .first { $0.appendingPathComponent("steamapps").isDirectoryURL || $0.appendingPathComponent("steam.exe").exists }
    }

    /// Converts a Windows path from Steam's config (e.g. `D:\\Games\\SteamLibrary`) to a path on the Mac.
    static func unixPath(fromWindows path: String, prefix: URL) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2, normalized.dropFirst().first == ":" else { return nil }
        let drive = normalized.prefix(1).lowercased()
        let rest = String(normalized.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base: URL
        if drive == "c" {
            base = prefix.appendingPathComponent("drive_c", isDirectory: true)
        } else {
            base = prefix.appendingPathComponent("dosdevices/\(drive):", isDirectory: true).resolvingSymlinksInPath()
        }
        return rest.isEmpty ? base : base.appendingPathComponent(rest, isDirectory: true)
    }

    /// Every `steamapps` folder Steam knows about in this prefix.
    static func libraryFolders(steamRoot: URL, prefix: URL) -> [URL] {
        var folders = [steamRoot.appendingPathComponent("steamapps", isDirectory: true)]
        let config = steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf")
        if let text = try? String(contentsOf: config, encoding: .utf8) {
            let root = VDF.parse(text)
            let libraries = root["libraryfolders"] ?? root["LibraryFolders"]
            for (_, entry) in libraries?.pairs ?? [] {
                let path = entry["path"]?.string ?? entry.string
                if let path, let url = unixPath(fromWindows: path, prefix: prefix) {
                    folders.append(url.appendingPathComponent("steamapps", isDirectory: true))
                }
            }
        }
        var seen = Set<String>()
        return folders.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }

    static func installedApps(in prefix: URL) -> [SteamInstalledApp] {
        guard let root = steamRoot(in: prefix) else { return [] }
        var apps: [SteamInstalledApp] = []
        for steamapps in libraryFolders(steamRoot: root, prefix: prefix) {
            let files = (try? FileManager.default.contentsOfDirectory(at: steamapps, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent.hasPrefix("appmanifest_") && file.pathExtension == "acf" {
                guard let text = try? String(contentsOf: file, encoding: .utf8),
                      let app = parseManifest(text, steamapps: steamapps) else { continue }
                apps.append(app)
            }
        }
        return apps
            .filter { !isTool($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseManifest(_ text: String, steamapps: URL) -> SteamInstalledApp? {
        guard let state = VDF.parse(text)["AppState"],
              let appID = state["appid"]?.string.flatMap(Int.init),
              let installDir = state["installdir"]?.string, !installDir.isEmpty else { return nil }
        let flags = state["StateFlags"]?.string.flatMap(Int.init) ?? 0
        return SteamInstalledApp(
            appID: appID,
            name: state["name"]?.string ?? installDir,
            installDirectory: steamapps.appendingPathComponent("common/\(installDir)", isDirectory: true),
            isFullyInstalled: flags & 4 != 0
        )
    }

    /// Steamworks redistributables and runtimes that Steam installs alongside games.
    private static func isTool(_ app: SteamInstalledApp) -> Bool {
        [228980, 1070560, 1391110, 1628350, 1493710, 1826330, 2180100].contains(app.appID)
            || app.name.hasPrefix("Steamworks Common")
            || app.name.hasPrefix("Proton")
            || app.name.hasPrefix("Steam Linux Runtime")
    }

    /// Picks the most likely game executable inside an install folder.
    static func mainExecutable(in installDirectory: URL, name: String) -> URL? {
        let candidates = ExecutableScanner.scan(installDirectory, limit: 20)
        guard !candidates.isEmpty else { return nil }
        return candidates
            .map { candidate -> (URL, Double) in
                let stem = candidate.url.deletingPathExtension().lastPathComponent
                let bonus = TitleMatcher.score(stem, name) * 20
                return (candidate.url, Double(candidate.score) + bonus)
            }
            .max { $0.1 < $1.1 }?.0
    }
}
