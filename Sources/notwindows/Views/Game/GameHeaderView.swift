import SwiftUI
import UniformTypeIdentifiers

struct GameHeaderView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(AppNavigation.self) private var navigation

    let game: Game
    let report: ExecutableReport?
    /// How far the artwork reaches up under the toolbar.
    var topBleed: CGFloat = 0
    let showWinetricks: () -> Void
    let showLog: () -> Void
    let showCompat: () -> Void

    @State private var isDropTargeted = false
    @State private var mosaic: PixelGrid?
    @State private var revealStart: Date?

    var body: some View {
        let state = library.state(of: game.id)
        let icon = library.icons[game.id]
        let palette = library.palettes[game.id]

        HStack(alignment: .center, spacing: 28) {
            GameIconView(icon: icon, size: 112)
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(isDropTargeted ? Color.white : .white.opacity(0.2), lineWidth: isDropTargeted ? 3 : 1)
                }
                .overlay {
                    if state.isRunning { RunningGlow(cornerRadius: 28, lineWidth: 2.5) }
                }
                .shadow(color: (palette?.glow ?? .black).opacity(0.55), radius: 26, y: 10)
                .scaleEffect(isDropTargeted ? 1.06 : 1)
                .tiltOnHover(maxAngle: 12, cornerRadius: 28)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDropTargeted)
                .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted, perform: dropIcon)
                .contextMenu {
                    Button("Choose Icon…") { chooseIcon() }
                    Button("Use Executable's Icon") { library.refreshIconFromExecutable(game.id) }
                        .disabled(game.executableURL == nil)
                }
                .help("Drop an image here to change the icon")

            VStack(alignment: .leading, spacing: 12) {
                tags(state)

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let company = report?.companyName?.trimmingCharacters(in: .whitespaces), !company.isEmpty, company != game.name {
                        Text(company)
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }

                stats(state)

                HStack(spacing: 10) {
                    PlayControl(game: game, tint: .white, foreground: .black.opacity(0.85))

                    Menu {
                        Section("Windows Tools") {
                            ForEach(WineTool.allCases) { tool in
                                Button(tool.title, systemImage: tool.symbol) { library.open(tool, for: game.id) }
                            }
                        }
                        Section {
                            Button("Smart Setup…", systemImage: "sparkles", action: showCompat)
                            Button("Winetricks…", systemImage: "wand.and.stars", action: showWinetricks)
                            Button("Run Program in Prefix…", systemImage: "play.rectangle") {
                                if let url = Panels.chooseFile(message: "Choose a program to run inside \(game.name)'s prefix", types: Panels.windowsExecutableTypes, directory: game.driveC) {
                                    library.runInPrefix(url, for: game.id)
                                }
                            }
                        }
                        Section {
                            Button("Export Settings…", systemImage: "square.and.arrow.up") { SettingsTransfer.export(game, library: library) }
                            Button("Import Settings…", systemImage: "square.and.arrow.down") {
                                SettingsTransfer.chooseAndImport(into: game, library: library)
                            }
                        }
                        Section {
                            Button("Open C: Drive", systemImage: "folder") { NSWorkspace.shared.open(game.driveC) }
                            Button("Show Last Log", systemImage: "doc.text.magnifyingglass", action: showLog)
                            Button("Force Quit All Processes", systemImage: "xmark.octagon") { library.stop(game.id) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Tools")

                    Button {
                        library.update(game.id) { $0.isFavorite.toggle() }
                    } label: {
                        Image(systemName: game.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(game.isFavorite ? .yellow : .white)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.2)))
                    }
                    .buttonStyle(.plain)
                    .symbolEffect(.bounce, value: game.isFavorite)
                    .help(game.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                }
                .padding(.top, 2)
            }
            .environment(\.colorScheme, .dark)
            Spacer(minLength: 0)
        }
        .formColumn()
        .padding(.top, 34)
        .padding(.bottom, 44)
        .task(id: icon.map(ObjectIdentifier.init)) {
            mosaic = icon?.pixelGrid(side: 22)
            revealStart = Date()
        }
        .background {
            ZStack {
                ArtworkBackground(backdrop: library.backdrops[game.id], palette: palette)
                if let mosaic {
                    GeometryReader { proxy in
                        PixelMosaic(grid: mosaic, revealStart: revealStart)
                            .frame(width: proxy.size.height * 1.1, height: proxy.size.height * 1.1)
                            .rotationEffect(.degrees(-8))
                            .shadow(color: (palette?.glow ?? .white).opacity(0.5), radius: 14)
                            .mask {
                                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .leading, endPoint: .trailing)
                            }
                            .opacity(0.42)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                            .offset(x: proxy.size.height * 0.12)
                    }
                    .clipped()
                }
            }
            // Fade the artwork into the page so the tabs below sit on the same surface as the settings.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            // ignoresSafeArea inside a scroll view stretches the backdrop over the whole viewport, so reach up by hand.
            .padding(.top, -topBleed)
        }
    }

    // MARK: Tags

    private struct HeaderTag: Identifiable {
        let text: String
        var symbol: String?
        var tint: Color = .white
        var id: String { text }
    }

    private func tagItems(_ state: RunState) -> [HeaderTag] {
        var items: [HeaderTag] = []
        if game.executablePath.isEmpty {
            items.append(HeaderTag(text: "No executable", symbol: "exclamationmark.triangle.fill", tint: .orange))
        }
        if let report {
            items.append(HeaderTag(text: report.is64Bit ? "64-bit" : "32-bit", symbol: "cpu"))
            if let api = report.graphicsAPI { items.append(HeaderTag(text: api.title, symbol: "cube")) }
            if let engine = report.engine { items.append(HeaderTag(text: engine.rawValue, symbol: "hammer.fill")) }
            if report.isDotNet { items.append(HeaderTag(text: ".NET")) }
        }
        if game.isSteamGame || game.isSteamLauncher {
            items.append(HeaderTag(text: "Steam", symbol: "cloud.fill"))
        }
        for name in report?.antiCheat ?? [] {
            items.append(HeaderTag(text: name, symbol: "exclamationmark.shield.fill", tint: .orange))
        }
        return items
    }

    @ViewBuilder
    private func tags(_ state: RunState) -> some View {
        let items = tagItems(state)
        if !items.isEmpty {
            // In narrow windows, drop tags from the end rather than truncating every one of them.
            ViewThatFits(in: .horizontal) {
                ForEach((1...items.count).reversed(), id: \.self) { count in
                    HStack(spacing: 6) {
                        ForEach(items.prefix(count)) { tag($0) }
                    }
                }
            }
        }
    }

    private func tag(_ item: HeaderTag) -> some View {
        HStack(spacing: 4) {
            if let symbol = item.symbol { Image(systemName: symbol) }
            Text(item.text.uppercased())
        }
        .font(.system(size: 10, weight: .heavy, design: .monospaced))
        .tracking(0.5)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(item.tint == .white ? Color.white.opacity(0.9) : item.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(item.tint == .white ? Color.white.opacity(0.14) : item.tint.opacity(0.22),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: Stats

    private func stats(_ state: RunState) -> some View {
        let engine = engines.engine(named: library.launcher(of: game)?.engineName ?? game.engineName)
        let neverPlayed = game.totalPlaytime == 0 && !state.isRunning
        let items: [(label: String, value: String)] = [
            ("PLAYED", neverPlayed ? "—" : state.isRunning && game.totalPlaytime == 0 ? "First run" : Format.playtime(game.totalPlaytime)),
            ("LAST PLAYED", state.isRunning ? "Now" : game.lastPlayedAt == nil ? "Never" : Format.relative(game.lastPlayedAt, style: .short)),
            ("ENGINE", engine?.displayName ?? "None"),
            ("RENDERER", renderer(engine)),
        ]
        // Like the tags, drop readouts from the end when the window is too narrow for all of them.
        return ViewThatFits(in: .horizontal) {
            ForEach((1...items.count).reversed(), id: \.self) { count in
                HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        if index > 0 {
                            Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 28).padding(.horizontal, 16)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(items[index].value)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .contentTransition(.numericText())
                            Text(items[index].label)
                                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                .tracking(1)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .lineLimit(1)
                        .fixedSize()
                    }
                }
            }
        }
    }

    /// The renderer this game's own graphics API ends up on.
    private func renderer(_ engine: Engine?) -> String {
        let settings = engine.map { WineEnvironment.renderers(for: game.settings, engine: $0) } ?? game.settings
        switch report?.graphicsAPI {
        case .d3d9, .d3d8: return settings.direct3D9Backend == .d9vk ? "D9VK" : "WineD3D"
        case .directDraw: return settings.cncDDraw ? "cnc-ddraw" : "WineD3D"
        case .openGL: return "OpenGL"
        case .vulkan: return settings.vulkanDriver.shortTitle
        default: return settings.direct3DBackend.shortTitle
        }
    }

    private func chooseIcon() {
        guard let url = Panels.chooseFile(message: "Choose an icon image", types: [.image, .icns]),
              let image = NSImage(contentsOf: url) else { return }
        library.setIcon(image, for: game.id)
    }

    private func dropIcon(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else { return }
                Task { @MainActor in library.setIcon(image, for: game.id) }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                let image = url.pathExtension.lowercased() == "exe" ? PEIconExtractor.image(fromExecutableAt: url) : NSImage(contentsOf: url)
                if let image { library.setIcon(image, for: game.id) }
            }
        }
        return true
    }
}
