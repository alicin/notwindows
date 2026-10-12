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

    /// Running games, most recently started first.
    private var runningGames: [Game] {
        library.games
            .compactMap { game -> (Game, Date)? in
                if case .running(let since) = library.state(of: game.id) { (game, since) } else { nil }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        @Bindable var navigation = navigation
        let running = runningGames

        List(selection: $navigation.selection) {
            Section {
                SmartListRow(filter: .all, isSelected: navigation.selection == .allGames)
                    .badge(library.games.count)
                    .tag(SidebarItem.allGames)
                SmartListRow(filter: .favorites, isSelected: navigation.selection == .favorites)
                    .tag(SidebarItem.favorites)
                SmartListRow(filter: .recent, isSelected: navigation.selection == .recent)
                    .tag(SidebarItem.recent)
            } header: {
                SidebarHeader(title: "Library")
            }

            let ownGames = filteredGames.filter { $0.launcherID == nil }
            Section {
                ForEach(ownGames) { game in
                    gameRow(game)
                }
            } header: {
                SidebarHeader(title: "Games", count: ownGames.isEmpty ? nil : ownGames.count)
            }

            ForEach(library.games.filter(\.isSteamLauncher)) { launcher in
                let children = filteredGames.filter { $0.launcherID == launcher.id }
                if !children.isEmpty {
                    Section {
                        ForEach(children) { game in
                            gameRow(game)
                        }
                    } header: {
                        SidebarHeader(title: "\(launcher.name) Library", count: children.count) {
                            if let icon = library.icons[launcher.id] {
                                GameIconView(icon: icon, size: 14)
                            } else {
                                Image(systemName: "cloud.fill")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if !running.isEmpty {
                NowPlayingCard(running: running)
                    .padding(10)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: running.map(\.id))
        #if DEBUG || DEBUG_HOOKS
        .onAppear { DebugSnapshots.openSettings = { openSettings() } }
        #endif
    }

    private func gameRow(_ game: Game) -> some View {
        SidebarGameRow(game: game, icon: library.icons[game.id], palette: library.palettes[game.id],
                       state: library.state(of: game.id), isSelected: navigation.selection == .game(game.id))
            .tag(SidebarItem.game(game.id))
            .contextMenu { GameContextMenu(game: game) }
    }
}

/// Section titles in small arcade-style caps, with a count where it helps.
private struct SidebarHeader<Icon: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(title.uppercased())
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .tracking(1)
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.top, 4)
    }
}

extension SidebarHeader where Icon == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

private struct SmartListRow: View {
    let filter: LibraryFilter
    let isSelected: Bool
    @State private var bounce = 0
    @State private var hovering = false

    var body: some View {
        Label {
            Text(filter.title)
        } icon: {
            SymbolTile(symbol: filter.symbol, tint: filter.tint, bounce: bounce)
                .liftedIcon(hovering || isSelected)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { hovering = h } }
        .onChange(of: isSelected) { _, selected in
            if selected { bounce += 1 }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isSelected)
    }
}

private extension View {
    /// The zoomed, tilted pose sidebar icons take while hovered or selected.
    func liftedIcon(_ lifted: Bool) -> some View {
        modifier(LiftedIcon(lifted: lifted))
    }
}

private struct LiftedIcon: ViewModifier {
    let lifted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(lifted && !reduceMotion ? 1.14 : 1)
            .rotationEffect(.degrees(lifted && !reduceMotion ? -7 : 0))
    }
}

private struct SidebarGameRow: View {
    let game: Game
    let icon: NSImage?
    let palette: IconPalette?
    let state: RunState
    let isSelected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pop = 0

    var body: some View {
        Label {
            HStack {
                Text(game.name).lineLimit(1)
                Spacer(minLength: 4)
                switch state {
                case .running:
                    PixelInvader()
                        .help("Running")
                        .transition(.scale.combined(with: .opacity))
                case .preparing:
                    ProgressView().controlSize(.mini)
                case .idle where game.isFavorite:
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.yellow)
                        .transition(.scale.combined(with: .opacity))
                case .idle:
                    EmptyView()
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: game.isFavorite)
        } icon: {
            GameIconView(icon: icon, size: 22)
                .shadow(color: (palette?.glow ?? .accentColor).opacity(isSelected ? 0.9 : 0), radius: 5)
                .liftedIcon(hovering || isSelected)
                .phaseAnimator([1, 1.3], trigger: pop) { content, scale in
                    content.scaleEffect(scale)
                } animation: { scale in
                    scale == 1 ? .spring(response: 0.4, dampingFraction: 0.45) : .spring(response: 0.14, dampingFraction: 0.9)
                }
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { hovering = h } }
        .onChange(of: isSelected) { _, selected in
            if selected && !reduceMotion { pop += 1 }
        }
        .onChange(of: state.isRunning) { _, running in
            if running && !reduceMotion { pop += 1 }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isSelected)
    }
}

/// Mini player for whatever is running, drawn from the game's own artwork.
private struct NowPlayingCard: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let running: [Game]
    @State private var hovering = false

    var body: some View {
        let lead = running[0]
        let stack = Array(running.prefix(3).enumerated())
        let palette = library.palettes[lead.id]

        HStack(spacing: 10) {
            ZStack(alignment: .leading) {
                ForEach(stack.reversed(), id: \.element.id) { index, game in
                    GameIconView(icon: library.icons[game.id], size: 32)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .rotationEffect(.degrees(Double(index) * 8))
                        .offset(x: CGFloat(index) * 10)
                }
            }
            .frame(width: 32 + CGFloat(stack.count - 1) * 10, alignment: .leading)
            .scaleEffect(hovering ? 1.08 : 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    PixelInvader(pixel: 1, color: .white)
                    Text(running.count == 1 ? "NOW PLAYING" : "\(running.count) RUNNING")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(running.count == 1 ? lead.name : running.map(\.name).formatted(.list(type: .and)))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if running.count == 1, case .running(let since) = library.state(of: lead.id) {
                    Text(since, style: .timer)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            Spacer(minLength: 0)

            Button {
                if running.count == 1 { library.stop(lead.id) } else { library.stopAll() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.2), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(running.count == 1 ? "Stop \(lead.name)" : "Stop All")
        }
        .padding(10)
        .background {
            ArtworkBackground(backdrop: library.backdrops[lead.id], palette: palette)
                .scaleEffect(hovering ? 1.1 : 1)
        }
        .overlay { RunningGlow(cornerRadius: 14, lineWidth: 1.5) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .shadow(color: (palette?.primary ?? .black).opacity(0.4), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { h in withAnimation(.smooth(duration: 0.4)) { hovering = h } }
        .onTapGesture { navigation.selection = .game(lead.id) }
        .contextMenu { GameContextMenu(game: lead) }
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
            let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            shape
                .fill(LinearGradient(colors: [IconPalette.fallback.glow, IconPalette.fallback.primary, IconPalette.fallback.secondary],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay(shape.strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
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
        let guests = game.externalPrefixPath == nil ? library.prefixMates(of: game).map(\.name) : []
        if !guests.isEmpty {
            alert.informativeText = "This game's notwindows settings will be moved to the Trash. Its Windows prefix stays, because \(guests.formatted(.list(type: .and))) \(guests.count == 1 ? "uses" : "use") it."
        } else if game.externalPrefixPath == nil {
            alert.informativeText = "The game's Windows prefix, including everything installed in it, will be moved to the Trash."
        } else if game.externalPrefixPath?.contains(".app/") == true {
            alert.informativeText = "This game's notwindows settings will be moved to the Trash. The imported wrapper is left untouched."
        } else {
            alert.informativeText = "This game's notwindows settings will be moved to the Trash. The prefix it runs in is left untouched."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        library.remove(game)
        onRemoved()
    }
}
