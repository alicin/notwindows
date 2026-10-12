import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            EnginesSettingsView()
                .tabItem { Label("Engines", systemImage: "cpu") }
            RuntimeSettingsView()
                .tabItem { Label("Runtime", systemImage: "shippingbox") }
            LinksSettingsView()
                .tabItem { Label("Links", systemImage: "link") }
            GeneralSettingsView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .frame(width: 720, height: 640)
    }
}

private struct GeneralSettingsView: View {
    @Environment(GameLibrary.self) private var library

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { library.autoApplyCompat }, set: { library.autoApplyCompat = $0 })) {
                    Text("Apply Smart Setup to new games")
                    Text("Scans each new game and applies recommended settings automatically. Installs always wait for your review.")
                }
                Button("Clear Fix Cache") { Task { await CompatSources.shared.clearCache() } }
            } header: {
                Text("Smart Setup")
            }
            Section("Library") {
                LabeledContent("Games") { Text("\(library.games.count)") }
                LabeledContent("Location") {
                    HStack {
                        Text(Paths.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.open(Paths.root) }
                    }
                }
            }
            Section {
                Text("Each game gets its own Windows prefix and its own settings, so tweaks for one game never affect another. Engines and the runtime are shared and downloaded once.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("How notwindows works")
            }
            Section("Credits") {
                Text("Wine engines, the runtime (MoltenVK, KosmicKrisp, DXVK, D9VK, DXMT, cnc-ddraw, GStreamer) and winetricks are provided by the [Sikarugir project](https://github.com/Sikarugir-App/Sikarugir). D3DMetal is © Apple and subject to its own license.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EnginesSettingsView: View {
    @Environment(EngineManager.self) private var engines
    @Environment(GameLibrary.self) private var library

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard(title: "Installed", symbol: "cpu.fill", tint: .purple,
                             subtitle: engines.installed.isEmpty ? "Nothing yet" : "\(engines.installed.count) engine\(engines.installed.count == 1 ? "" : "s")",
                             footer: "New games use the default engine; each game can pick another in its General tab.") {
                    Button("Import Archive…") { importArchive() }
                        .buttonStyle(.link)
                } content: {
                    if engines.installed.isEmpty {
                        SettingRow(title: "No engines installed yet", detail: "Download one below.")
                    }
                    ForEach(Array(engines.installed.enumerated()), id: \.element.id) { index, engine in
                        if index > 0 { RowDivider() }
                        InstalledEngineRow(engine: engine)
                    }
                }

                if !engines.localArchives.isEmpty {
                    SettingsCard(title: "Found in Sikarugir", symbol: "tray.and.arrow.down.fill", tint: .teal,
                                 subtitle: "Engines the Sikarugir Creator already downloaded") {
                    } content: {
                        ForEach(Array(engines.localArchives.enumerated()), id: \.element) { index, archive in
                            if index > 0 { RowDivider() }
                            let name = EngineManager.engineName(forArchive: archive)
                            SettingRow(title: Engine.displayName(for: name), detail: archive.lastPathComponent) {
                                if engines.progress[name] != nil {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Import") {
                                        Task { do { try await engines.importArchive(archive) } catch { library.report("Import failed", error) } }
                                    }
                                }
                            }
                        }
                    }
                }

                HStack {
                    Text("Available").font(.title3.bold())
                    Spacer()
                    if engines.isRefreshingCatalog { ProgressView().controlSize(.small) }
                    Button { Task { await engines.refreshCatalog() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
                if let error = engines.catalogError, engines.catalog.isEmpty {
                    NoticeRow("Couldn't load the engine list: \(error)")
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                ForEach(EngineFamily.allCases) { family in
                    let items = engines.catalog.filter { $0.family == family }
                    if !items.isEmpty { EngineFamilyCard(family: family, items: items) }
                }
                Text("The list comes from Sikarugir's engine releases and Gcenx's macOS Wine builds on GitHub.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .task {
            engines.reload()
            if engines.catalog.isEmpty { await engines.refreshCatalog() }
        }
    }

    private func importArchive() {
        guard let url = Panels.chooseFile(message: "Choose a Wine engine (.tar.xz)", types: [UTType(filenameExtension: "xz") ?? .archive]) else { return }
        Task {
            do { try await engines.importArchive(url) } catch { library.report("Import failed", error) }
        }
    }
}

private struct InstalledEngineRow: View {
    @Environment(EngineManager.self) private var engines
    @Environment(GameLibrary.self) private var library
    let engine: Engine
    @State private var size: Int64?

    var body: some View {
        let users = library.games.filter { $0.engineName == engine.name }.count
        let isDefault = engines.defaultEngineName == engine.name
        let capabilities = engine.capabilities
        let update = engines.catalog.first { $0.family == engine.family && !engines.isInstalled($0.name) }
            .flatMap { $0.name.localizedStandardCompare(engine.name) == .orderedDescending ? $0 : nil }

        HStack(alignment: .center, spacing: 12) {
            SymbolTile(symbol: engine.family.symbol, tint: engine.family.tint, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(engine.displayName).font(.headline)
                    if isDefault { StatusPill(text: "Default", symbol: "star.fill", tint: .orange) }
                }
                Text([engine.version, size.map(Format.bytes), users > 0 ? "\(users) game\(users == 1 ? "" : "s")" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if capabilities.rendererHooks {
                        StatusPill(text: "DXMT · DXVK · D3DMetal", tint: .green)
                    } else {
                        StatusPill(text: "WineD3D only")
                    }
                    if capabilities.rosettaX87 { StatusPill(text: "rosettax87", tint: .blue) }
                    if engine.isWin32Only { StatusPill(text: "32-bit only", tint: .orange) }
                }
            }
            Spacer(minLength: 8)
            if let update {
                if let progress = engines.progress[update.name] {
                    ProgressView(value: progress).frame(width: 80)
                } else {
                    Button("Update") {
                        Task { do { try await engines.install(update) } catch { library.report("Download failed", error) } }
                    }
                    .help("Download \(update.displayName)")
                }
            }
            Menu {
                Button("Make Default", systemImage: "star") { engines.defaultEngineName = engine.name }
                    .disabled(isDefault)
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([engine.directory]) }
                Divider()
                Button("Remove", systemImage: "trash", role: .destructive) {
                    do { try engines.remove(engine) } catch { library.report("Couldn't remove engine", error) }
                }
                .disabled(users > 0)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(users > 0 ? "In use by \(users) game\(users == 1 ? "" : "s"), so it can't be removed" : "More")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .task(id: engine.name) {
            let directory = engine.directory
            size = await Task.detached(priority: .utility) { FileManager.default.allocatedSize(of: directory) }.value
        }
    }
}

/// One family of engines: its newest build up front, older ones folded away.
private struct EngineFamilyCard: View {
    @Environment(EngineManager.self) private var engines
    let family: EngineFamily
    let items: [EngineCatalogItem]
    @State private var showsOlder = false

    var body: some View {
        SettingsCard(title: family.title, symbol: family.symbol, tint: family.tint, subtitle: family.summary) {
            if let latest = items.first {
                StatusPill(text: latest.displayName.replacingOccurrences(of: family.title + " ", with: ""), tint: family.tint)
            }
        } content: {
            if let latest = items.first { CatalogRow(item: latest) }
            if items.count > 1 {
                RowDivider()
                Button {
                    withAnimation(.smooth(duration: 0.25)) { showsOlder.toggle() }
                } label: {
                    HStack {
                        Text(showsOlder ? "Hide older versions" : "\(items.count - 1) older version\(items.count == 2 ? "" : "s")")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(showsOlder ? 180 : 0))
                            .font(.caption.weight(.semibold))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsOlder {
                    ForEach(items.dropFirst()) { item in
                        RowDivider()
                        CatalogRow(item: item)
                    }
                }
            }
        }
    }
}

private struct CatalogRow: View {
    @Environment(EngineManager.self) private var engines
    @Environment(GameLibrary.self) private var library
    let item: EngineCatalogItem

    var body: some View {
        SettingRow(title: item.displayName, detail: "\(item.name) · \(Format.bytes(item.size))",
                   badge: item.isRecommended ? "Recommended" : nil, badgeTint: .green) {
            if let progress = engines.progress[item.name] {
                ProgressView(value: progress).frame(width: 110)
            } else if engines.isInstalled(item.name) {
                Label("Installed", systemImage: "checkmark").foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            } else {
                Button("Download") {
                    Task { do { try await engines.install(item) } catch { library.report("Download failed", error) } }
                }
            }
        }
    }
}

extension EngineFamily {
    var tint: Color {
        switch self {
        case .sikarugir: .purple
        case .crossOver: .red
        case .crossOver32: .orange
        case .gptk: .gray
        case .whisky: .blue
        case .wineStaging: .teal
        case .wineDevel: .indigo
        case .wine: .brown
        }
    }
}

private struct RuntimeSettingsView: View {
    @Environment(RuntimeManager.self) private var runtime
    @Environment(GameLibrary.self) private var library

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed") {
                    Text(runtime.current?.name ?? "Not installed")
                        .foregroundStyle(runtime.current == nil ? .secondary : .primary)
                }
                LabeledContent("Latest") {
                    Text(runtime.latestName ?? "—")
                }
                if let progress = runtime.progress {
                    ProgressView(value: progress) { Text(runtime.status ?? "") }
                } else {
                    HStack {
                        Button("Check for Updates") { Task { await runtime.checkForUpdate() } }
                        Spacer()
                        if runtime.current == nil || runtime.isUpdateAvailable {
                            Button(runtime.current == nil ? "Install" : "Update to \(runtime.latestName ?? "")") {
                                Task { do { try await runtime.installLatest() } catch { library.report("Runtime install failed", error) } }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            } header: {
                Text("Sikarugir runtime")
            } footer: {
                Text("The graphics and media stack from Sikarugir's wrapper template, shared by every game.")
                    .sectionNote()
            }

            if let current = runtime.current {
                Section("Components") {
                    ForEach(current.components) { component in
                        LabeledContent(component.name) {
                            Text(component.version).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }

            Section("Winetricks") {
                HStack {
                    Text(Paths.tools.appendingPathComponent("winetricks").exists ? "Downloaded" : "Downloaded on first use")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Update Winetricks") {
                        Task { do { try await runtime.refreshWinetricks() } catch { library.report("Couldn't update winetricks", error) } }
                    }
                }
            }

            if !runtime.isRosettaInstalled {
                Section("Rosetta 2") {
                    Text("Not installed. Run `softwareupdate --install-rosetta --agree-to-license` in Terminal.")
                }
            }
        }
        .formStyle(.grouped)
        .task { await runtime.checkForUpdate() }
    }
}

private struct LinksSettingsView: View {
    @Environment(GameLibrary.self) private var library

    var body: some View {
        Form {
            Section {
                if library.linkHandlers.isEmpty {
                    Text("No game has registered a link type yet. Launchers usually register theirs the first time they run.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.linkHandlers) { handler in
                    LinkHandlerRow(handler: handler)
                }
            } header: {
                HStack {
                    Text("Link types from your games")
                    Spacer()
                    Button { library.refreshLinkHandlers() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Rescan")
                }
            } footer: {
                Text("Launchers that sign in through your browser finish by opening a link like jagex:// or com.epicgames.launcher://. notwindows registers a small helper for each of these with macOS and hands the link to the game that registered it.")
                    .sectionNote()
            }
        }
        .formStyle(.grouped)
        .onAppear { library.refreshLinkHandlers() }
    }
}

struct LinkHandlerRow: View {
    @Environment(GameLibrary.self) private var library
    let handler: LinkHandler

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(handler.scheme)://").font(.body.monospaced())
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            switch handler.status {
            case .active:
                Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon).font(.caption)
                Button("Turn Off") { library.setLinkScheme(handler.scheme, enabled: false) }.controlSize(.small)
            case .disabled:
                Text("Off").font(.caption).foregroundStyle(.secondary)
                Button("Turn On") { library.setLinkScheme(handler.scheme, enabled: true) }.controlSize(.small)
            case .handledByOtherApp(let app):
                Text("Opens in \(app)").font(.caption).foregroundStyle(.orange)
                Button("Use notwindows") { library.takeOverLinkScheme(handler.scheme) }.controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(1).help(message)
            }
        }
    }

    private var subtitle: String {
        let games = handler.gameIDs.compactMap { library.game($0)?.name }
        let program = handler.program.map { "\($0) · " } ?? ""
        return program + (games.isEmpty ? "No game" : games.joined(separator: ", "))
    }
}
