import Foundation

/// Finds likely game executables inside a prefix after an installer has run.
enum ExecutableScanner {
    struct Candidate: Identifiable, Hashable {
        let url: URL
        let size: Int64
        let score: Int
        var id: URL { url }
    }

    private static let skippedDirectories: Set<String> = ["windows", "temp", "cache", "_commonredist", "redist", "redistributables", "directx", "vcredist", "dotnet", "__installer", "support"]
    private static let noisyNames = ["unins", "setup", "install", "redist", "vcredist", "dxsetup", "crash", "report", "helper", "updater", "update", "launcherpatcher", "cefprocess", "webhelper", "dotnet", "uploader", "benchmark", "touchup", "cleanup", "easyanticheat_setup", "ue4prereq", "prereq"]

    static func scan(_ driveC: URL, limit: Int = 40) -> [Candidate] {
        guard let enumerator = FileManager.default.enumerator(
            at: driveC,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [Candidate] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey])
            let name = url.lastPathComponent.lowercased()
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                if skippedDirectories.contains(name) || (name == "microsoft" && url.path.contains("/ProgramData/")) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let size = Int64(values?.fileSize ?? 0)
            results.append(Candidate(url: url, size: size, score: score(url, name: name, size: size)))
        }
        return results
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.size > $1.size }
            .prefix(limit)
            .map { $0 }
    }

    private static func score(_ url: URL, name: String, size: Int64) -> Int {
        var score = 0
        if noisyNames.contains(where: name.contains) { score -= 50 }
        if url.path.contains("/Program Files") { score += 10 }
        if url.path.contains("/users/") { score -= 5 }
        if size > 20_000_000 { score += 15 } else if size > 2_000_000 { score += 5 }
        if name.contains("launcher") { score += 3 }
        if name.hasSuffix("-win64-shipping.exe") || name.hasSuffix("_x64.exe") || name.hasSuffix("64.exe") { score += 8 }
        let folder = url.deletingLastPathComponent().lastPathComponent.lowercased()
        let stem = (name as NSString).deletingPathExtension
        if folder.replacingOccurrences(of: " ", with: "").contains(stem.replacingOccurrences(of: " ", with: "")) { score += 6 }
        return score
    }
}
