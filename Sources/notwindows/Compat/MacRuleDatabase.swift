import Foundation

/// Mac-specific fixes for particular games and engines, kept in Resources/mac-rules.json. The app bundles a copy and
/// fetches the latest from GitHub, so rules can improve without a release.
struct MacRuleDatabase: Decodable {
    static let currentFormat = 1
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/alicin/notwindows/main/Resources/mac-rules.json")!
    /// Placeholders filled in when a change is applied rather than by a rule's variables.
    static let builtInPlaceholders: Set<String> = ["DOCUMENTS", "INSTALLDIR", "SCREEN_WIDTH", "SCREEN_HEIGHT"]

    var format: Int
    /// Bumped with every change, so the newer of the bundled and downloaded copies wins.
    var revision: Int
    var rules: [MacRule]

    static func decode(_ data: Data) throws -> MacRuleDatabase {
        let database = try JSONDecoder().decode(MacRuleDatabase.self, from: data)
        guard database.format <= currentFormat else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The Mac rules need a newer version of notwindows."])
        }
        return database
    }

    static var bundled: MacRuleDatabase? {
        Bundle.main.url(forResource: "mac-rules", withExtension: "json").flatMap { try? Data(contentsOf: $0) }.flatMap { try? decode($0) }
    }

    struct Subject {
        var steamAppID: Int?
        var executable: String
        var engine: ExecutableReport.GameEngine?
        var is64Bit: Bool
    }

    /// Suggestions from every rule that matches, game rules ahead of engine rules. Variables the game rules define
    /// (say, which .ini an engine rule edits) fill in the engine rules' placeholders; changes left with unknown
    /// placeholders are dropped.
    func suggestions(for subject: Subject) -> [CompatSuggestion] {
        let matched = rules.compactMap { rule in rule.match.kind(of: subject).map { (rule, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        var variables: [String: String] = [:]
        for rule in matched {
            for (key, value) in rule.variables ?? [:] where variables[key.uppercased()] == nil { variables[key.uppercased()] = value }
        }
        return matched.flatMap { rule in
            rule.actions.compactMap { item -> CompatSuggestion? in
                guard let action = item.action.substituting(variables) else { return nil }
                return CompatSuggestion(action: action, reason: item.reason, source: .macRule(rule.name), recommended: item.recommended ?? true)
            }
        }
    }
}

struct MacRule: Decodable {
    struct Match: Decodable {
        var steamAppIDs: [Int]?
        var executables: [String]?
        var engines: [String]?
        /// "32-bit" or "64-bit"; applies on top of the other criteria.
        var architecture: String?

        enum Kind: Comparable { case game, engine }

        /// Matches on any listed app ID, executable or engine.
        func kind(of subject: Subject) -> Kind? {
            if let architecture, architecture != (subject.is64Bit ? "64-bit" : "32-bit") { return nil }
            if let id = subject.steamAppID, steamAppIDs?.contains(id) == true { return .game }
            if executables?.contains(where: { $0.caseInsensitiveCompare(subject.executable) == .orderedSame }) == true { return .game }
            if let engine = subject.engine, engines?.contains(where: { $0.caseInsensitiveCompare(engine.rawValue) == .orderedSame }) == true { return .engine }
            return nil
        }

        typealias Subject = MacRuleDatabase.Subject
    }

    struct Item: Decodable {
        let action: CompatAction
        let reason: String
        var recommended: Bool?

        private enum Keys: String, CodingKey {
            case reason, recommended
            case renderer, direct3D9, cncDDraw, wineRosetta, windowsVersion, esync, msync, keepMono, dllOverride, environment, argument
            case winetricks, rosettaX87, advertiseAVX, retina, vulkanDriver, engine, executable, ini
        }

        private struct Pair: Decodable { let name: String?; let mode: String?; let key: String?; let value: String?; let family: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            reason = try c.decode(String.self, forKey: .reason)
            recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended)
            func bool(_ key: Keys) throws -> Bool? { try c.decodeIfPresent(Bool.self, forKey: key) }
            func string(_ key: Keys) throws -> String? { try c.decodeIfPresent(String.self, forKey: key) }
            func invalid(_ key: Keys) -> DecodingError {
                .dataCorruptedError(forKey: key, in: c, debugDescription: "Unknown value")
            }

            if let value = try string(.renderer) {
                guard let backend = Direct3DBackend(rawValue: value) else { throw invalid(.renderer) }
                action = .renderer(backend)
            } else if let value = try string(.direct3D9) {
                guard let backend = Direct3D9Backend(rawValue: value) else { throw invalid(.direct3D9) }
                action = .direct3D9(backend)
            } else if let on = try bool(.cncDDraw) {
                action = .cncDDraw(on)
            } else if let on = try bool(.wineRosetta) {
                action = .wineRosetta(on)
            } else if let value = try string(.windowsVersion) {
                guard let version = WindowsVersion(rawValue: value) else { throw invalid(.windowsVersion) }
                action = .windowsVersion(version)
            } else if let on = try bool(.esync) {
                action = .esync(on)
            } else if let on = try bool(.msync) {
                action = .msync(on)
            } else if try bool(.keepMono) == true {
                action = .keepMono
            } else if let pair = try c.decodeIfPresent(Pair.self, forKey: .dllOverride) {
                guard let name = pair.name, let mode = pair.mode.flatMap(DLLOverrideMode.init(rawValue:)) else { throw invalid(.dllOverride) }
                action = .dllOverride(name: name, mode: mode)
            } else if let pair = try c.decodeIfPresent(Pair.self, forKey: .environment) {
                guard let key = pair.key, let value = pair.value else { throw invalid(.environment) }
                action = .environment(key: key, value: value)
            } else if let value = try string(.argument) {
                action = .argument(value)
            } else if let value = try string(.winetricks) {
                action = .winetricks(value)
            } else if let on = try bool(.rosettaX87) {
                action = .rosettaX87(on)
            } else if let on = try bool(.advertiseAVX) {
                action = .advertiseAVX(on)
            } else if let on = try bool(.retina) {
                action = .retina(on)
            } else if let value = try string(.vulkanDriver) {
                guard let driver = VulkanDriver(rawValue: value) else { throw invalid(.vulkanDriver) }
                action = .vulkanDriver(driver)
            } else if let pair = try c.decodeIfPresent(Pair.self, forKey: .engine) {
                if let name = pair.name {
                    action = .engine(.named(name))
                } else if let family = pair.family.flatMap(EngineFamily.init(rawValue:)) {
                    action = .engine(.family(family))
                } else {
                    throw invalid(.engine)
                }
            } else if let value = try string(.executable) {
                action = .executable(value)
            } else if let ini = try c.decodeIfPresent(IniSetting.self, forKey: .ini) {
                action = .iniSetting(ini)
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "No action this version knows"))
            }
        }
    }

    let name: String
    let match: Match
    var variables: [String: String]?
    let actions: [Item]

    private enum CodingKeys: String, CodingKey { case name, match, variables, actions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        match = try c.decode(Match.self, forKey: .match)
        variables = try c.decodeIfPresent([String: String].self, forKey: .variables)
        // Actions a newer notwindows added are skipped, so an old app still uses the rest of the file.
        actions = try c.decode([Lossy<Item>].self, forKey: .actions).compactMap(\.value)
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

extension CompatAction {
    /// Fills in %NAME% placeholders from `variables`, or nil when a placeholder that isn't built in stays unknown.
    func substituting(_ variables: [String: String]) -> CompatAction? {
        func fill(_ text: String) -> String? {
            var result = text
            for (key, value) in variables { result = result.replacingOccurrences(of: "%\(key)%", with: value, options: .caseInsensitive) }
            let placeholders = result.matches(of: #/%([A-Za-z0-9_]+)%/#).map { String($0.1).uppercased() }
            return placeholders.allSatisfy(MacRuleDatabase.builtInPlaceholders.contains) ? result : nil
        }
        switch self {
        case .iniSetting(var ini):
            guard let file = fill(ini.file), let value = fill(ini.value) else { return nil }
            ini.file = file
            ini.value = value
            return .iniSetting(ini)
        case .executable(let path):
            return fill(path).map(CompatAction.executable)
        case .argument(let argument):
            return fill(argument).map(CompatAction.argument)
        case .environment(let key, let value):
            return fill(value).map { .environment(key: key, value: $0) }
        default:
            return self
        }
    }
}
