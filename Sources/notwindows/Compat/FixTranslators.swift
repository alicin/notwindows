import Foundation

/// Reads umu-protonfixes Python game fixes without running them, turning the common `util.*` calls into actions.
enum ProtonFixTranslator {
    /// Proton/Linux-only environment variables that mean nothing to a macOS Wine build.
    private static let ignoredEnvironmentPrefixes = [
        "PROTON_", "UMU_", "STEAM", "SteamDeck", "PULSE_", "radeonsi", "RADV_", "mesa_", "MESA_", "__GL_", "vk_",
        "VKD3D_", "DXVK_NVAPI", "WINE_DISABLE_VULKAN_OPWR", "LD_", "SDL_VIDEODRIVER", "ENABLE_VKBASALT", "STAGING_",
    ]

    /// Verbs that change the renderer on Linux; notwindows handles renderers itself.
    private static let rendererVerbs: Set<String> = ["dxvk", "vkd3d", "d3d11=builtin", "d3d10=builtin", "d3d9=builtin", "dxvk_nvapi"]

    private static let overrideOrders: [String: DLLOverrideMode] = [
        "NATIVE_BUILTIN": .nativeThenBuiltin, "BUILTIN_NATIVE": .builtinThenNative, "NATIVE": .native, "BUILTIN": .builtin, "DISABLED": .disabled,
        "n,b": .nativeThenBuiltin, "b,n": .builtinThenNative, "n": .native, "b": .builtin, "": .disabled,
    ]

    static func translate(_ script: String, file: String, knownVerbs: Set<String>) -> (suggestions: [CompatSuggestion], notes: [CompatNote]) {
        let source = CompatSource.protonFixes(file: file)
        var suggestions: [CompatSuggestion] = []
        var notes: [CompatNote] = []
        func add(_ action: CompatAction, _ reason: String, recommended: Bool = true) {
            suggestions.append(CompatSuggestion(action: action, reason: reason, source: source, recommended: recommended))
        }
        let fileSummary = docstring(script)

        for call in calls(in: script) {
            let args = call.arguments
            let summary = call.comment ?? fileSummary
            switch call.name {
            case "protontricks":
                for verb in args.first.map({ $0.split(separator: " ").map(String.init) }) ?? [] {
                    if rendererVerbs.contains(verb) || verb.hasPrefix("dxvk") || verb.hasPrefix("vkd3d") {
                        notes.append(CompatNote(text: "Skipped \(verb): notwindows picks the renderer itself.", source: source))
                    } else if let version = WindowsVersion(rawValue: verb) {
                        add(.windowsVersion(version), summary ?? "Fix sets \(verb).")
                    } else if knownVerbs.isEmpty || knownVerbs.contains(verb) {
                        add(.winetricks(verb), summary ?? "The game's fix installs \(verb).")
                    } else {
                        notes.append(CompatNote(text: "Winetricks verb \(verb) isn't available in Sikarugir's winetricks.", source: source))
                    }
                }
            case "winedll_override":
                guard args.count >= 2, let mode = overrideOrders[args[1].replacingOccurrences(of: "util.OverrideOrder.", with: "").replacingOccurrences(of: "OverrideOrder.", with: "")] else { continue }
                add(.dllOverride(name: args[0], mode: mode), summary ?? "The game's fix overrides \(args[0]).")
            case "set_environment":
                guard args.count >= 2 else { continue }
                if ignoredEnvironmentPrefixes.contains(where: args[0].hasPrefix) {
                    notes.append(CompatNote(text: "Skipped \(args[0])=\(args[1]): Linux/Proton only.", source: source))
                } else {
                    add(.environment(key: args[0], value: args[1]), summary ?? "The game's fix sets \(args[0]).", recommended: !args[0].hasPrefix("DXVK_"))
                }
            case "append_argument":
                for arg in args.first.map(CommandLineSplitter.split) ?? [] {
                    add(.argument(arg), summary ?? "The game's fix adds \(arg) to the command line.")
                }
            case "disable_esync":
                add(.esync(false), summary ?? "The game's fix turns off esync.")
            case "disable_fsync":
                add(.msync(false), summary ?? "The game's fix turns off fsync; MSync is the macOS equivalent.", recommended: false)
            default:
                let rendered = "\(call.name)(\(args.joined(separator: ", ")))"
                notes.append(CompatNote(text: "Not translated: \(rendered)", source: source))
            }
        }
        return (suggestions, notes)
    }

    struct Call: Equatable {
        let name: String
        let arguments: [String]
        /// The `#` comment directly above the call, which usually explains it.
        var comment: String?
    }

    /// Finds `util.name(...)` calls and their string/identifier arguments.
    static func calls(in script: String) -> [Call] {
        var result: [Call] = []
        let pattern = #"util\.([a-z_]+)\(([^()]*(?:\([^()]*\)[^()]*)*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        var comment: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let text = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty && !text.hasPrefix("http") && !text.hasPrefix("util.") { comment.append(text) }
                continue
            }
            let text = String(line)
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches {
                guard let name = Range(match.range(at: 1), in: text), let args = Range(match.range(at: 2), in: text) else { continue }
                result.append(Call(name: String(text[name]), arguments: splitArguments(String(text[args])),
                                   comment: comment.isEmpty ? nil : comment.joined(separator: " ")))
            }
            if trimmed.isEmpty || !matches.isEmpty { comment = [] }
        }
        return result
    }

    private static func splitArguments(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var depth = 0
        for ch in raw {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "(" || ch == "[" {
                depth += 1; current.append(ch)
            } else if ch == ")" || ch == "]" {
                depth -= 1; current.append(ch)
            } else if ch == "," && depth == 0 {
                args.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else {
                current.append(ch)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { args.append(last) }
        return args
    }

    /// The first line of the module docstring, which usually says what the fix is for.
    static func docstring(_ script: String) -> String? {
        guard let start = script.range(of: "\"\"\"") else { return nil }
        let rest = script[start.upperBound...]
        guard let firstLine = rest.split(separator: "\n").first else { return nil }
        let text = firstLine.replacingOccurrences(of: "\"\"\"", with: "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

/// Pulls Wine-relevant settings out of a Lutris installer script.
enum LutrisTranslator {
    private static let allowedEnvironmentPrefixes = ["WINE", "MVK_", "MTL_"]

    static func translate(_ script: [String: Any], slug: String, knownVerbs: Set<String>) -> [CompatSuggestion] {
        let source = CompatSource.lutris(slug: slug)
        var suggestions: [CompatSuggestion] = []
        let modes: [String: DLLOverrideMode] = ["n,b": .nativeThenBuiltin, "b,n": .builtinThenNative, "n": .native, "native": .native,
                                                 "b": .builtin, "builtin": .builtin, "": .disabled, "disabled": .disabled, "native,builtin": .nativeThenBuiltin]

        if let wine = script["wine"] as? [String: Any], let overrides = wine["overrides"] as? [String: Any] {
            for (dll, value) in overrides.sorted(by: { $0.key < $1.key }) {
                guard let mode = modes[String(describing: value).lowercased().replacingOccurrences(of: " ", with: "")] else { continue }
                suggestions.append(CompatSuggestion(action: .dllOverride(name: dll, mode: mode), reason: "Lutris installer overrides \(dll).", source: source, recommended: true))
            }
        }
        if let system = script["system"] as? [String: Any], let env = system["env"] as? [String: Any] {
            for (key, value) in env.sorted(by: { $0.key < $1.key }) where allowedEnvironmentPrefixes.contains(where: key.hasPrefix) {
                suggestions.append(CompatSuggestion(action: .environment(key: key, value: String(describing: value)), reason: "Lutris installer sets \(key).", source: source, recommended: false))
            }
        }
        for step in script["installer"] as? [[String: Any]] ?? [] {
            guard let task = step["task"] as? [String: Any], task["name"] as? String == "winetricks", let apps = task["app"] as? String else { continue }
            for verb in apps.split(separator: " ").map(String.init) where !verb.hasPrefix("dxvk") && (knownVerbs.isEmpty || knownVerbs.contains(verb)) {
                if let version = WindowsVersion(rawValue: verb) {
                    suggestions.append(CompatSuggestion(action: .windowsVersion(version), reason: "Lutris installer sets \(verb).", source: source, recommended: true))
                } else {
                    suggestions.append(CompatSuggestion(action: .winetricks(verb), reason: "Lutris installer installs \(verb).", source: source, recommended: true))
                }
            }
        }
        return suggestions
    }
}
