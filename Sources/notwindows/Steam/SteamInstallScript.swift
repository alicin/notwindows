import Foundation

/// What Steam does the first time it starts a game: write the registry keys from the game's installscript.vdf (e.g.
/// Bethesda's "installed path", which their launchers check) and run its redistributables. Launching the executable
/// directly skips that, so notwindows applies the script itself, the way Steam would.
struct SteamInstallScript {
    struct Process {
        /// The value Steam sets under `hasRunKey` once this entry has run.
        let name: String
        let hasRunKey: String
        let commands: [(executable: String, arguments: String)]
    }

    /// A .reg document with the script's registry section, or "" when it has none.
    let registryDocument: String
    let processes: [Process]

    static func find(in installDirectory: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: installDirectory.path)) ?? []
        return names.first { $0.lowercased() == "installscript.vdf" }.map { installDirectory.appendingPathComponent($0) }
    }

    /// - Parameters:
    ///   - installDirectory: the game folder as a Mac path, substituted for %INSTALLDIR% in programs to run.
    ///   - windowsInstallDirectory: the same folder as Windows sees it, substituted in registry values.
    ///   - wow64: whether the prefix is 64-bit. Steam is a 32-bit program, so its HKLM\Software writes land in the
    ///     32-bit view (Wow6432Node), and that's where 32-bit games look.
    init(_ text: String, installDirectory: URL, windowsInstallDirectory: String, wow64: Bool) {
        let script = VDF.parse(text)["installscript"]
        func registryKey(_ path: String) -> String {
            var parts = path.split(separator: "\\").map(String.init)
            guard let hive = parts.first else { return path }
            switch hive.lowercased() {
            case "hkey_local_machine", "hklm": parts[0] = "HKEY_LOCAL_MACHINE"
            case "hkey_current_user", "hkcu": parts[0] = "HKEY_CURRENT_USER"
            default: break
            }
            if wow64, parts[0] == "HKEY_LOCAL_MACHINE", parts.count > 1, parts[1].lowercased() == "software",
               parts.count < 3 || parts[2].lowercased() != "wow6432node" {
                parts.insert("Wow6432Node", at: 2)
            }
            return parts.joined(separator: "\\")
        }
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }

        var lines: [String] = []
        for (path, types) in script?["registry"]?.pairs ?? [] {
            var values: [String] = []
            for (type, entries) in types.pairs {
                for (name, value) in entries.pairs {
                    guard let raw = value.string else { continue }
                    let text = raw.replacingOccurrences(of: "%INSTALLDIR%", with: windowsInstallDirectory, options: .caseInsensitive)
                    switch type.lowercased() {
                    case "dword":
                        if let number = UInt32(text) { values.append("\"\(escaped(name))\"=dword:\(String(format: "%08x", number))") }
                    case "string":
                        values.append("\"\(escaped(name))\"=\"\(escaped(text))\"")
                    default:
                        continue
                    }
                }
            }
            if !values.isEmpty { lines += ["", "[\(registryKey(path))]"] + values }
        }
        registryDocument = lines.isEmpty ? "" : (["Windows Registry Editor Version 5.00"] + lines + [""]).joined(separator: "\n")

        processes = (script?["run process"]?.pairs ?? []).compactMap { name, entry in
            guard let hasRunKey = entry["hasrunkey"]?.string else { return nil }
            var commands: [(String, String)] = []
            for index in 1... {
                guard let program = entry["process \(index)"]?.string else { break }
                let path = program.replacingOccurrences(of: "%INSTALLDIR%", with: installDirectory.path, options: .caseInsensitive)
                    .replacingOccurrences(of: "\\", with: "/")
                // Other placeholders (%STEAMPATH%, …) point outside the game folder; leave those to Steam.
                guard !path.contains("%") else { continue }
                commands.append((path, entry["command \(index)"]?.string ?? ""))
            }
            return commands.isEmpty ? nil : Process(name: name, hasRunKey: registryKey(hasRunKey), commands: commands)
        }
    }

    /// Marks a process entry as done, so neither Steam nor notwindows runs it again.
    static func doneDocument(for process: Process) -> String {
        "Windows Registry Editor Version 5.00\n\n[\(process.hasRunKey)]\n\"\(process.name)\"=dword:00000001\n"
    }
}
