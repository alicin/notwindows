import Foundation
import Observation

struct EngineCatalogItem: Identifiable, Hashable {
    let name: String
    let url: URL
    let size: Int64
    let isRecommended: Bool
    var id: String { name }
    var displayName: String { Engine.displayName(for: name) }
    var family: EngineFamily { EngineFamily(engineName: name) }
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
    /// Gcenx's builds of upstream Wine (devel, staging and stable) for macOS.
    private static let wineBuildsRepository = "Gcenx/macOS_Wine_builds"

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

    private struct Release: Decodable { let assets: [Asset] }
    private struct Asset: Decodable { let name: String; let size: Int64; let browser_download_url: URL }

    func refreshCatalog() async {
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        async let sikarugir = Result { try await Self.sikarugirCatalog() }
        async let wineBuilds = Result { try await Self.wineBuildsCatalog() }
        let results = await [sikarugir, wineBuilds]

        var seen = Set<String>()
        catalog = results.flatMap { (try? $0.get()) ?? [] }
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        let failures = results.compactMap { result -> String? in
            if case .failure(let error) = result { error.localizedDescription } else { nil }
        }
        catalogError = failures.count == results.count ? failures.first : nil
    }

    /// Every engine Sikarugir publishes, with the ones its EngineList.txt points at marked as recommended.
    private static func sikarugirCatalog() async throws -> [EngineCatalogItem] {
        var releases: [Release] = []
        for page in 1...5 {
            let batch = try await Downloader.json([Release].self, from: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100&page=\(page)")!)
            releases += batch
            if batch.count < 100 { break }
        }
        let recommendedText = (try? await Downloader.string(URL(string: "https://raw.githubusercontent.com/\(repository)/HEAD/EngineList.txt")!)) ?? ""
        let recommended = Set(recommendedText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        return releases.flatMap(\.assets)
            .filter { $0.name.hasSuffix(".tar.xz") }
            .map { asset in
                let name = String(asset.name.dropLast(".tar.xz".count))
                return EngineCatalogItem(name: name, url: asset.browser_download_url, size: asset.size, isRecommended: recommended.contains(name))
            }
    }

    /// Upstream Wine from Gcenx's macOS builds, named like "wine-staging-11.18".
    private static func wineBuildsCatalog() async throws -> [EngineCatalogItem] {
        let releases = try await Downloader.json([Release].self, from: URL(string: "https://api.github.com/repos/\(wineBuildsRepository)/releases?per_page=30")!)
        return releases.flatMap(\.assets)
            .filter { $0.name.hasPrefix("wine-") && $0.name.hasSuffix("-osx64.tar.xz") }
            .map { EngineCatalogItem(name: String($0.name.dropLast("-osx64.tar.xz".count)), url: $0.browser_download_url, size: $0.size, isRecommended: false) }
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

    /// Installs the newest engine of a family from the catalog.
    func installNewest(of family: EngineFamily) async throws {
        if catalog.isEmpty { await refreshCatalog() }
        guard let item = catalog.first(where: { $0.family == family }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: catalogError ?? "No \(family.title) engine is available to download."])
        }
        try await install(item)
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

        // Sikarugir engines ship a wswine.bundle; Gcenx's upstream builds a "Wine ….app" whose Contents/Resources/wine
        // has the same bin/lib layout, so it's installed as the bundle.
        let files = FileManager.default.enumerator(at: staging, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        guard let bundle = files.first(where: { $0.lastPathComponent == "wswine.bundle" })
                ?? files.first(where: { $0.path.hasSuffix(".app/Contents/Resources/wine") && $0.appendingPathComponent("bin").isDirectoryURL }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(archive.lastPathComponent) doesn't contain a Wine engine."])
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
        if name.hasPrefix("wine-"), name.hasSuffix("-osx64") { name = String(name.dropLast("-osx64".count)) }
        return name
    }
}
