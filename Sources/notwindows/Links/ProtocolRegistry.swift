import Foundation

/// A URL scheme a Windows program registered inside a prefix, e.g. `jagex://` or `com.epicgames.launcher://`.
struct RegisteredProtocol: Hashable {
    let scheme: String
    let description: String?
    let command: String

    /// The registered command with the link filled in, ready to pass to Wine as program + arguments.
    func arguments(for link: String) -> [String] {
        var substituted = false
        let parts = CommandLineSplitter.split(command).map { part -> String in
            guard part.contains("%1") || part.contains("%L") || part.contains("%l") else { return part }
            substituted = true
            return part.replacingOccurrences(of: "%1", with: link).replacingOccurrences(of: "%L", with: link).replacingOccurrences(of: "%l", with: link)
        }
        .filter { $0 != "%*" }
        return substituted ? parts : parts + [link]
    }

    /// The program from the command line, e.g. "MicrobotLauncher.exe".
    var programName: String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let path: Substring
        if trimmed.hasPrefix("\"") {
            path = trimmed.dropFirst().prefix { $0 != "\"" }
        } else {
            path = trimmed.prefix { $0 != " " }
        }
        return path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
    }
}

enum ProtocolRegistry {
    /// Schemes macOS or Wine itself owns; never forwarded into a prefix.
    static let reservedSchemes: Set<String> = [
        "http", "https", "ftp", "ftps", "file", "mailto", "news", "nntp", "telnet", "gopher", "ldap", "tel", "sms", "data",
        "about", "javascript", "vbscript", "res", "its", "mk", "ms-its", "ms-settings", "shell", "irc", "callto", "ws", "wss",
        "notwindows", "facetime", "itms", "itms-apps", "macappstore", "x-apple", "webcal", "feed",
    ]

    /// Wine's own handlers, which just bounce links back to macOS.
    private static let builtinHandlers = ["winebrowser", "iexplore.exe", "explorer.exe", "rundll32.exe", "start.exe"]

    static func protocols(inPrefix prefix: URL) -> [RegisteredProtocol] {
        var found: [String: RegisteredProtocol] = [:]
        // user.reg (HKCU\Software\Classes) wins over system.reg (HKLM\Software\Classes), as on Windows.
        for file in ["system.reg", "user.reg"] {
            guard let text = try? String(contentsOf: prefix.appendingPathComponent(file), encoding: .utf8) else { continue }
            for proto in parse(text) { found[proto.scheme] = proto }
        }
        return found.values.sorted { $0.scheme < $1.scheme }
    }

    /// Finds `Software\Classes\<scheme>` keys marked with "URL Protocol" that have a shell\open\command.
    static func parse(_ registry: String) -> [RegisteredProtocol] {
        var urlProtocols = Set<String>()
        var descriptions: [String: String] = [:]
        var commands: [String: String] = [:]
        var currentKey: String?
        var currentScheme: String?
        var isCommandKey = false

        for rawLine in registry.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                currentKey = nil; currentScheme = nil; isCommandKey = false
                guard let end = line.firstIndex(of: "]") else { continue }
                let key = String(line[line.index(after: line.startIndex)..<end]).replacingOccurrences(of: "\\\\", with: "\\")
                let lowered = key.lowercased()
                guard lowered.hasPrefix("software\\classes\\") else { continue }
                let parts = key.split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { continue }
                let scheme = parts[2].lowercased()
                guard isValidScheme(scheme) else { continue }
                currentKey = key
                currentScheme = scheme
                isCommandKey = parts.count == 6 && parts[3].lowercased() == "shell" && parts[4].lowercased() == "open" && parts[5].lowercased() == "command"
                if parts.count != 3 && !isCommandKey { currentScheme = nil }
                continue
            }
            guard currentKey != nil, let scheme = currentScheme else { continue }
            if isCommandKey, line.hasPrefix("@=") {
                commands[scheme] = unquote(String(line.dropFirst(2)))
            } else if !isCommandKey {
                if line.hasPrefix("\"URL Protocol\"=") {
                    urlProtocols.insert(scheme)
                } else if line.hasPrefix("@=") {
                    descriptions[scheme] = unquote(String(line.dropFirst(2)))
                }
            }
        }

        return urlProtocols.compactMap { scheme -> RegisteredProtocol? in
            guard let command = commands[scheme], !reservedSchemes.contains(scheme) else { return nil }
            let lowered = command.lowercased()
            guard !builtinHandlers.contains(where: lowered.contains) else { return nil }
            return RegisteredProtocol(scheme: scheme, description: descriptions[scheme], command: command)
        }
        .sorted { $0.scheme < $1.scheme }
    }

    static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first, CharacterSet.letters.contains(first) else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        return scheme.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII }
    }

    /// Decodes a REGEDIT string value: `"\"C:\\x.exe\" \"%1\""` → `"C:\x.exe" "%1"`.
    private static func unquote(_ value: String) -> String {
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        var result = ""
        var escaping = false
        for ch in value.dropFirst().dropLast() {
            if escaping { result.append(ch); escaping = false }
            else if ch == "\\" { escaping = true }
            else { result.append(ch) }
        }
        return result
    }
}
