import Foundation

/// What a static look at a game's executable and folder tells us.
struct ExecutableReport: Equatable {
    enum GameEngine: String { case unity = "Unity", unreal = "Unreal Engine", source = "Source", gameMaker = "GameMaker", renPy = "Ren'Py", rpgMaker = "RPG Maker" }

    var is64Bit = false
    var imports: Set<String> = []
    var isDotNet = false
    var productName: String?
    var companyName: String?
    var engine: GameEngine?
    var antiCheat: [String] = []
    var hasSteamAPI = false

    var directXLabel: String? {
        if imports.contains("d3d12.dll") { return "DirectX 12" }
        if imports.contains("d3d11.dll") { return "DirectX 11" }
        if imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") || imports.contains("d3d10core.dll") { return "DirectX 10" }
        if imports.contains("d3d9.dll") { return "DirectX 9" }
        if imports.contains("d3d8.dll") { return "DirectX 8" }
        if imports.contains("ddraw.dll") { return "DirectDraw" }
        if imports.contains("vulkan-1.dll") { return "Vulkan" }
        if imports.contains("opengl32.dll") { return "OpenGL" }
        return nil
    }

    func imports(prefix: String) -> [String] { imports.filter { $0.hasPrefix(prefix) }.sorted() }
}

/// A single change notwindows can make to a game.
enum CompatAction: Hashable {
    case renderer(Direct3DBackend)
    case direct3D9(Direct3D9Backend)
    case cncDDraw(Bool)
    case wineRosetta(Bool)
    case windowsVersion(WindowsVersion)
    case esync(Bool)
    case msync(Bool)
    case keepMono
    case dllOverride(name: String, mode: DLLOverrideMode)
    case environment(key: String, value: String)
    case argument(String)
    case winetricks(String)
    case rename(String)

    /// Short "what changes" label for the review sheet.
    var title: String {
        switch self {
        case .renderer(let b): "Direct3D 10/11/12 → \(b.title)"
        case .direct3D9(let b): "Direct3D 8/9 → \(b.title)"
        case .cncDDraw(let on): "cnc-ddraw \(on ? "on" : "off")"
        case .wineRosetta(let on): "WineRosetta \(on ? "on" : "off")"
        case .windowsVersion(let v): "Windows version → \(v.title)"
        case .esync(let on): "ESync \(on ? "on" : "off")"
        case .msync(let on): "MSync \(on ? "on" : "off")"
        case .keepMono: "Keep Wine Mono enabled"
        case .dllOverride(let name, let mode): "DLL override \(name) → \(mode.title)"
        case .environment(let key, let value): "Set \(key)=\(value)"
        case .argument(let arg): "Launch argument \(arg)"
        case .winetricks(let verb): "Install \(verb) (winetricks)"
        case .rename(let name): "Rename to “\(name)”"
        }
    }

    var symbol: String {
        switch self {
        case .renderer, .direct3D9, .cncDDraw: "display"
        case .wineRosetta, .esync, .msync: "gauge.with.dots.needle.67percent"
        case .windowsVersion, .keepMono: "macwindow"
        case .dllOverride: "puzzlepiece.extension"
        case .environment: "terminal"
        case .argument: "text.cursor"
        case .winetricks: "wand.and.stars"
        case .rename: "character.cursor.ibeam"
        }
    }

    var needsInstall: Bool { if case .winetricks = self { true } else { false } }

    /// True when the game's current settings already match.
    func isSatisfied(by game: Game, installedVerbs: Set<String>) -> Bool {
        let s = game.settings
        switch self {
        case .renderer(let b): return s.direct3DBackend == b
        case .direct3D9(let b): return s.direct3D9Backend == b
        case .cncDDraw(let on): return s.cncDDraw == on
        case .wineRosetta(let on): return s.wineRosetta == on
        case .windowsVersion(let v): return s.windowsVersion == v
        case .esync(let on): return s.esync == on
        case .msync(let on): return s.msync == on
        case .keepMono: return !s.skipMono
        case .dllOverride(let name, let mode):
            return s.dllOverrides.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.mode == mode }
        case .environment(let key, let value):
            return s.environment.contains { $0.key == key && $0.value == value }
        case .argument(let arg):
            return CommandLineSplitter.split(game.arguments).contains(arg)
        case .winetricks(let verb):
            return installedVerbs.contains(verb)
        case .rename(let name):
            return game.name == name
        }
    }

    func apply(to game: inout Game) {
        switch self {
        case .renderer(let b): game.settings.direct3DBackend = b
        case .direct3D9(let b): game.settings.direct3D9Backend = b
        case .cncDDraw(let on): game.settings.cncDDraw = on
        case .wineRosetta(let on): game.settings.wineRosetta = on
        case .windowsVersion(let v): game.settings.windowsVersion = v
        case .esync(let on): game.settings.esync = on
        case .msync(let on): game.settings.msync = on
        case .keepMono: game.settings.skipMono = false
        case .dllOverride(let name, let mode):
            game.settings.dllOverrides.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            game.settings.dllOverrides.append(DLLOverride(name: name, mode: mode))
        case .environment(let key, let value):
            game.settings.environment.removeAll { $0.key == key }
            game.settings.environment.append(EnvironmentVariable(key: key, value: value))
        case .argument(let arg):
            let quoted = arg.contains(" ") ? "\"\(arg)\"" : arg
            game.arguments = game.arguments.trimmingCharacters(in: .whitespaces).isEmpty ? quoted : game.arguments + " " + quoted
        case .winetricks:
            break
        case .rename(let name):
            game.name = name
        }
    }
}

enum CompatSource: Hashable {
    case executable
    case macRules
    case protonFixes(file: String)
    case lutris(slug: String)

    var title: String {
        switch self {
        case .executable: "Detected from the executable"
        case .macRules: "macOS recommendations"
        case .protonFixes: "umu-protonfixes"
        case .lutris(let slug): "Lutris installer (\(slug))"
        }
    }
}

struct CompatSuggestion: Identifiable, Hashable {
    let action: CompatAction
    let reason: String
    let source: CompatSource
    /// Pre-checked in the review sheet and applied automatically to new games.
    let recommended: Bool

    var id: String { "\(source)-\(action)" }
}

/// Something from a fix that notwindows can't translate (registry edits, file patches, Linux-only tweaks).
struct CompatNote: Identifiable, Hashable {
    let text: String
    let source: CompatSource
    var id: String { "\(source)-\(text)" }
}

struct CompatMatch: Hashable {
    let title: String
    let steamAppID: Int?
    let umuID: String?
    let store: String?
}

struct CompatReport {
    var executable: ExecutableReport?
    var match: CompatMatch?
    var alternatives: [CompatMatch] = []
    var protonDBTier: String?
    var suggestions: [CompatSuggestion] = []
    var notes: [CompatNote] = []
    var warnings: [String] = []
    var errors: [String] = []

    /// Drops later duplicates of the same action, so earlier, more specific sources win.
    mutating func deduplicate() {
        var seen = Set<CompatAction>()
        var conflictKeys = Set<String>()
        suggestions = suggestions.filter { suggestion in
            guard seen.insert(suggestion.action).inserted else { return false }
            let key = Self.conflictKey(suggestion.action)
            if let key { return conflictKeys.insert(key).inserted }
            return true
        }
    }

    private static func conflictKey(_ action: CompatAction) -> String? {
        switch action {
        case .renderer: "renderer"
        case .direct3D9: "d3d9"
        case .cncDDraw: "cnc"
        case .wineRosetta: "winerosetta"
        case .windowsVersion: "winver"
        case .esync: "esync"
        case .msync: "msync"
        case .dllOverride(let name, _): "dll-\(name.lowercased())"
        case .environment(let key, _): "env-\(key)"
        case .rename: "rename"
        default: nil
        }
    }
}
