import SwiftUI

struct SidebarView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings

    private var filteredGames: [Game] {
        let query = navigation.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return library.games }
        return library.games.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        @Bindable var navigation = navigation

        List(selection: $navigation.selection) {
            Section("Library") {
                Label("All Games", systemImage: "square.grid.2x2")
                    .badge(library.games.count)
                    .tag(SidebarItem.allGames)
                Label("Favorites", systemImage: "star")
                    .tag(SidebarItem.favorites)
                Label("Recently Played", systemImage: "clock")
                    .tag(SidebarItem.recent)
            }

            Section("Games") {
                ForEach(filteredGames) { game in
                    SidebarGameRow(game: game, icon: library.icons[game.id], state: library.state(of: game.id))
                        .tag(SidebarItem.game(game.id))
                        .contextMenu { GameContextMenu(game: game) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if library.runningCount > 0 {
                HStack {
                    PulsingDot(size: 8)
                    Text("\(library.runningCount) running")
                        .font(.callout)
                    Spacer()
                    Button("Stop All") { library.stopAll() }
                        .controlSize(.small)
                }
                .padding(10)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: library.runningCount)
        #if DEBUG
        .onAppear { DebugSnapshots.openSettings = { openSettings() } }
        #endif
    }
}

private struct SidebarGameRow: View {
    let game: Game
    let icon: NSImage?
    let state: RunState

    var body: some View {
        Label {
            HStack {
                Text(game.name).lineLimit(1)
                Spacer(minLength: 4)
                switch state {
                case .running:
                    PulsingDot(size: 7)
                        .help("Running")
                        .transition(.scale.combined(with: .opacity))
                case .preparing:
                    ProgressView().controlSize(.mini)
                case .idle:
                    EmptyView()
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state)
        } icon: {
            GameIconView(icon: icon, size: 18)
        }
    }
}

struct GameIconView: View {
    let icon: NSImage?
    var size: CGFloat

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "gamecontroller.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
                .padding(size * 0.12)
                .frame(width: size, height: size)
        }
    }
}

struct GameContextMenu: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let game: Game

    var body: some View {
        let state = library.state(of: game.id)
        if state.isBusy {
            Button("Stop", systemImage: "stop.fill") { library.stop(game.id) }
        } else {
            Button("Play", systemImage: "play.fill") { library.play(game.id) }
                .disabled(game.executablePath.isEmpty)
        }
        Button("Settings…", systemImage: "slider.horizontal.3") { navigation.selection = .game(game.id) }
        Divider()
        Button(game.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: game.isFavorite ? "star.slash" : "star") {
            library.update(game.id) { $0.isFavorite.toggle() }
        }
        Button("Open C: Drive", systemImage: "folder") { NSWorkspace.shared.open(game.driveC) }
        if let exe = game.executableURL {
            Button("Show Executable in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([exe])
            }
        }
        Divider()
        Button("Remove from Library…", systemImage: "trash", role: .destructive) {
            RemoveGameConfirmation.present(game: game, library: library) {
                if navigation.selection == .game(game.id) { navigation.selection = .allGames }
            }
        }
    }
}

enum RemoveGameConfirmation {
    @MainActor
    static func present(game: Game, library: GameLibrary, onRemoved: () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(game.name)”?"
        alert.informativeText = game.externalPrefixPath == nil
            ? "The game's Windows prefix, including everything installed in it, will be moved to the Trash."
            : "This game's notwindows settings will be moved to the Trash. The imported wrapper is left untouched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.remove(game)
        onRemoved()
    }
}
