import SwiftUI

struct GameSettingsForm: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(AppNavigation.self) private var navigation

    let gameID: UUID
    let tab: GameTab

    private var game: Game { library.game(gameID) ?? Game(name: "") }
    private var engine: Engine? { engines.engine(named: library.launcher(of: game)?.engineName ?? game.engineName) }
    private func setting<V>(_ keyPath: WritableKeyPath<GameSettings, V>) -> Binding<V> { library.setting(gameID, keyPath) }

    var body: some View {
        Form {
            switch tab {
            case .general: general
            case .graphics: graphics
            case .performance: performance
            case .input: input
            case .advanced: advanced
            }
        }
        .formStyle(.grouped)
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        if game.executablePath.isEmpty || library.candidates[gameID] != nil {
            ExecutablePickerSection(gameID: gameID)
        }

        SmartSetupBanner(gameID: gameID)

        if game.isSteamLauncher {
            SteamLauncherSection(gameID: gameID)
        } else if game.isSteamGame {
            SteamGameSection(gameID: gameID)
        }

        Section("Game") {
            TextField("Name", text: library.binding(gameID, \.name, default: ""))
            LabeledContent("Executable") {
                HStack {
                    Text(game.displayExecutablePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(game.executablePath)
                    Button("Choose…") {
                        if let url = Panels.chooseFile(message: "Choose the game's executable", types: Panels.windowsExecutableTypes,
                                                       directory: game.executableURL?.deletingLastPathComponent() ?? game.driveC) {
                            library.chooseExecutable(url, for: gameID)
                        }
                    }
                }
            }
            TextField("Arguments", text: library.binding(gameID, \.arguments, default: ""), prompt: Text("e.g. -dx11 -windowed"))
            TextField("Working folder", text: library.binding(gameID, \.workingDirectory, default: nil).withDefault(""),
                      prompt: Text("Executable's folder"))
        }

        Section {
            if let launcher = library.launcher(of: game) {
                LabeledContent("Wine engine") {
                    Text(engines.engine(named: launcher.engineName)?.displayName ?? "Steam's engine")
                        .foregroundStyle(.secondary)
                }
            } else {
            Picker("Wine engine", selection: library.binding(gameID, \.engineName, default: nil)) {
                Text("Default (\(engines.defaultEngine?.displayName ?? "none"))").tag(String?.none)
                if !engines.installed.isEmpty { Divider() }
                ForEach(engines.installed) { engine in
                    Text(engine.displayName).tag(Optional(engine.name))
                }
                if let name = game.engineName, !engines.isInstalled(name) {
                    Text("\(Engine.displayName(for: name)) (missing)").tag(Optional(name))
                }
            }
            }
            Picker("Windows version", selection: setting(\.windowsVersion)) {
                ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
            }
            if let engine, let is32Bit = game.isPrefix32Bit, is32Bit != engine.isWin32Only {
                HStack {
                    Label(is32Bit ? "This prefix is 32-bit, which \(engine.displayName) can't run."
                                  : "\(engine.displayName) needs a 32-bit prefix; this one is 64-bit.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    if game.externalPrefixPath == nil {
                        Button("Reset Prefix…") { confirmReset() }
                            .disabled(library.state(of: gameID).isBusy)
                    }
                }
            }
        } header: {
            Text("Compatibility")
        } footer: {
            Group {
                if let engine, engine.isWin32Only {
                    Text("\(engine.displayName) runs only 32-bit Windows programs, in a 32-bit prefix, and draws all Direct3D through WineD3D (OpenGL). It suits older 32-bit games.")
                } else if game.isSteamGame {
                    Text("Steam games run next to the Steam client, so they use its engine. Windows version and other registry settings apply to this game only.")
                } else if game.externalPrefixPath != nil, !library.prefixMates(of: game).isEmpty {
                    Text("While another game in this prefix is running, this one uses that game's engine. Windows version and other registry settings apply to this game only.")
                } else {
                    Text("Switching engines on an existing prefix makes Wine update it on next launch.")
                }
            }
            .sectionNote()
        }

        Section("Prefix") {
            LabeledContent("Location") {
                HStack {
                    Text(game.prefixURL.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Open C: Drive") { NSWorkspace.shared.open(game.driveC) }
                        .disabled(!game.driveC.exists)
                }
            }
            if let owner = library.prefixOwner(of: game) {
                Label("Shares \(owner.name)'s prefix.", systemImage: "person.2")
                    .foregroundStyle(.secondary)
            } else if game.externalPrefixPath?.contains(".app/") == true {
                Label("Imported wrapper — the prefix lives inside the original app bundle.", systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
            } else if game.externalPrefixPath != nil {
                Label("Uses an existing prefix folder.", systemImage: "folder")
                    .foregroundStyle(.secondary)
            }
            let guests = game.externalPrefixPath == nil ? library.prefixMates(of: game) : []
            if !guests.isEmpty {
                Label("Also used by \(guests.map(\.name).formatted(.list(type: .and))).", systemImage: "person.2")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Graphics

    @ViewBuilder
    private var graphics: some View {
        if let engine, engine.isWin32Only {
            Section {
                Label("\(engine.displayName) draws every Direct3D version through WineD3D (OpenGL), so the renderer choices below don't apply to it.",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Picker("Direct3D 10 / 11 / 12", selection: setting(\.direct3DBackend)) {
                ForEach(Direct3DBackend.allCases) { backend in
                    VStack(alignment: .leading) {
                        Text(backend.title)
                        Text(backend.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(backend)
                }
            }
            .pickerStyle(.radioGroup)

            Picker("Direct3D 8 / 9", selection: setting(\.direct3D9Backend)) {
                ForEach(Direct3D9Backend.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: setting(\.cncDDraw)) {
                Text("cnc-ddraw for DirectDraw")
                Text("Fixes many classic 2D games (DirectDraw 1–7).")
            }
        } header: {
            Text("Renderer")
        } footer: {
            Group {
                if game.settings.direct3DBackend == .d3dmetal {
                    Text("D3DMetal is Apple's Game Porting Toolkit layer. It's licensed for evaluation only and runs 64-bit games.")
                }
            }
            .sectionNote()
        }

        ShaderCacheSection(gameID: gameID)

        Section("Display") {
            Toggle(isOn: setting(\.retinaMode)) {
                Text("High resolution (Retina) mode")
                Text("Renders at full pixel density. Sharper, but heavier on the GPU.")
            }
            Toggle(isOn: setting(\.metalHUD)) {
                Text("Metal performance HUD")
                Text("Shows FPS, frame time and GPU memory.")
            }
            Toggle("Font smoothing", isOn: setting(\.fontSmoothing))
        }

        Section {
            Picker("Vulkan driver", selection: setting(\.vulkanDriver)) {
                ForEach(VulkanDriver.allCases) { Text($0.title).tag($0) }
            }
            Picker("DXVK / D9VK version", selection: setting(\.dxvkVersion)) {
                ForEach(DXVKVersion.allCases) { Text($0.title).tag($0) }
            }
            .disabled(game.settings.direct3DBackend != .dxvk && game.settings.direct3D9Backend != .d9vk)
            Toggle(isOn: setting(\.dxvkAsync)) {
                Text("Asynchronous shader compilation")
                Text("Reduces stutter while shaders compile, at the cost of brief visual glitches.")
            }
            Picker("DXVK HUD", selection: setting(\.dxvkHUD)) {
                ForEach(DXVKHUD.allCases) { Text($0.title).tag($0) }
            }
            Toggle("MoltenVK fast math", isOn: setting(\.moltenVKFastMath))
        } header: {
            Text("Vulkan")
        } footer: {
            Text("Used by DXVK and D9VK. Automatic picks the 3.x builds with KosmicKrisp, and DXVK 1.10 / D9VK 2.3 with MoltenVK, which lacks the Vulkan 1.3 features 3.x needs.")
                .sectionNote()
        }
    }

    // MARK: Performance

    @ViewBuilder
    private var performance: some View {
        Section {
            Toggle(isOn: setting(\.msync)) {
                Text("MSync")
                Text("Mach-port based synchronization. Usually the fastest option on macOS.")
            }
            Toggle(isOn: setting(\.esync)) {
                Text("ESync")
                Text("Eventfd-style synchronization. Fallback when MSync is off.")
            }
        } header: {
            Text("Synchronization")
        } footer: {
            Group {
                if game.isSteamGame {
                    Text("Follows the Steam entry's settings, since all processes in a prefix must use the same mode.")
                }
            }
            .sectionNote()
        }
        .disabled(game.isSteamGame)

        Section {
            Toggle(isOn: setting(\.advertiseAVX)) {
                Text("Advertise AVX to games")
                Text("Lets games that require AVX start under Rosetta 2.")
            }
        } header: {
            Text("CPU")
        }

        Section {
            Toggle(isOn: setting(\.wineRosetta)) {
                Text("WineRosetta")
                Text("Emulates the instructions Rosetta 2 can't run in 32-bit World of Warcraft (1.12.1, 2.4.3, 3.3.5a).")
            }
            Toggle(isOn: setting(\.rosettaX87)) {
                HStack(spacing: 6) {
                    Text("rosettax87")
                    Text("Experimental")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Text("Replaces Rosetta's slow x87 math with a fast version, often many times faster in old 32-bit games. The first time, macOS may ask to allow Developer Tools access.")
            }
            if let exe = game.executableURL, game.settings.wineRosetta, !WineRosetta.is32BitExecutable(exe) {
                Label("This executable isn't 32-bit, so WineRosetta won't help it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("32-bit games on Apple Silicon")
        } footer: {
            Text("Places winerosetta as d3d9.dll next to the game (and D9VK as d9vk.dll when Direct3D 8/9 uses D9VK). Anything already there is moved aside and put back when you turn this off.")
                .sectionNote()
        }
    }

    // MARK: Input

    @ViewBuilder
    private var input: some View {
        Section {
            Toggle(isOn: setting(\.commandAsControl)) {
                Text("Command keys act as Control")
                Text("Handy for games with Ctrl-heavy shortcuts.")
            }
            Toggle(isOn: setting(\.optionAsAlt)) {
                Text("Option keys act as Alt")
                Text("Needed for Alt-key bindings and Alt+Enter.")
            }
        } header: {
            Text("Keyboard")
        }

        Section {
            Toggle(isOn: Binding(get: { !game.settings.disableMFiControllers },
                                 set: { value in library.update(gameID) { $0.settings.disableMFiControllers = !value } })) {
                Text("Use the MFi controller API")
                Text("Off routes controllers through IOKit/HID, which works better for most games.")
            }
        } header: {
            Text("Controllers")
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advanced: some View {
        Section("Logging") {
            Picker("Wine log level", selection: setting(\.logLevel)) {
                ForEach(WineLogLevel.allCases) { Text($0.title).tag($0) }
            }
        }

        Section {
            Toggle("Skip Wine Mono (.NET)", isOn: setting(\.skipMono))
            Toggle("Skip Wine Gecko (HTML)", isOn: setting(\.skipGecko))
        } header: {
            Text("Prefix components")
        } footer: {
            Text("Applies when the prefix is created or reset, and disables the components at launch.")
                .sectionNote()
        }

        let links = library.linkHandlers.filter { $0.gameIDs.contains(gameID) }
        if !links.isEmpty {
            Section {
                ForEach(links) { LinkHandlerRow(handler: $0) }
            } header: {
                Text("Links")
            } footer: {
                Text("Browser sign-ins that end with these links are handed back to this game.")
                    .sectionNote()
            }
        }

        DLLOverridesSection(gameID: gameID)
        EnvironmentSection(gameID: gameID)

        Section {
            if game.externalPrefixPath == nil {
                Button("Reset Prefix…", role: .destructive) { confirmReset() }
                    .disabled(([game] + library.prefixMates(of: game)).contains { library.state(of: $0.id).isBusy })
            }
            Button("Remove from Library…", role: .destructive) {
                RemoveGameConfirmation.present(game: game, library: library) { navigation.selection = .allGames }
            }
        } header: {
            Text("Danger zone")
        }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset the prefix for “\(game.name)”?"
        let guests = library.prefixMates(of: game).map(\.name)
        alert.informativeText = "The current prefix, including anything installed into it and its save files, is moved to the Trash and a fresh one is created."
            + (guests.isEmpty ? "" : " \(guests.formatted(.list(type: .and))) also \(guests.count == 1 ? "uses" : "use") it and will lose what's installed there.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { library.resetPrefix(gameID) }
    }
}

private struct ExecutablePickerSection: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let candidates = library.candidates[gameID]
        Section {
            if let candidates {
                if candidates.isEmpty {
                    Text("No executables found yet. Use Choose… below, or run the installer again from Tools › Run Program in Prefix.")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { candidate in
                    Button {
                        library.chooseExecutable(candidate.url, for: gameID)
                    } label: {
                        HStack(spacing: 10) {
                            GameIconView(icon: PEIconExtractor.image(fromExecutableAt: candidate.url), size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(candidate.url.lastPathComponent).foregroundStyle(.primary)
                                Text(relativePath(candidate.url)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Format.bytes(candidate.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack {
                    Text("This game doesn't have an executable yet.")
                    Spacer()
                    Button("Scan Prefix") { library.scanForExecutables(gameID) }
                }
            }
        } header: {
            Text("Choose the game's executable")
        } footer: {
            Group {
                if candidates != nil {
                    HStack {
                        Spacer()
                        Button("Rescan") { library.scanForExecutables(gameID) }
                            .buttonStyle(.link)
                    }
                }
            }
            .sectionNote()
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let drive = library.game(gameID)?.driveC.path, url.path.hasPrefix(drive) else { return url.path }
        return "C:" + url.deletingLastPathComponent().path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
    }
}

private struct DLLOverridesSection: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let overrides = library.setting(gameID, \.dllOverrides)
        Section {
            ForEach(overrides) { $item in
                HStack {
                    TextField("DLL", text: $item.name, prompt: Text("d3dcompiler_47"))
                        .labelsHidden()
                    Picker("Mode", selection: $item.mode) {
                        ForEach(DLLOverrideMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Button {
                        overrides.wrappedValue.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                overrides.wrappedValue.append(DLLOverride(name: "", mode: .nativeThenBuiltin))
            } label: {
                Label("Add Override", systemImage: "plus")
            }
        } header: {
            Text("DLL overrides")
        } footer: {
            Text("Passed to Wine as WINEDLLOVERRIDES. Use native for DLLs you've dropped next to the game.")
                .sectionNote()
        }
    }
}

private struct EnvironmentSection: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let variables = library.setting(gameID, \.environment)
        Section {
            ForEach(variables) { $item in
                HStack {
                    TextField("Name", text: $item.key, prompt: Text("NAME"))
                        .labelsHidden()
                        .font(.body.monospaced())
                    Text("=").foregroundStyle(.secondary)
                    TextField("Value", text: $item.value, prompt: Text("value"))
                        .labelsHidden()
                        .font(.body.monospaced())
                    Button {
                        variables.wrappedValue.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                variables.wrappedValue.append(EnvironmentVariable(key: "", value: ""))
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
        } header: {
            Text("Environment variables")
        } footer: {
            Text("Applied last, so they override anything notwindows sets.")
                .sectionNote()
        }
    }
}

extension Binding {
    func withDefault<T>(_ fallback: T) -> Binding<T> where Value == T? {
        Binding<T>(
            get: { wrappedValue ?? fallback },
            set: { newValue in
                if let string = newValue as? String, string.isEmpty { wrappedValue = nil } else { wrappedValue = newValue }
            }
        )
    }
}

/// Nudges toward Smart Setup when there are recommended changes the game doesn't have yet.
private struct SmartSetupBanner: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let pending = pendingCount
        if library.compatLoading.contains(gameID) {
            Section {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking up fixes for this game…").foregroundStyle(.secondary)
                }
            }
        } else if pending > 0 || library.compatReports[gameID] == nil {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundStyle(.purple)
                        .symbolEffect(.pulse, options: .repeating, isActive: pending > 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending > 0 ? "\(pending) suggested change\(pending == 1 ? "" : "s")" : "Smart Setup")
                            .font(.headline)
                        Text(pending > 0
                             ? "Based on the executable and known fixes for this game."
                             : "Scan the executable and look up known fixes for this game.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(pending > 0 ? "Review…" : "Scan…") { library.compatSheetGameID = gameID }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var pendingCount: Int {
        guard let report = library.compatReports[gameID], let game = library.game(gameID) else { return 0 }
        let installed = library.installedWinetricksVerbs(gameID)
        return report.suggestions.filter { $0.recommended && !$0.action.isSatisfied(by: game, installedVerbs: installed) }.count
    }
}

private struct SteamLauncherSection: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let gameID: UUID

    var body: some View {
        let games = library.steamGames(of: gameID)
        Section {
            if games.isEmpty {
                Text("No installed games found yet. Install games in Steam and they'll show up here automatically, each with its own settings.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(games) { game in
                    Button {
                        navigation.selection = .game(game.id)
                    } label: {
                        HStack(spacing: 10) {
                            GameIconView(icon: library.icons[game.id], size: 24)
                            Text(game.name).foregroundStyle(.primary)
                            Spacer()
                            if game.executablePath.isEmpty {
                                Text("No executable").font(.caption).foregroundStyle(.orange)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            HStack {
                Text("Steam Library")
                Spacer()
                Button("Sync Now") { library.syncSteamLibrary(gameID) }
                    .buttonStyle(.link)
            }
        } footer: {
            Text("Games installed through this Steam appear in your library and the sidebar. Playing one starts Steam in the background, then runs the game with its own settings.")
                .sectionNote()
        }
    }
}

private struct SteamGameSection: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let gameID: UUID

    var body: some View {
        let game = library.game(gameID)
        Section {
            if let launcher = game.flatMap({ library.launcher(of: $0) }) {
                LabeledContent("Installed through") {
                    Button(launcher.name) { navigation.selection = .game(launcher.id) }
                        .buttonStyle(.link)
                }
            }
            if let appID = game?.steamAppID {
                LabeledContent("Steam app") {
                    Link(String(appID), destination: URL(string: "https://store.steampowered.com/app/\(appID)")!)
                }
            }
            if let folder = game?.installDirectory {
                LabeledContent("Install folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                        .buttonStyle(.link)
                }
            }
        } header: {
            Text("Steam")
        } footer: {
            Text("Play starts Steam in the background if needed, then launches the game directly so its own settings apply. A steam_appid.txt is added next to the executable so the game doesn't restart through the Steam client.")
                .sectionNote()
        }
    }
}

private struct ShaderCacheSection: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID
    @State private var size: Int64?

    var body: some View {
        Section {
            LabeledContent("This game's cache") {
                HStack {
                    Text(size.map { $0 == 0 ? "Empty" : Format.bytes($0) } ?? "…").foregroundStyle(.secondary)
                    Button("Clear") { clear() }
                        .disabled((size ?? 0) == 0 || library.state(of: gameID).isBusy)
                }
            }
        } header: {
            Text("Shader cache")
        } footer: {
            Text("Shaders are compiled the first time a game needs them, which causes the stutter on first launch or in new areas. DXMT saves them here; macOS also keeps compiled Metal shaders for all games. Clear only if a game shows graphics glitches after an update.")
                .sectionNote()
        }
        .task { refresh() }
    }

    private var folder: URL? { library.game(gameID)?.cacheDirectory }

    private func refresh() {
        guard let folder else { return }
        Task.detached(priority: .utility) {
            let total = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])?.compactMap { item -> Int64? in
                guard let url = item as? URL else { return nil }
                return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            } ?? []).reduce(0, +)
            await MainActor.run { size = total }
        }
    }

    private func clear() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
        refresh()
    }
}
