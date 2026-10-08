import Foundation
import Observation

struct EngineCatalogItem: Identifiable, Hashable {
    let name: String
    let url: URL
    let size: Int64
    let isRecommended: Bool
    var id: String { name }
    var displayName: String { Engine.displayName(for: name) }
}

@MainActor
@Observable
final class EngineManager {
    private(set) var installed: [Engine] = []
    private(set) var catalog: [EngineCatalogItem] = []
    private(set) var localArchives: [URL] = []
    private(set) var progress: [String: Double] = [:]
    private(set) var isRefreshingCatalog = false
    var catalogError: String?

    var defaultEngineName: String? {
        didSet { UserDefaults.standard.set(defaultEngineName, forKey: "defaultEngine") }
    }

    private static let repository = "Sikarugir-App/Engines"

    init() {
        defaultEngineName = UserDefaults.standard.string(forKey: "defaultEngine")
        reload()
    }

    var defaultEngine: Engine? {
        installed.first { $0.name == defaultEngineName } ?? installed.first
    }

    func engine(named name: String?) -> Engine? {
        guard let name else { return defaultEngine }
        return installed.first { $0.name == name }
    }

    func isInstalled(_ name: String) -> Bool { installed.contains { $0.name == name } }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.engines.path)) ?? []
        installed = names
            .map { Engine(name: $0, directory: Paths.engines.appendingPathComponent($0, isDirectory: true)) }
            .filter(\.isValid)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        if defaultEngineName == nil || !installed.contains(where: { $0.name == defaultEngineName }) {
            defaultEngineName = installed.first?.name
        }
        let local = (try? FileManager.default.contentsOfDirectory(at: Paths.sikarugirEngines, includingPropertiesForKeys: nil)) ?? []
        localArchives = local
            .filter { $0.lastPathComponent.hasSuffix(".tar.xz") && !isInstalled(Self.engineName(forArchive: $0)) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
    }

    func refreshCatalog() async {
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        do {
            struct Release: Decodable { let assets: [Asset] }
            struct Asset: Decodable { let name: String; let size: Int64; let browser_download_url: URL }

            let releases = try await Downloader.json([Release].self, from: URL(string: "https://api.github.com/repos/\(Self.repository)/releases?per_page=20")!)
            let recommendedText = (try? await Downloader.string(URL(string: "https://raw.githubusercontent.com/\(Self.repository)/HEAD/EngineList.txt")!)) ?? ""
            let recommended = Set(recommendedText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })

            var seen = Set<String>()
            catalog = releases.flatMap(\.assets)
                .filter { $0.name.hasSuffix(".tar.xz") }
                .compactMap { asset in
                    let name = String(asset.name.dropLast(".tar.xz".count))
                    guard seen.insert(name).inserted else { return nil }
                    return EngineCatalogItem(name: name, url: asset.browser_download_url, size: asset.size, isRecommended: recommended.contains(name))
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
            catalogError = nil
        } catch {
            catalogError = error.localizedDescription
        }
    }

    /// Newest recommended engine from the catalog — what onboarding installs.
    var suggested: EngineCatalogItem? {
        catalog.first { $0.isRecommended && $0.name.contains("Sikarugir") } ?? catalog.first(where: \.isRecommended) ?? catalog.first
    }

    func install(_ item: EngineCatalogItem) async throws {
        progress[item.name] = 0
        defer { progress[item.name] = nil }
        let archive = try await Downloader.download(item.url) { value in
            Task { @MainActor in self.progress[item.name] = value * 0.9 }
        }
        defer { try? FileManager.default.removeItem(at: archive) }
        try await installArchive(archive, name: item.name)
    }

    func importArchive(_ archive: URL) async throws {
        let name = Self.engineName(forArchive: archive)
        progress[name] = 0.5
        defer { progress[name] = nil }
        try await installArchive(archive, name: name)
    }

    func remove(_ engine: Engine) throws {
        try FileManager.default.removeItem(at: engine.directory)
        reload()
    }

    private func installArchive(_ archive: URL, name: String) async throws {
        let staging = Paths.engines.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Downloader.extract(archive, into: staging)

        guard let bundle = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == "wswine.bundle" }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(archive.lastPathComponent) doesn't contain a wswine.bundle."])
        }
        let destination = Paths.engines.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: bundle, to: destination.appendingPathComponent("wswine.bundle"))
        reload()
    }

    static func engineName(forArchive url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".tar.xz", ".tar.7z", ".tar.gz", ".tar"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name
    }
}
