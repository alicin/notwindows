import Foundation

/// An .ini file edited in place. Its encoding, byte order mark, line endings and every line that isn't changed stay
/// exactly as they were, since games are picky about all of them.
struct IniFile {
    private(set) var lines: [String]
    let encoding: String.Encoding
    let byteOrderMark: Data
    let lineEnding: String
    let endsWithLineBreak: Bool

    init?(data: Data) {
        let boms: [(Data, String.Encoding)] = [(Data([0xEF, 0xBB, 0xBF]), .utf8), (Data([0xFF, 0xFE]), .utf16LittleEndian),
                                               (Data([0xFE, 0xFF]), .utf16BigEndian)]
        var text: String?
        var encoding = String.Encoding.utf8
        var bom = Data()
        if let (mark, markEncoding) = boms.first(where: { data.starts(with: $0.0) }) {
            bom = mark
            encoding = markEncoding
            text = String(data: data.dropFirst(mark.count), encoding: markEncoding)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            // Windows games write their code page, usually Windows-1252; Latin-1 reads and writes every byte back as is.
            encoding = .isoLatin1
            text = String(data: data, encoding: .isoLatin1)
        }
        guard let text else { return nil }
        self.encoding = encoding
        byteOrderMark = bom
        lineEnding = text.contains("\r\n") ? "\r\n" : "\n"
        // "\r\n" is a single Character in Swift, so look at the last scalar.
        endsWithLineBreak = text.unicodeScalars.last == "\n"
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if endsWithLineBreak { lines.removeLast() }
        self.lines = lines
    }

    var data: Data? {
        let text = lines.joined(separator: lineEnding) + (endsWithLineBreak ? lineEnding : "")
        return text.data(using: encoding).map { byteOrderMark + $0 }
    }

    func value(section: String, key: String) -> String? {
        var current: String?
        var found: String?
        for line in lines {
            if let name = Self.sectionName(line) { current = name; continue }
            guard let current, current.caseInsensitiveCompare(section) == .orderedSame,
                  let pair = Self.keyValue(line), pair.key.caseInsensitiveCompare(key) == .orderedSame else { continue }
            // Like the games, the last occurrence wins.
            found = pair.value
        }
        return found
    }

    /// Sets every occurrence of the key in the section, adding the key (and the section) when missing. Returns
    /// whether anything changed.
    @discardableResult
    mutating func set(section: String, key: String, value: String) -> Bool {
        var inSection = false, inFirstSection = false
        var changed = false, found = false
        var insertAt: Int?
        for index in lines.indices {
            let line = lines[index]
            if let name = Self.sectionName(line) {
                inSection = name.caseInsensitiveCompare(section) == .orderedSame
                inFirstSection = inSection && insertAt == nil
                if inFirstSection { insertAt = index + 1 }
                continue
            }
            guard inSection else { continue }
            // New keys go after the first matching section's last line, ahead of the blank lines before the next one.
            if inFirstSection, !line.trimmingCharacters(in: .whitespaces).isEmpty { insertAt = index + 1 }
            guard let pair = Self.keyValue(line), pair.key.caseInsensitiveCompare(key) == .orderedSame,
                  let equals = line.firstIndex(of: "=") else { continue }
            found = true
            let spacing = line[line.index(after: equals)...].prefix { $0 == " " || $0 == "\t" }
            let replaced = String(line[...equals]) + spacing + value
            if replaced != line {
                lines[index] = replaced
                changed = true
            }
        }
        guard !found else { return changed }
        if let insertAt {
            lines.insert("\(key)=\(value)", at: insertAt)
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
            lines += ["[\(section)]", "\(key)=\(value)"]
        }
        return true
    }

    private static func sectionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).trimmingCharacters(in: .whitespaces)
    }

    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(";"), !trimmed.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
        return (line[..<equals].trimmingCharacters(in: .whitespaces), line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
    }
}

enum IniEditor {
    static let backupSuffix = ".notwindows-backup"

    /// Writes values into an existing file, keeping a backup of the original the first time and its permissions,
    /// including read-only ones. Returns false when the file doesn't exist yet.
    static func apply(_ values: [(section: String, key: String, value: String)], to url: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        guard var ini = IniFile(data: try Data(contentsOf: url)) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't a text file."])
        }
        var changed = false
        for item in values where ini.set(section: item.section, key: item.key, value: item.value) { changed = true }
        guard changed else { return true }
        guard let data = ini.data else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: "A new value can't be written in \(url.lastPathComponent)'s encoding."])
        }
        let backup = URL(fileURLWithPath: url.path + backupSuffix)
        if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
        let permissions = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        // Bethesda ship some .ini files read-only so their launchers can't overwrite them; keep it that way.
        if permissions & 0o200 == 0 { try fm.setAttributes([.posixPermissions: permissions | 0o200], ofItemAtPath: url.path) }
        defer { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        try data.write(to: url, options: .atomic)
        return true
    }

    static func value(in url: URL, section: String, key: String) -> String? {
        guard let data = try? Data(contentsOf: url), let ini = IniFile(data: data) else { return nil }
        return ini.value(section: section, key: key)
    }
}
