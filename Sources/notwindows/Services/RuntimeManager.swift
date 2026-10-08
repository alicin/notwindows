import Foundation
import Observation

/// Installs the graphics/media runtime that Sikarugir ships inside its wrapper template, once, for all games.
@MainActor
@Observable
final class RuntimeManager {
    private(set) var current: Runtime?
    private(set) var latestName: String?
    private(set) var progress: Double?
    private(set) var status: String?

    private static let repository = "Sikarugir-App/Template"
    private static let winetricksURL = URL(string: "https://raw.githubusercontent.com/Sikarugir-App/winetricks/HEAD/src/winetricks")!

    init() { reload() }

    var isUpdateAvailable: Bool {
        guard let latestName, let current else { return false }
        return latestName.localizedStandardCompare(current.name) == .orderedDescending
    }

    var isRosettaInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta")
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.runtime.path)) ?? []
        current = names
            .filter { $0.hasPrefix("Template-") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .lazy
            .map { Runtime(name: $0, directory: Paths.runtime.appendingPathComponent($0, isDirectory: true)) }
            .first(where: \.isValid)
    }

    func checkForUpdate() async {
        let text = try? await Downloader.string(URL(string: "https://raw.githubusercontent.com/\(Self.repository)/HEAD/NewestVersion.txt")!)
        let name = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, name.hasPrefix("Template-") { latestName = name }
    }

    func installLatest() async throws {
        if latestName == nil { await checkForUpdate() }
        guard let name = latestName else {
            throw URLError(.cannotFindHost, userInfo: [NSLocalizedDescriptionKey: "Couldn't find the latest Sikarugir runtime."])
        }
        try await install(name: name)
    }

    func install(name: String) async throws {
        progress = 0
        status = "Downloading \(name)…"
        defer { progress = nil; status = nil }

        let url = URL(string: "https://github.com/\(Self.repository)/releases/download/v1.0/\(name).tar.xz")!
        let archive = try await Downloader.download(url) { value in
            Task { @MainActor in self.progress = value * 0.85 }
        }
        defer { try? FileManager.default.removeItem(at: archive) }

        status = "Unpacking…"
        progress = 0.9
        let staging = Paths.runtime.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Downloader.extract(archive, into: staging, members: [
            "*/Contents/Frameworks",
            "*/Contents/Resources/vulkan",
            "*/Contents/Configure.app/Contents/Resources/cabextract",
        ])

        guard let app = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "The runtime archive has an unexpected layout."])
        }
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let tools = contents.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let cabextract = contents.appendingPathComponent("Configure.app/Contents/Resources/cabextract")
        if cabextract.exists { try FileManager.default.moveItem(at: cabextract, to: tools.appendingPathComponent("cabextract")) }
        try? FileManager.default.removeItem(at: contents.appendingPathComponent("Configure.app"))

        let destination = Paths.runtime.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: contents, to: destination.appendingPathComponent("Contents"))

        let previous = current
        reload()
        if let previous, previous.name != name { try? FileManager.default.removeItem(at: previous.directory) }
    }

    /// Fetches Sikarugir's winetricks fork on first use.
    func winetricksScript() async throws -> URL {
        let url = Paths.tools.appendingPathComponent("winetricks")
        if url.exists { return url }
        let (data, _) = try await URLSession.shared.data(from: Self.winetricksURL)
        try FileManager.default.createDirectory(at: Paths.tools, withIntermediateDirectories: true)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func refreshWinetricks() async throws {
        try? FileManager.default.removeItem(at: Paths.tools.appendingPathComponent("winetricks"))
        _ = try await winetricksScript()
    }
}
