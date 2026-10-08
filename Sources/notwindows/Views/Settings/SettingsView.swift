import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            EnginesSettingsView()
                .tabItem { Label("Engines", systemImage: "cpu") }
            RuntimeSettingsView()
                .tabItem { Label("Runtime", systemImage: "shippingbox") }
            GeneralSettingsView()
                .tabItem { Label("Library", systemImage: "books.vertical") }
        }
        .frame(width: 640, height: 520)
    }
}

private struct GeneralSettingsView: View {
    @Environment(GameLibrary.self) private var library

    var body: some View {
        Form {
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
    @State private var showAll = false

    var body: some View {
        @Bindable var engines = engines

        Form {
            Section("Installed") {
                if engines.installed.isEmpty {
                    Text("No engines installed yet.").foregroundStyle(.secondary)
                } else {
                    Picker("Default engine", selection: $engines.defaultEngineName) {
                        ForEach(engines.installed) { Text($0.displayName).tag(Optional($0.name)) }
                    }
                    ForEach(engines.installed) { engine in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(engine.displayName)
                                Text(engine.version).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            let users = library.games.filter { $0.engineName == engine.name }.count
                            if users > 0 {
                                Text("\(users) game\(users == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Remove", role: .destructive) {
                                do { try engines.remove(engine) } catch { library.report("Couldn't remove engine", error) }
                            }
                            .disabled(users > 0)
                        }
                    }
                }
                Button("Import Engine Archive…") {
                    if let url = Panels.chooseFile(message: "Choose a Sikarugir engine (.tar.xz)", types: [UTType(filenameExtension: "xz") ?? .archive]) {
                        Task {
                            do { try await engines.importArchive(url) } catch { library.report("Import failed", error) }
                        }
                    }
                }
            }

            if !engines.localArchives.isEmpty {
                Section("Found in Sikarugir") {
                    ForEach(engines.localArchives, id: \.self) { archive in
                        let name = EngineManager.engineName(forArchive: archive)
                        HStack {
                            Text(Engine.displayName(for: name))
                            Spacer()
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

            Section {
                if engines.catalog.isEmpty {
                    HStack {
                        if engines.isRefreshingCatalog { ProgressView().controlSize(.small) }
                        Text(engines.catalogError ?? "Loading…").foregroundStyle(.secondary)
                    }
                }
                ForEach(engines.catalog.filter { showAll || $0.isRecommended }) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(item.displayName)
                                if item.isRecommended {
                                    Text("Recommended")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text("\(item.name) · \(Format.bytes(item.size))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
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
            } header: {
                HStack {
                    Text("Available")
                    Spacer()
                    Toggle("Show all versions", isOn: $showAll).toggleStyle(.checkbox).font(.caption)
                    Button { Task { await engines.refreshCatalog() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            engines.reload()
            if engines.catalog.isEmpty { await engines.refreshCatalog() }
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
