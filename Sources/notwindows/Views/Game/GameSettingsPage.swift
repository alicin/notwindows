import GameController
import SwiftUI

/// Things the settings page asks the surrounding game page to show.
struct GamePageActions {
    var showWinetricks: () -> Void = {}
    var showLog: () -> Void = {}
}

struct GameSettingsPage: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(AppNavigation.self) private var navigation

    let gameID: UUID
    let tab: GameTab
    let report: ExecutableReport?
    var actions = GamePageActions()

    private var game: Game { library.game(gameID) ?? Game(name: "") }
    private var launcher: Game? { library.launcher(of: game) }
    private var engine: Engine? { engines.engine(named: launcher?.engineName ?? game.engineName) }
    private var isWin32Engine: Bool { engine?.isWin32Only == true }
    private var lacksRendererHooks: Bool { engine?.capabilities.rendererHooks == false }
    private var lacksRosettaX87: Bool { engine?.capabilities.rosettaX87 == false }
    /// What actually takes effect at launch, which can differ from what's stored (e.g. under CrossOver's 32-bit engine).
    private var effective: GameSettings { engine.map { WineEnvironment.renderers(for: game.settings, engine: $0) } ?? game.settings }
    private func setting<V>(_ keyPath: WritableKeyPath<GameSettings, V>) -> Binding<V> { library.setting(gameID, keyPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            switch tab {
            case .general: general
            case .graphics: graphics
            case .performance: performance
            case .input: input
            case .advanced: advanced
            }
        }
        .formColumn()
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        if game.executablePath.isEmpty || library.candidates[gameID] != nil {
            ExecutablePickerCard(gameID: gameID)
        }

        SmartSetupBanner(gameID: gameID)

        if game.isSteamLauncher {
            SteamLauncherCard(gameID: gameID)
        } else if game.isSteamGame {
            SteamGameCard(gameID: gameID)
        }

        SettingsCard(title: "Game", symbol: "gamecontroller.fill", tint: .indigo, subtitle: report?.companyName) {
            if let report {
                StatusPill(text: report.is64Bit ? "64-bit" : "32-bit", symbol: "cpu")
            }
        } content: {
            textRow("Name", text: library.binding(gameID, \.name, default: ""))
            RowDivider()
            SettingRow(title: "Executable", detail: game.displayExecutablePath) {
                Button("Choose…") {
                    if let url = Panels.chooseFile(message: "Choose the game's executable", types: Panels.windowsExecutableTypes,
                                                   directory: game.executableURL?.deletingLastPathComponent() ?? game.driveC) {
                        library.chooseExecutable(url, for: gameID)
                    }
                }
            }
            .help(game.executablePath)
            RowDivider()
            textRow("Arguments", text: library.binding(gameID, \.arguments, default: ""), prompt: "e.g. -dx11 -windowed")
            RowDivider()
            textRow("Working folder", text: library.binding(gameID, \.workingDirectory, default: nil).withDefault(""), prompt: "Executable's folder")
        }

        SettingsCard(title: "Wine", symbol: "wineglass.fill", tint: .purple, subtitle: engine?.displayName ?? "No engine installed",
                     footer: wineFooter) {
            if let engine {
                StatusPill(text: engine.isWin32Only ? "32-bit only" : "32 + 64-bit", symbol: "cpu")
            }
        } content: {
            if let launcher {
                SettingRow(title: "Wine engine", detail: "Steam games run next to \(launcher.name), so they use its engine.") {
                    Text(engine?.displayName ?? "Steam's engine").foregroundStyle(.secondary)
                }
            } else {
                SettingRow(title: "Wine engine") {
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
                    .labelsHidden()
                    .fixedSize()
                }
            }
            RowDivider()
            SettingRow(title: "Windows version") {
                Picker("Windows version", selection: setting(\.windowsVersion)) {
                    ForEach(WindowsVersion.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let engine, let is32Bit = game.isPrefix32Bit, is32Bit != engine.isWin32Only {
                NoticeRow(text: is32Bit ? "This prefix is 32-bit, which \(engine.displayName) can't run."
                                        : "\(engine.displayName) needs a 32-bit prefix; this one is 64-bit.") {
                    if game.externalPrefixPath == nil {
                        Button("Reset Prefix…") { confirmReset() }
                            .disabled(library.state(of: gameID).isBusy)
                    }
                }
            }
        }

        PrefixCard(gameID: gameID, showWinetricks: actions.showWinetricks)
    }

    private var wineFooter: String {
        if let engine, engine.isWin32Only {
            return "\(engine.displayName) runs only 32-bit Windows programs, in a 32-bit prefix, and draws all Direct3D through WineD3D (OpenGL). It suits older 32-bit games."
        } else if game.isSteamGame {
            return "Windows version and other registry settings apply to this game only."
        } else if game.externalPrefixPath != nil, !library.prefixMates(of: game).isEmpty {
            return "While another game in this prefix is running, this one uses that game's engine. Windows version and other registry settings apply to this game only."
        }
        return "Switching engines on an existing prefix makes Wine update it on next launch."
    }

    // MARK: Graphics

    @ViewBuilder
    private var graphics: some View {
        let api = report?.graphicsAPI
        let lockedByEngine = lacksRendererHooks ? "\(engine?.displayName ?? "This engine") always draws through WineD3D (OpenGL)." : nil

        SettingsCard(title: "Render pipeline", symbol: "point.3.connected.trianglepath.dotted", tint: .pink,
                     subtitle: "How each graphics API reaches your GPU") {
            if let api {
                StatusPill(text: "Uses \(api.title)", symbol: "scope", tint: .pink)
            }
        } content: {
            PipelineRow(api: "Direct3D 10 · 11 · 12", stages: stages(for: effective.direct3DBackend),
                        isUsedByGame: api?.isModernDirect3D == true, tint: .pink)
            RowDivider()
            PipelineRow(api: "Direct3D 8 · 9", stages: stages(for: effective.direct3D9Backend),
                        isUsedByGame: api == .d3d9 || api == .d3d8, tint: .pink)
            RowDivider()
            PipelineRow(api: "DirectDraw", stages: effective.cncDDraw ? ["cnc-ddraw"] : ["WineD3D", "OpenGL"],
                        isUsedByGame: api == .directDraw, tint: .pink)
        }

        SettingsCard(title: "Direct3D 10 · 11 · 12", symbol: "cube.fill", tint: .blue, subtitle: "Modern renderer",
                     footer: effective.direct3DBackend == .d3dmetal ? "D3DMetal is Apple's Game Porting Toolkit layer. It's licensed for evaluation only." : nil,
                     locked: lockedByEngine) {
            StatusPill(text: effective.direct3DBackend.shortTitle, tint: .blue)
        } content: {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Direct3DBackend.allCases) { backend in
                    OptionTile(symbol: backend.symbol, title: backend.shortTitle, caption: backend.api, detail: backend.detail,
                               tags: tags(for: backend, api: api), isSelected: effective.direct3DBackend == backend, tint: .blue) {
                        setting(\.direct3DBackend).wrappedValue = backend
                    }
                }
            }
            .padding(12)
            if lockedByEngine == nil, let report {
                if effective.direct3DBackend == .d3dmetal && !report.is64Bit {
                    NoticeRow("D3DMetal runs only 64-bit games, and this one is 32-bit.")
                } else if api == .d3d12 && effective.direct3DBackend != .d3dmetal {
                    NoticeRow("This game uses Direct3D 12, which needs D3DMetal.")
                }
            }
        }

        SettingsCard(title: "Older games", symbol: "clock.arrow.circlepath", tint: .orange, subtitle: "Direct3D 8 / 9 and DirectDraw",
                     locked: lockedByEngine) {
            StatusPill(text: effective.direct3D9Backend == .d9vk ? "D9VK" : "WineD3D", tint: .orange)
        } content: {
            SettingRow(title: "Direct3D 8 / 9") {
                Picker("Direct3D 8 / 9", selection: lockedByEngine == nil ? setting(\.direct3D9Backend) : .constant(effective.direct3D9Backend)) {
                    ForEach(Direct3D9Backend.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            ToggleRow(title: "cnc-ddraw for DirectDraw", detail: "Fixes many classic 2D games (DirectDraw 1–7).",
                      isOn: lockedByEngine == nil ? setting(\.cncDDraw) : .constant(false))
        }

        SettingsCard(title: "Display", symbol: "display", tint: .cyan) {
            if game.settings.retinaMode { StatusPill(text: "Retina", symbol: "sparkles", tint: .cyan) }
        } content: {
            ToggleRow(title: "High resolution (Retina) mode", detail: "Renders at full pixel density. Sharper, but heavier on the GPU.",
                      isOn: setting(\.retinaMode))
            RowDivider()
            ToggleRow(title: "Metal performance HUD", detail: "Shows FPS, frame time and GPU memory.", isOn: setting(\.metalHUD))
            RowDivider()
            ToggleRow(title: "Font smoothing", isOn: setting(\.fontSmoothing))
        }

        ShaderCacheCard(gameID: gameID, isCaching: effective.direct3DBackend == .dxmt || usesVulkan)

        let vulkanLock: String? = usesVulkan ? nil
            : lacksRendererHooks ? "\(engine?.displayName ?? "This engine") doesn't use Vulkan."
            : "Not in use. Choose DXVK or D9VK above to draw through Vulkan."
        SettingsCard(title: "Vulkan", symbol: "flame.fill", tint: .red, subtitle: "DXVK and D9VK",
                     footer: "Automatic picks the 3.x builds with KosmicKrisp, and DXVK 1.10 / D9VK 2.3 with MoltenVK, which lacks the Vulkan 1.3 features 3.x needs.",
                     locked: vulkanLock) {
            StatusPill(text: usesVulkan ? "In use" : "Not in use", symbol: usesVulkan ? "checkmark.circle.fill" : nil,
                       tint: usesVulkan ? .green : .secondary)
        } content: {
            SettingRow(title: "Vulkan driver") {
                Picker("Vulkan driver", selection: setting(\.vulkanDriver)) {
                    ForEach(VulkanDriver.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            SettingRow(title: "DXVK / D9VK version") {
                Picker("DXVK / D9VK version", selection: setting(\.dxvkVersion)) {
                    ForEach(DXVKVersion.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            RowDivider()
            ToggleRow(title: "Asynchronous shader compilation", detail: "Reduces stutter while shaders compile, at the cost of brief visual glitches.",
                      isOn: setting(\.dxvkAsync))
            RowDivider()
            SettingRow(title: "DXVK HUD") {
                Picker("DXVK HUD", selection: setting(\.dxvkHUD)) {
                    ForEach(DXVKHUD.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            ToggleRow(title: "MoltenVK fast math",
                      detail: game.settings.vulkanDriver == .moltenVK ? nil : "Only affects MoltenVK.",
                      isOn: game.settings.vulkanDriver == .moltenVK ? setting(\.moltenVKFastMath) : .constant(false))
                .disabled(game.settings.vulkanDriver != .moltenVK)
        }
    }

    private var usesVulkan: Bool { effective.direct3DBackend == .dxvk || effective.direct3D9Backend == .d9vk }

    private func stages(for backend: Direct3DBackend) -> [String] {
        switch backend {
        case .wined3d: ["WineD3D", "OpenGL"]
        case .dxmt: ["DXMT", "Metal"]
        case .dxvk: ["DXVK", "Vulkan", game.settings.vulkanDriver.shortTitle, "Metal"]
        case .d3dmetal: ["D3DMetal", "Metal"]
        }
    }

    private func stages(for backend: Direct3D9Backend) -> [String] {
        switch backend {
        case .wined3d: ["WineD3D", "OpenGL"]
        case .d9vk: ["D9VK", "Vulkan", game.settings.vulkanDriver.shortTitle, "Metal"]
        }
    }

    private func tags(for backend: Direct3DBackend, api: GraphicsAPI?) -> [(String, Color)] {
        switch backend {
        case .d3dmetal:
            var tags = [("64-bit only", report?.is64Bit == false ? Color.orange : .secondary)]
            if api == .d3d12 { tags.append(("Runs DX12", .green)) }
            return tags
        case .dxmt where api == .d3d11 || api == .d3d10:
            return [("Good fit", .green)]
        default:
            return []
        }
    }

    // MARK: Performance

    @ViewBuilder
    private var performance: some View {
        let sync = launcher?.settings ?? game.settings
        SettingsCard(title: "Synchronization", symbol: "arrow.triangle.2.circlepath", tint: .green,
                     subtitle: "How Wine coordinates the game's threads",
                     locked: launcher.map { "Follows \($0.name), since every process in a prefix must use the same mode." }) {
            StatusPill(text: sync.msync ? "MSync" : sync.esync ? "ESync" : "Off", tint: sync.msync || sync.esync ? .green : .secondary)
        } content: {
            ToggleRow(title: "MSync", detail: "Mach-port based synchronization. Usually the fastest option on macOS.",
                      isOn: launcher == nil ? setting(\.msync) : .constant(sync.msync))
            RowDivider()
            ToggleRow(title: "ESync", detail: "Eventfd-style synchronization. Fallback when MSync is off.",
                      isOn: launcher == nil ? setting(\.esync) : .constant(sync.esync))
        }

        SettingsCard(title: "CPU", symbol: "cpu.fill", tint: .gray, subtitle: "Rosetta 2 translates the game's Intel code") {
            StatusPill(text: "Rosetta 2", tint: .secondary)
        } content: {
            ToggleRow(title: "Advertise AVX to games",
                      detail: isWin32Engine ? "Not available with \(engine?.displayName ?? "this engine"), which crashes when Rosetta advertises AVX."
                                            : "Lets games that require AVX start under Rosetta 2.",
                      isOn: isWin32Engine ? .constant(false) : setting(\.advertiseAVX))
                .disabled(isWin32Engine)
        }

        SettingsCard(title: "32-bit games", symbol: "memorychip.fill", tint: .orange, subtitle: "Helpers for old games on Apple Silicon",
                     footer: "WineRosetta places winerosetta as d3d9.dll next to the game (and D9VK as d9vk.dll when Direct3D 8/9 uses D9VK). Anything already there is moved aside and put back when you turn it off.") {
            if let report {
                StatusPill(text: report.is64Bit ? "64-bit game" : "32-bit game", symbol: "cpu", tint: report.is64Bit ? .secondary : .orange)
            }
        } content: {
            ToggleRow(title: "WineRosetta", detail: "Emulates the instructions Rosetta 2 can't run in 32-bit World of Warcraft (1.12.1, 2.4.3, 3.3.5a).",
                      isOn: setting(\.wineRosetta))
            if game.settings.wineRosetta, report?.is64Bit == true {
                NoticeRow("This executable isn't 32-bit, so WineRosetta won't help it.")
            }
            RowDivider()
            ToggleRow(title: "rosettax87",
                      detail: lacksRosettaX87 ? "Not available with \(engine?.displayName ?? "this engine"), which can't start games through rosettax87."
                                              : "Replaces Rosetta's slow x87 math with a fast version, often many times faster in old 32-bit games. The first time, macOS may ask to allow Developer Tools access.",
                      badge: "Experimental",
                      isOn: lacksRosettaX87 ? .constant(false) : setting(\.rosettaX87))
                .disabled(lacksRosettaX87)
        }
    }

    // MARK: Input

    @ViewBuilder
    private var input: some View {
        let settings = game.settings
        SettingsCard(title: "Keyboard", symbol: "keyboard.fill", tint: .brown, subtitle: "Mac modifier keys inside the game") {
            let mapped = [settings.commandAsControl, settings.optionAsAlt].filter { $0 }.count
            StatusPill(text: mapped == 0 ? "Mac layout" : "\(mapped) remapped", tint: mapped == 0 ? .secondary : .brown)
        } content: {
            HStack(spacing: 36) {
                keyMapping(from: KeyCap(symbol: "⌘", label: "command", lit: settings.commandAsControl, tint: .brown),
                           to: KeyCap(symbol: "Ctrl", label: "windows", lit: settings.commandAsControl, tint: .brown),
                           on: settings.commandAsControl)
                keyMapping(from: KeyCap(symbol: "⌥", label: "option", lit: settings.optionAsAlt, tint: .brown),
                           to: KeyCap(symbol: "Alt", label: "windows", lit: settings.optionAsAlt, tint: .brown),
                           on: settings.optionAsAlt)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: settings.commandAsControl)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: settings.optionAsAlt)
            RowDivider()
            ToggleRow(title: "Command keys act as Control", detail: "Handy for games with Ctrl-heavy shortcuts.", isOn: setting(\.commandAsControl))
            RowDivider()
            ToggleRow(title: "Option keys act as Alt", detail: "Needed for Alt-key bindings and Alt+Enter.", isOn: setting(\.optionAsAlt))
        }

        ControllersCard(useMFi: Binding(get: { !game.settings.disableMFiControllers },
                                        set: { value in library.update(gameID) { $0.settings.disableMFiControllers = !value } }))
    }

    private func keyMapping(from: KeyCap, to: KeyCap, on: Bool) -> some View {
        HStack(spacing: 10) {
            from
            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(on ? AnyShapeStyle(Color.brown) : AnyShapeStyle(.tertiary))
                .opacity(on ? 1 : 0.5)
            to.opacity(on ? 1 : 0.55)
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advanced: some View {
        LoggingCard(gameID: gameID, showLog: actions.showLog)

        SettingsCard(title: "Prefix components", symbol: "shippingbox.fill", tint: .indigo,
                     footer: "Applies when the prefix is created or reset, and disables the components at launch.") {
            let skipped = [game.settings.skipMono, game.settings.skipGecko].filter { $0 }.count
            if skipped > 0 { StatusPill(text: "\(skipped) skipped", tint: .indigo) }
        } content: {
            ToggleRow(title: "Skip Wine Mono (.NET)", isOn: setting(\.skipMono))
            RowDivider()
            ToggleRow(title: "Skip Wine Gecko (HTML)", isOn: setting(\.skipGecko))
        }

        let links = library.linkHandlers.filter { $0.gameIDs.contains(gameID) }
        if !links.isEmpty {
            SettingsCard(title: "Links", symbol: "link", tint: .blue,
                         footer: "Browser sign-ins that end with these links are handed back to this game.") {
                StatusPill(text: "\(links.count)", tint: .blue)
            } content: {
                ForEach(Array(links.enumerated()), id: \.element.id) { index, handler in
                    if index > 0 { RowDivider() }
                    LinkHandlerRow(handler: handler)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }

        DLLOverridesCard(gameID: gameID)
        EnvironmentCard(gameID: gameID)
        IniEditsCard(gameID: gameID)

        SettingsCard(title: "Share settings", symbol: "square.and.arrow.up.fill", tint: .blue, subtitle: "Pass this setup on to someone else",
                     footer: "A settings file carries the renderer, sync, display, input and system settings, launch arguments, the engine and the Winetricks components installed here. Paths and play history stay on this Mac.") {
        } content: {
            SettingRow(title: "Export settings", detail: "Saves a .notwindows file anyone can import.") {
                Button("Export…") { SettingsTransfer.export(game, library: library) }
            }
            RowDivider()
            SettingRow(title: "Import settings", detail: "Replaces these settings with the ones in a file.") {
                Button("Import…") { SettingsTransfer.chooseAndImport(into: game, library: library) }
            }
        }

        SettingsCard(title: "Danger zone", symbol: "exclamationmark.triangle.fill", tint: .red) {
        } content: {
            if game.externalPrefixPath == nil {
                SettingRow(title: "Reset prefix", detail: "Moves the prefix, with everything installed in it and its save files, to the Trash and creates a fresh one.") {
                    Button("Reset Prefix…", role: .destructive) { confirmReset() }
                        .disabled(([game] + library.prefixMates(of: game)).contains { library.state(of: $0.id).isBusy })
                }
                RowDivider()
            }
            SettingRow(title: "Remove from library", detail: "Moves this game's notwindows settings to the Trash.") {
                Button("Remove…", role: .destructive) {
                    RemoveGameConfirmation.present(game: game, library: library) { navigation.selection = .allGames }
                }
            }
        }
    }

    // MARK: Helpers

    private func textRow(_ title: String, text: Binding<String>, prompt: String? = nil) -> some View {
        SettingRow(title: title) {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 320)
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

// MARK: - Presentation

enum GraphicsAPI {
    case d3d12, d3d11, d3d10, d3d9, d3d8, directDraw, vulkan, openGL

    var title: String {
        switch self {
        case .d3d12: "DirectX 12"
        case .d3d11: "DirectX 11"
        case .d3d10: "DirectX 10"
        case .d3d9: "DirectX 9"
        case .d3d8: "DirectX 8"
        case .directDraw: "DirectDraw"
        case .vulkan: "Vulkan"
        case .openGL: "OpenGL"
        }
    }

    var isModernDirect3D: Bool { self == .d3d10 || self == .d3d11 || self == .d3d12 }
}

extension ExecutableReport {
    /// The newest graphics API the executable links against.
    var graphicsAPI: GraphicsAPI? {
        if imports.contains("d3d12.dll") { return .d3d12 }
        if imports.contains("d3d11.dll") { return .d3d11 }
        if imports.contains("d3d10.dll") || imports.contains("d3d10_1.dll") || imports.contains("d3d10core.dll") { return .d3d10 }
        if imports.contains("d3d9.dll") { return .d3d9 }
        if imports.contains("d3d8.dll") { return .d3d8 }
        if imports.contains("ddraw.dll") { return .directDraw }
        if imports.contains("vulkan-1.dll") { return .vulkan }
        if imports.contains("opengl32.dll") { return .openGL }
        return nil
    }
}

extension Direct3DBackend {
    var shortTitle: String {
        switch self {
        case .wined3d: "WineD3D"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        case .d3dmetal: "D3DMetal"
        }
    }

    var api: String {
        switch self {
        case .wined3d: "OpenGL"
        case .dxmt: "Metal"
        case .dxvk: "Vulkan"
        case .d3dmetal: "Apple GPTK"
        }
    }

    var symbol: String {
        switch self {
        case .wined3d: "cube.transparent"
        case .dxmt: "bolt.fill"
        case .dxvk: "flame.fill"
        case .d3dmetal: "apple.logo"
        }
    }
}

extension VulkanDriver {
    var shortTitle: String {
        switch self {
        case .moltenVK: "MoltenVK"
        case .kosmicKrisp: "KosmicKrisp"
        }
    }
}

extension GameLibrary {
    /// Recommended Smart Setup changes the game doesn't have yet.
    func pendingSuggestionCount(_ id: UUID) -> Int {
        guard let report = compatReports[id], let game = game(id) else { return 0 }
        let state = compatState(id)
        return report.suggestions.filter { $0.recommended && !$0.action.isSatisfied(by: game, state: state) }.count
    }
}

// MARK: - Cards

private struct ExecutablePickerCard: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let candidates = library.candidates[gameID]
        SettingsCard(title: "Choose the game's executable", symbol: "questionmark.app.dashed", tint: .orange,
                     subtitle: candidates.map { "\($0.count) found in the prefix" }) {
            if candidates != nil {
                Button("Rescan") { library.scanForExecutables(gameID) }
                    .buttonStyle(.link)
            }
        } content: {
            if let candidates {
                if candidates.isEmpty {
                    SettingRow(title: "No executables found yet", detail: "Use Choose… below, or run the installer again from Tools › Run Program in Prefix.")
                }
                ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { RowDivider() }
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
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                SettingRow(title: "This game doesn't have an executable yet.") {
                    Button("Scan Prefix") { library.scanForExecutables(gameID) }
                }
            }
        }
    }

    private func relativePath(_ url: URL) -> String {
        guard let drive = library.game(gameID)?.driveC.path, url.path.hasPrefix(drive) else { return url.path }
        return "C:" + url.deletingLastPathComponent().path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
    }
}

/// Nudges toward Smart Setup when there are recommended changes the game doesn't have yet.
private struct SmartSetupBanner: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let pending = library.pendingSuggestionCount(gameID)
        if library.compatLoading.contains(gameID) {
            banner {
                ProgressView().controlSize(.small)
                Text("Looking up fixes for this game…").foregroundStyle(.secondary)
                Spacer()
            }
        } else if pending > 0 || library.compatReports[gameID] == nil {
            banner {
                SymbolTile(symbol: "sparkles", tint: .purple, size: 36)
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
        }
    }

    private func banner(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 12, content: content)
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color.purple.opacity(0.17), Color.indigo.opacity(0.07)], startPoint: .leading, endPoint: .trailing))
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.purple.opacity(0.28)))
    }
}

private struct PrefixCard: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID
    let showWinetricks: () -> Void
    @State private var size: Int64?
    @State private var verbs: [String] = []

    var body: some View {
        if let game = library.game(gameID) {
            let guests = game.externalPrefixPath == nil ? library.prefixMates(of: game) : []
            let exists = game.isPrefixInitialized
            SettingsCard(title: "Prefix", symbol: "externaldrive.fill", tint: .teal,
                         subtitle: exists ? (game.isPrefix32Bit == true ? "32-bit Windows" : "64-bit Windows") : "Created on first launch") {
                if exists {
                    StatusPill(text: size.map(Format.bytes) ?? "Measuring…", symbol: "internaldrive", tint: .teal)
                }
            } content: {
                SettingRow(title: "Location", detail: game.prefixURL.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    Button("Open C: Drive") { NSWorkspace.shared.open(game.driveC) }
                        .disabled(!game.driveC.exists)
                }
                if let owner = library.prefixOwner(of: game) {
                    RowDivider()
                    SettingRow(title: "Shared", detail: "Uses \(owner.name)'s prefix.")
                } else if game.externalPrefixPath?.contains(".app/") == true {
                    RowDivider()
                    SettingRow(title: "Imported wrapper", detail: "The prefix lives inside the original app bundle.")
                } else if game.externalPrefixPath != nil {
                    RowDivider()
                    SettingRow(title: "Existing prefix", detail: "Uses a prefix folder from outside notwindows.")
                }
                if !guests.isEmpty {
                    RowDivider()
                    SettingRow(title: "Shared with", detail: guests.map(\.name).formatted(.list(type: .and)))
                }
                RowDivider()
                SettingRow(title: "Installed with Winetricks",
                           detail: verbs.isEmpty ? "Nothing yet." : verbs.joined(separator: ", ")) {
                    Button("Winetricks…", action: showWinetricks)
                }
            }
            .task(id: game.prefixURL) { await measure(game.prefixURL) }
        }
    }

    /// Walking a big prefix takes a while, so a size measured in the last minute is reused when switching tabs.
    @MainActor private static var measured: [URL: (size: Int64, at: Date)] = [:]

    private func measure(_ prefix: URL) async {
        verbs = WinetricksCatalog.installedVerbs(in: prefix)
        if let cached = Self.measured[prefix] {
            size = cached.size
            if cached.at.timeIntervalSinceNow > -60 { return }
        }
        let total = await Task.detached(priority: .utility) { FileManager.default.allocatedSize(of: prefix) }.value
        Self.measured[prefix] = (total, Date())
        size = total
    }
}

private struct SteamLauncherCard: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let gameID: UUID

    var body: some View {
        let games = library.steamGames(of: gameID)
        SettingsCard(title: "Steam Library", symbol: "cloud.fill", tint: .blue,
                     subtitle: games.isEmpty ? "No games yet" : "\(games.count) installed game\(games.count == 1 ? "" : "s")",
                     footer: "Games installed through this Steam appear in your library and the sidebar. Playing one starts Steam in the background, then runs the game with its own settings.") {
            Button("Sync Now") { library.syncSteamLibrary(gameID) }
                .buttonStyle(.link)
        } content: {
            if games.isEmpty {
                SettingRow(title: "No installed games found yet", detail: "Install games in Steam and they'll show up here automatically, each with its own settings.")
            } else {
                ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                    if index > 0 { RowDivider() }
                    Button {
                        navigation.selection = .game(game.id)
                    } label: {
                        HStack(spacing: 10) {
                            GameIconView(icon: library.icons[game.id], size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(game.name).foregroundStyle(.primary)
                                Text(game.executablePath.isEmpty ? "No executable" : Format.relative(game.lastPlayedAt))
                                    .font(.caption)
                                    .foregroundStyle(game.executablePath.isEmpty ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SteamGameCard: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let gameID: UUID

    var body: some View {
        let game = library.game(gameID)
        SettingsCard(title: "Steam", symbol: "cloud.fill", tint: .blue,
                     footer: "Play starts Steam in the background if needed, then launches the game directly so its own settings apply. A steam_appid.txt is added next to the executable so the game doesn't restart through the Steam client.") {
            if let appID = game?.steamAppID {
                Link(destination: URL(string: "https://store.steampowered.com/app/\(appID)")!) {
                    StatusPill(text: "App \(appID)", symbol: "arrow.up.right", tint: .blue)
                }
                .help("Open in the Steam store")
            }
        } content: {
            if let launcher = game.flatMap({ library.launcher(of: $0) }) {
                SettingRow(title: "Installed through") {
                    Button(launcher.name) { navigation.selection = .game(launcher.id) }
                        .buttonStyle(.link)
                }
            }
            if let folder = game?.installDirectory {
                RowDivider()
                SettingRow(title: "Install folder", detail: (folder as NSString).abbreviatingWithTildeInPath) {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                }
            }
        }
    }
}

private struct ShaderCacheCard: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID
    let isCaching: Bool
    @State private var size: Int64?

    var body: some View {
        SettingsCard(title: "Shader cache", symbol: "square.stack.3d.up.fill", tint: .mint,
                     footer: "Shaders are compiled the first time a game needs them, which causes the stutter on first launch or in new areas. Clear only if a game shows graphics glitches after an update.") {
            StatusPill(text: size.map { $0 == 0 ? "Empty" : Format.bytes($0) } ?? "…", symbol: "internaldrive", tint: .mint)
        } content: {
            SettingRow(title: "This game's cache",
                       detail: isCaching ? "DXMT and DXVK keep compiled shaders here; macOS also caches Metal shaders for all games."
                                         : "The current renderer doesn't keep a cache here; macOS still caches Metal shaders for all games.") {
                Button("Clear") { clear() }
                    .disabled((size ?? 0) == 0 || library.state(of: gameID).isBusy)
            }
        }
        .task { refresh() }
    }

    private var folder: URL? { library.game(gameID)?.cacheDirectory }

    private func refresh() {
        guard let folder else { return }
        Task {
            size = await Task.detached(priority: .utility) { FileManager.default.allocatedSize(of: folder) }.value
        }
    }

    private func clear() {
        guard let folder else { return }
        try? FileManager.default.removeItem(at: folder)
        refresh()
    }
}

private struct ControllersCard: View {
    @Binding var useMFi: Bool
    @State private var controllers: [GCController] = GCController.controllers()

    var body: some View {
        SettingsCard(title: "Controllers", symbol: "gamecontroller.fill", tint: .green) {
            StatusPill(text: controllers.isEmpty ? "None connected" : "\(controllers.count) connected",
                       symbol: controllers.isEmpty ? nil : "dot.radiowaves.left.and.right",
                       tint: controllers.isEmpty ? .secondary : .green)
        } content: {
            ForEach(Array(controllers.enumerated()), id: \.offset) { _, controller in
                SettingRow(title: controller.vendorName ?? "Controller", detail: controller.productCategory) {
                    if let battery = controller.battery {
                        Label("\(Int(battery.batteryLevel * 100))%", systemImage: batterySymbol(battery.batteryLevel))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                RowDivider()
            }
            ToggleRow(title: "Use the MFi controller API", detail: "Off routes controllers through IOKit/HID, which works better for most games.",
                      isOn: $useMFi)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in controllers = GCController.controllers() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in controllers = GCController.controllers() }
    }

    private func batterySymbol(_ level: Float) -> String {
        switch level {
        case ..<0.2: "battery.0percent"
        case ..<0.45: "battery.25percent"
        case ..<0.7: "battery.50percent"
        case ..<0.9: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct LoggingCard: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID
    let showLog: () -> Void

    var body: some View {
        let game = library.game(gameID)
        let level = library.setting(gameID, \.logLevel)
        let attributes = game.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.lastLogURL.path) }
        SettingsCard(title: "Logging", symbol: "text.alignleft", tint: .gray) {
            StatusPill(text: level.wrappedValue.title, tint: level.wrappedValue == .off ? .secondary : .gray)
        } content: {
            SettingRow(title: "Wine log level", detail: level.wrappedValue == .verbose ? "Verbose logs slow games down; turn it back off once you're done." : nil) {
                Picker("Wine log level", selection: level) {
                    ForEach(WineLogLevel.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            RowDivider()
            SettingRow(title: "Last run", detail: attributes.map(logSummary) ?? "No log yet.") {
                Button("Show Log", action: showLog)
                    .disabled(attributes == nil)
            }
        }
    }

    private func logSummary(_ attributes: [FileAttributeKey: Any]) -> String {
        let size = (attributes[.size] as? NSNumber).map { Format.bytes($0.int64Value) } ?? ""
        let date = (attributes[.modificationDate] as? Date).map { Format.relative($0) } ?? ""
        return [size, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct DLLOverridesCard: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let overrides = library.setting(gameID, \.dllOverrides)
        SettingsCard(title: "DLL overrides", symbol: "puzzlepiece.extension.fill", tint: .purple,
                     footer: "Passed to Wine as WINEDLLOVERRIDES. Use native for DLLs you've dropped next to the game.") {
            if !overrides.wrappedValue.isEmpty { StatusPill(text: "\(overrides.wrappedValue.count)", tint: .purple) }
        } content: {
            ForEach(overrides) { $item in
                HStack {
                    TextField("DLL", text: $item.name, prompt: Text("d3dcompiler_47"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                RowDivider()
            }
            Button {
                overrides.wrappedValue.append(DLLOverride(name: "", mode: .nativeThenBuiltin))
            } label: {
                Label("Add Override", systemImage: "plus")
            }
            .buttonStyle(.link)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }
}

private struct EnvironmentCard: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        let variables = library.setting(gameID, \.environment)
        SettingsCard(title: "Environment variables", symbol: "terminal.fill", tint: .teal,
                     footer: "Applied last, so they override anything notwindows sets.") {
            if !variables.wrappedValue.isEmpty { StatusPill(text: "\(variables.wrappedValue.count)", tint: .teal) }
        } content: {
            ForEach(variables) { $item in
                HStack {
                    TextField("Name", text: $item.key, prompt: Text("NAME"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Text("=").foregroundStyle(.secondary)
                    TextField("Value", text: $item.value, prompt: Text("value"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Button {
                        variables.wrappedValue.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                RowDivider()
            }
            Button {
                variables.wrappedValue.append(EnvironmentVariable(key: "", value: ""))
            } label: {
                Label("Add Variable", systemImage: "plus")
            }
            .buttonStyle(.link)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }
}

/// The .ini changes Smart Setup made, and whether they're still in place.
private struct IniEditsCard: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    var body: some View {
        if let game = library.game(gameID), !game.settings.iniEdits.isEmpty {
            let edits = game.settings.iniEdits
            let state = library.compatState(gameID)
            SettingsCard(title: "Game files", symbol: "doc.badge.gearshape.fill", tint: .orange, subtitle: "Changes made to the game's .ini files",
                         footer: "The first change to a file keeps the original next to it with a .notwindows-backup extension. Removing a change from this list leaves the file as it is.") {
                StatusPill(text: "\(edits.count)", tint: .orange)
            } content: {
                ForEach(Array(edits.enumerated()), id: \.element.id) { index, edit in
                    if index > 0 { RowDivider() }
                    let status = status(of: edit, in: game, state: state)
                    SettingRow(title: "\(edit.setting.key) = \(state.expand(edit.setting.value))",
                               detail: "\(edit.setting.fileName) · [\(edit.setting.section)]", badge: status.text, badgeTint: status.tint) {
                        HStack(spacing: 10) {
                            if status.canReapply {
                                Button("Apply Again") {
                                    library.update(gameID) { game in
                                        if let i = game.settings.iniEdits.firstIndex(where: { $0.id == edit.id }) { game.settings.iniEdits[i].isPending = true }
                                    }
                                    library.applyIniEdits(gameID)
                                }
                                .controlSize(.small)
                            }
                            Button {
                                library.update(gameID) { $0.settings.iniEdits.removeAll { $0.id == edit.id } }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from the list")
                        }
                    }
                }
            }
        }
    }

    private func status(of edit: IniEdit, in game: Game, state: CompatState) -> (text: String, tint: Color, canReapply: Bool) {
        if edit.isPending { return ("Waits for the game to create the file", .orange, false) }
        if CompatAction.iniSetting(edit.setting).isSatisfied(by: game, state: state) { return ("Applied", .green, false) }
        return ("Changed since", .secondary, true)
    }
}

extension FileManager {
    /// Disk space taken by everything under `url`, or 0 if it doesn't exist.
    func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
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
