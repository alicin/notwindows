import Foundation

/// The Windows Steam client's appinfo.vdf cache: what Steam knows about every app it has seen, including the launch
/// options and install script it uses, in binary KeyValues.
enum SteamAppInfo {
    struct LaunchOption: Equatable {
        /// Relative to the install folder, with Windows separators.
        let executable: String
        let arguments: String
        let description: String?
        /// Set for options that only apply to a beta branch.
        let betaKey: String?
        let osList: String?

        var isForWindows: Bool { osList.map { $0.isEmpty || $0.lowercased().contains("windows") } ?? true }
    }

    static func file(inPrefix prefix: URL) -> URL? {
        SteamLibraryScanner.steamRoot(in: prefix).map { $0.appendingPathComponent("appcache/appinfo.vdf") }.flatMap { $0.exists ? $0 : nil }
    }

    /// The default launch options, in Steam's order, for Windows and the default branch.
    static func launchOptions(_ app: VDF.Value) -> [LaunchOption] {
        (app["config"]?["launch"]?.pairs ?? []).compactMap { _, entry in
            guard let executable = entry["executable"]?.string, !executable.isEmpty else { return nil }
            let option = LaunchOption(executable: executable, arguments: entry["arguments"]?.string ?? "",
                                      description: entry["description"]?.string, betaKey: entry["config"]?["betakey"]?.string,
                                      osList: entry["config"]?["oslist"]?.string)
            return option.isForWindows && option.betaKey == nil ? option : nil
        }
    }

    /// Where the install script lives, relative to the install folder.
    static func installScript(_ app: VDF.Value) -> String? { app["extended"]?["installscript"]?.string }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (modified: Date, apps: [Int: VDF.Value])] = [:]

    /// The `appinfo` sections of the requested apps, as Steam last downloaded them.
    static func apps(_ ids: Set<Int>, in file: URL) -> [Int: VDF.Value] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
        lock.lock()
        let cached = cache[file.path].flatMap { $0.modified == modified ? $0.apps : nil } ?? [:]
        lock.unlock()
        let missing = ids.subtracting(cached.keys)
        guard !missing.isEmpty else { return cached.filter { ids.contains($0.key) } }
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return [:] }
        let found = parse(data, ids: missing).merging(cached) { new, _ in new }
        lock.lock()
        cache[file.path] = (modified, found)
        lock.unlock()
        return found.filter { ids.contains($0.key) }
    }

    /// Parses the apps in `ids` out of appinfo.vdf. Format 27 has one SHA-1 per entry, 28 a second one for the binary
    /// data, and 29 moves every key name into a string table at the end of the file.
    static func parse(_ data: Data, ids: Set<Int>) -> [Int: VDF.Value] {
        var reader = BinaryReader(data: data)
        guard let magic = reader.u32(), [0x0756_4427, 0x0756_4428, 0x0756_4429].contains(magic), reader.u32() != nil else { return [:] }
        var strings: [String]?
        if magic == 0x0756_4429 {
            guard let offset = reader.u64() else { return [:] }
            var table = BinaryReader(data: data, offset: Int(offset))
            guard let count = table.u32() else { return [:] }
            var names: [String] = []
            names.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let name = table.cString() else { return [:] }
                names.append(name)
            }
            strings = names
        }
        let headerSize = magic >= 0x0756_4428 ? 60 : 40
        var apps: [Int: VDF.Value] = [:]
        while apps.count < ids.count, let appID = reader.u32(), appID != 0, let size = reader.u32() {
            let end = reader.offset + Int(size)
            if ids.contains(Int(appID)) {
                var entry = BinaryReader(data: data, offset: reader.offset + headerSize, end: end)
                if let pairs = entry.object(strings: strings) {
                    apps[Int(appID)] = VDF.Value.object(pairs)["appinfo"] ?? .object(pairs)
                }
            }
            reader.offset = end
        }
        return apps
    }

    private struct BinaryReader {
        let data: Data
        var offset: Int
        var end: Int

        init(data: Data, offset: Int = 0, end: Int? = nil) {
            self.data = data
            self.offset = offset
            self.end = min(end ?? data.count, data.count)
        }

        mutating func bytes(_ count: Int) -> Data? {
            guard offset >= 0, count >= 0, offset + count <= end else { return nil }
            defer { offset += count }
            return data[(data.startIndex + offset)..<(data.startIndex + offset + count)]
        }

        mutating func u8() -> UInt8? { bytes(1)?.first }
        mutating func u32() -> UInt32? { bytes(4).map { $0.reversed().reduce(0) { $0 << 8 | UInt32($1) } } }
        mutating func u64() -> UInt64? { bytes(8).map { $0.reversed().reduce(0) { $0 << 8 | UInt64($1) } } }

        mutating func cString() -> String? {
            guard offset < end, let zero = data[(data.startIndex + offset)..<(data.startIndex + end)].firstIndex(of: 0) else { return nil }
            let text = String(decoding: data[(data.startIndex + offset)..<zero], as: UTF8.self)
            offset = zero - data.startIndex + 1
            return text
        }

        mutating func key(strings: [String]?) -> String? {
            guard let strings else { return cString() }
            guard let index = u32(), Int(index) < strings.count else { return nil }
            return strings[Int(index)]
        }

        /// Binary KeyValues: a type byte, a key, a value; type 8 (or 11) closes the object.
        mutating func object(strings: [String]?) -> [(key: String, value: VDF.Value)]? {
            var pairs: [(key: String, value: VDF.Value)] = []
            while let type = u8() {
                if type == 0x08 || type == 0x0B { return pairs }
                guard let key = key(strings: strings) else { return nil }
                switch type {
                case 0x00:
                    guard let child = object(strings: strings) else { return nil }
                    pairs.append((key, .object(child)))
                case 0x01:
                    guard let text = cString() else { return nil }
                    pairs.append((key, .string(text)))
                case 0x02, 0x04, 0x06:
                    guard let value = u32() else { return nil }
                    pairs.append((key, .string(String(Int32(bitPattern: value)))))
                case 0x03:
                    guard let value = u32() else { return nil }
                    pairs.append((key, .string(String(Float(bitPattern: value)))))
                case 0x07:
                    guard let value = u64() else { return nil }
                    pairs.append((key, .string(String(value))))
                case 0x0A:
                    guard let value = u64() else { return nil }
                    pairs.append((key, .string(String(Int64(bitPattern: value)))))
                default:
                    return nil
                }
            }
            return pairs
        }
    }
}
