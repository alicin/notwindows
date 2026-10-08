import Foundation

enum Paths {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["NOTWINDOWS_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("notwindows", isDirectory: true)
    }

    static var games: URL { root.appendingPathComponent("Games", isDirectory: true) }
    static var engines: URL { root.appendingPathComponent("Engines", isDirectory: true) }
    static var runtime: URL { root.appendingPathComponent("Runtime", isDirectory: true) }
    static var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    static var tools: URL { root.appendingPathComponent("Tools", isDirectory: true) }

    /// Engines downloaded by the original Sikarugir Creator, offered for import.
    static var sikarugirEngines: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sikarugir/Engines", isDirectory: true)
    }

    static func ensureDirectories() {
        for url in [root, games, engines, runtime, downloads, tools] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

extension URL {
    var exists: Bool { FileManager.default.fileExists(atPath: path) }

    var isDirectoryURL: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
