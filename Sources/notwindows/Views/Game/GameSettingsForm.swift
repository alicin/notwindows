import SwiftUI

struct GameSettingsForm: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(AppNavigation.self) private var navigation

    let gameID: UUID
    let tab: GameTab

    private var game: Game { library.game(gameID) ?? Game(name: "") }
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
            Picker("Windows version", selection: setting(\.windowsVersion)) {
                ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Compatibility")
        } footer: {
            Text("Switching engines on an existing prefix makes Wine update it on next launch.")
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
            if game.externalPrefixPath != nil {
                Label("Imported wrapper — the prefix lives inside the original app bundle.", systemImage: "shippingbox")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Graphics

    @ViewBuilder
    private var graphics: some View {
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
            if game.settings.direct3DBackend == .d3dmetal {
                Text("D3DMetal is Apple's Game Porting Toolkit layer. It's licensed for evaluation only and runs 64-bit games.")
            }
        }

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
            Picker("DXVK version", selection: setting(\.dxvkVersion)) {
                ForEach(DXVKVersion.allCases) { Text($0.title).tag($0) }
            }
            .disabled(game.settings.direct3DBackend != .dxvk)
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
            Text("Used by DXVK and D9VK. Automatic picks DXVK 3.x with KosmicKrisp and 1.10 with MoltenVK.")
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
        }

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
            if let exe = game.executableURL, game.settings.wineRosetta, !WineRosetta.is32BitExecutable(exe) {
                Label("This executable isn't 32-bit, so WineRosetta won't help it.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("32-bit games on Apple Silicon")
        } footer: {
            Text("Places winerosetta as d3d9.dll next to the game (and D9VK as d9vk.dll when Direct3D 8/9 uses D9VK). Anything already there is moved aside and put back when you turn this off.")
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
        }

        DLLOverridesSection(gameID: gameID)
        EnvironmentSection(gameID: gameID)

        Section {
            if game.externalPrefixPath == nil {
                Button("Reset Prefix…", role: .destructive) { confirmReset() }
                    .disabled(library.state(of: gameID).isBusy)
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
        alert.informativeText = "The current prefix, including anything installed into it and its save files, is moved to the Trash and a fresh one is created."
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
            if candidates != nil {
                HStack {
                    Spacer()
                    Button("Rescan") { library.scanForExecutables(gameID) }
                        .buttonStyle(.link)
                }
            }
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
