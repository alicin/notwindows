import Foundation

/// Setups players share through pull requests to community/setups in the notwindows repository: one folder per game
/// ("22380-fallout-new-vegas" for a Steam game, the executable's name otherwise) holding .notwindows files.
enum CommunitySetups {
    static let repository = "alicin/notwindows"
    static let branch = "main"
    static let folder = "community/setups"

    struct Setup: Identifiable, Equatable {
        let path: String
        let shared: SharedSettings
        var id: String { path }
    }

    /// The folder a game's setups go in.
    static func folderName(steamAppID: Int?, game: String, executable: String?) -> String? {
        if let steamAppID { return "\(steamAppID)-" + slug(game) }
        return executable.map { $0.lowercased() }
    }

    static func matches(folder: String, steamAppID: Int?, executable: String?) -> Bool {
        let name = folder.lowercased()
        if let steamAppID, name == String(steamAppID) || name.hasPrefix("\(steamAppID)-") { return true }
        return executable.map { name == $0.lowercased() } ?? false
    }

    /// The .notwindows files in the repository's tree (from GitHub's git trees API) that belong to the game.
    static func paths(inTree data: Data, steamAppID: Int?, executable: String?) -> [(path: String, sha: String)] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tree = json["tree"] as? [[String: Any]] else { return [] }
        return tree.compactMap { item in
            guard item["type"] as? String == "blob", let path = item["path"] as? String, let sha = item["sha"] as? String,
                  path.hasPrefix(folder + "/"), path.lowercased().hasSuffix("." + SharedSettings.fileExtension) else { return nil }
            let parts = path.dropFirst(folder.count + 1).split(separator: "/")
            guard parts.count == 2, matches(folder: String(parts[0]), steamAppID: steamAppID, executable: executable) else { return nil }
            return (path, sha)
        }
    }

    static func rawURL(_ path: String) -> URL? {
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "https://raw.githubusercontent.com/\(repository)/\(branch)/\(encoded)")
    }

    /// GitHub's page for adding the setup as a new file, filled in. Someone without write access gets a fork and a
    /// pull request out of it, which is how setups are reviewed before they're listed.
    static func submissionURL(for shared: SharedSettings, date: Date = Date()) throws -> URL? {
        guard let folder = folderName(steamAppID: shared.steamAppID, game: shared.game, executable: shared.executable) else { return nil }
        let day = date.formatted(.iso8601.year().month().day())
        let file = [slug(shared.chip ?? shared.mac ?? "mac"), day].joined(separator: "-") + "." + SharedSettings.fileExtension
        var components = URLComponents(string: "https://github.com/\(repository)/new/\(branch)/\(Self.folder)/\(folder)")
        components?.queryItems = [URLQueryItem(name: "filename", value: file),
                                  URLQueryItem(name: "value", value: String(decoding: try shared.encoded(), as: UTF8.self))]
        return components?.url
    }

    static func slug(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US")).lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
