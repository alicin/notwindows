import Foundation

/// What a game's last log says went wrong, and the fixes that follow from it.
struct RunDiagnosis: Equatable {
    var suggestions: [CompatSuggestion] = []
    var notes: [CompatNote] = []

    var isEmpty: Bool { suggestions.isEmpty && notes.isEmpty }
}

/// Reads Wine's log for the errors that point at a fix: missing DLLs, unimplemented functions, display modes the Mac
/// doesn't have, Steam refusing to start the game, crashes and the game's own error messages.
enum LogDiagnostics {
    /// What the log needs to contain for this to work, at the "Quiet" level and up.
    static let channels = "err+module,err+macdrv,err+mscoree,trace+msgbox"

    static func diagnose(_ log: String, game: Game, displaySizes: [CGSize] = []) -> RunDiagnosis {
        var diagnosis = RunDiagnosis()
        func suggest(_ action: CompatAction, _ reason: String, recommended: Bool = true) {
            guard !diagnosis.suggestions.contains(where: { $0.action == action }) else { return }
            diagnosis.suggestions.append(CompatSuggestion(action: action, reason: reason, source: .lastRun, recommended: recommended))
        }
        func note(_ text: String) {
            guard !diagnosis.notes.contains(where: { $0.text == text }) else { return }
            diagnosis.notes.append(CompatNote(text: text, source: .lastRun, kind: .info))
        }
        func missingDLL(_ dll: String, neededBy program: String, detail: String) {
            let lower = dll.lowercased()
            if let (verb, _) = MacRules.verb(forDLL: lower) {
                suggest(.winetricks(verb), "\(detail) \(verb) installs it.")
            } else if lower == "mscoree.dll" {
                if game.settings.skipMono { suggest(.keepMono, "\(detail) It's part of Wine Mono, which is turned off for this game.") }
            } else if lower.hasPrefix("steam_api") {
                note("\(dll), Steam's library that \(program) loads, is missing next to it. Steam installs it with the game; verify the game's files in Steam.")
            } else {
                note("\(detail) It usually comes with the game or a redistributable in its folder.")
            }
        }

        var messages = 0
        for raw in log.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let m = line.firstMatch(of: #/err:module:import_dll Library (\S+) \(which is needed by L?"?(.+?)"?\) not found/#) {
                let program = Self.fileName(String(m.2))
                missingDLL(String(m.1), neededBy: program, detail: "\(program) couldn't start because \(m.1) is missing.")
            } else if let m = line.firstMatch(of: #/err:module:import_dll Loading library (\S+) \(which is needed by L?"?(.+?)"?\) failed \(error (\w+)\)/#) {
                let program = Self.fileName(String(m.2))
                note(m.3.lowercased() == "c000007b"
                     ? "\(m.1) is built for the other architecture (32 or 64-bit) than \(program), so it couldn't load. A copy in the game's folder may be the wrong one."
                     : "\(m.1), which \(program) needs, failed to load (error \(m.3)).")
            } else if let m = line.firstMatch(of: #/(?:to unimplemented function|Unimplemented function) ([\w-]+\.dll)\.(\S+?)(?:,| called|$)/#) {
                missingDLL(String(m.1), neededBy: "The game", detail: "The game called \(m.2) in \(m.1), which Wine's built-in copy doesn't have.")
            } else if let m = line.firstMatch(of: #/err:macdrv:macdrv_ChangeDisplaySettings(?:Ex)?:? No matching mode found (\d+)x(\d+)x(\d+)/#) {
                let sizes = displaySizes.prefix(5).map { "\(Int($0.width))x\(Int($0.height))" }
                let offer = sizes.isEmpty ? "Set the game to a resolution the display offers"
                    : "Set the game to the display's own size, \(sizes[0])" + (sizes.count > 1 ? ", or another it offers: \(sizes.dropFirst().joined(separator: ", "))" : "")
                note("The game asked for a \(m.1)x\(m.2) display mode, which this Mac's display doesn't offer, so it may not go full screen or report a DirectX error. \(offer). Smart Setup does this for games it knows.")
            } else if let m = line.firstMatch(of: #/\[S_API FAIL\] SteamAPI_Init\(\) failed; (.+)/#) {
                let reason = String(m.1).trimmingCharacters(in: .whitespaces)
                note(game.isSteamGame
                     ? "Steamworks couldn't reach Steam (\(reason)). notwindows waits for Steam to sign in; if this keeps happening, start Steam from the library before the game."
                     : "The game needs Steam (\(reason)). Install the Windows Steam client in the library and the game through it; Steam games show up on their own.")
            } else if let m = line.firstMatch(of: #/trace:msgbox:\w+ L"(.*)"$/#) {
                let text = String(m.1).replacingOccurrences(of: #"\n"#, with: " ").replacingOccurrences(of: #"\t"#, with: " ")
                    .replacingOccurrences(of: #"\""#, with: "\"").trimmingCharacters(in: .whitespaces)
                if text.localizedCaseInsensitiveContains("Application load error") {
                    note("Steam's DRM refused to start the game (“\(text)”). It needs the Windows Steam client running and signed in, in the same prefix"
                         + (game.isSteamGame ? "; notwindows waits for that, so check Steam is signed in." : "."))
                } else if text.range(of: #"\bAVX"#, options: .regularExpression) != nil, !game.settings.advertiseAVX {
                    suggest(.advertiseAVX(true), "The game said: “\(text)”")
                } else if messages < 3, !text.isEmpty {
                    messages += 1
                    note("The game showed an error: “\(text.count > 220 ? String(text.prefix(220)) + "…" : text)”")
                }
            } else if let m = line.firstMatch(of: #/^wine: Unhandled (.+?)(?: on (?:read|write|execute) access to \S+)? at address (\S+)/#) {
                let kind = String(m.1)
                if kind.hasPrefix("illegal instruction"), !game.settings.advertiseAVX {
                    suggest(.advertiseAVX(true), "The game crashed on an instruction Rosetta 2 wasn't told it could run; it may need AVX.")
                } else {
                    note("The game crashed: \(kind) at \(m.2).")
                }
            } else if line.contains("Wine Mono is not installed") || line.contains("err:mscoree") && line.localizedCaseInsensitiveContains("mono") {
                if game.settings.skipMono {
                    suggest(.keepMono, "The game needs .NET, and Wine Mono is turned off for it.")
                } else {
                    suggest(.winetricks("dotnet48"), "The game needs .NET, and Wine Mono wasn't enough.", recommended: false)
                }
            } else if line.contains("Failed to create Vulkan instance") || line.contains("DXVK: No adapters found") {
                if game.settings.direct3DBackend == .dxvk { suggest(.renderer(.dxmt), "Vulkan didn't start for DXVK. DXMT draws through Metal directly.") }
                if game.settings.direct3D9Backend == .d9vk { suggest(.direct3D9(.wined3d), "Vulkan didn't start for D9VK. WineD3D draws through OpenGL instead.", recommended: false) }
            }
        }
        return diagnosis
    }

    /// The executable's file name from a Windows path in a log line.
    static func fileName(_ path: String) -> String {
        path.replacingOccurrences(of: #"\\"#, with: "\\").split(separator: "\\").last.map(String.init) ?? path
    }

    /// The start and end of a long log, where load failures and crashes show up.
    static func readLog(_ url: URL, limit: Int = 4 << 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        guard size > UInt64(limit) else { return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) } }
        let head = (try? handle.read(upToCount: limit / 2)) ?? Data()
        try? handle.seek(toOffset: size - UInt64(limit / 2))
        let tail = (try? handle.readToEnd()) ?? Data()
        return String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
    }
}
