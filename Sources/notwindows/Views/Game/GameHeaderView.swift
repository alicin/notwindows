import SwiftUI
import UniformTypeIdentifiers

struct GameHeaderView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(AppNavigation.self) private var navigation

    let game: Game
    let showWinetricks: () -> Void
    let showLog: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        let state = library.state(of: game.id)
        let icon = library.icons[game.id]
        let palette = library.palettes[game.id]

        HStack(alignment: .center, spacing: 26) {
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

            VStack(alignment: .leading, spacing: 8) {
                Text(game.name)
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(spacing: 8) {
                    chip("clock", state.isRunning && game.totalPlaytime == 0 ? "First session" : Format.playtime(game.totalPlaytime))
                    chip("calendar", state.isRunning ? "Playing now" : Format.relative(game.lastPlayedAt))
                    chip("cpu", (engines.engine(named: game.engineName)?.displayName) ?? "No engine")
                    chip("cube.transparent", game.settings.direct3DBackend.title)
                }

                HStack(spacing: 10) {
                    PlayControl(game: game, tint: .white, foreground: .black.opacity(0.85))

                    Menu {
                        Section("Windows Tools") {
                            ForEach(WineTool.allCases) { tool in
                                Button(tool.title, systemImage: tool.symbol) { library.open(tool, for: game.id) }
                            }
                        }
                        Section {
                            Button("Winetricks…", systemImage: "wand.and.stars", action: showWinetricks)
                            Button("Run Program in Prefix…", systemImage: "play.rectangle") {
                                if let url = Panels.chooseFile(message: "Choose a program to run inside \(game.name)'s prefix", types: Panels.windowsExecutableTypes, directory: game.driveC) {
                                    library.runInPrefix(url, for: game.id)
                                }
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
                .padding(.top, 6)
            }
            .environment(\.colorScheme, .dark)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background {
            ArtworkBackground(backdrop: library.backdrops[game.id], palette: palette)
                .ignoresSafeArea()
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.white.opacity(0.14), in: Capsule())
            .contentTransition(.numericText())
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
