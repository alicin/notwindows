import SwiftUI

enum LibraryFilter {
    case all, favorites, recent

    var title: String {
        switch self {
        case .all: "All Games"
        case .favorites: "Favorites"
        case .recent: "Recently Played"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .favorites: "star.fill"
        case .recent: "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .all: Color(red: 0.74, green: 0.3, blue: 0.68)
        case .favorites: .orange
        case .recent: .blue
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, lastPlayed, playtime, added
    var id: Self { self }

    var title: String {
        switch self {
        case .name: "Name"
        case .lastPlayed: "Recently Played"
        case .playtime: "Most Played"
        case .added: "Date Added"
        }
    }

    func sorted(_ games: [Game]) -> [Game] {
        games.sorted { a, b in
            switch self {
            case .lastPlayed where a.lastPlayedAt != b.lastPlayedAt: (a.lastPlayedAt ?? .distantPast) > (b.lastPlayedAt ?? .distantPast)
            case .playtime where a.totalPlaytime != b.totalPlaytime: a.totalPlaytime > b.totalPlaytime
            case .added where a.addedAt != b.addedAt: a.addedAt > b.addedAt
            default: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

/// Recently played games grouped by day, with Finder's Recents headings.
private struct RecentSection {
    let title: String
    var games: [Game]
    let offset: Int

    static func group(_ games: [Game], now: Date = Date(), calendar: Calendar = .current) -> [RecentSection] {
        var sections: [RecentSection] = []
        for (index, game) in games.enumerated() {
            let title = heading(for: game.lastPlayedAt ?? .distantPast, now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1].games.append(game)
            } else {
                sections.append(RecentSection(title: title, games: [game], offset: index))
            }
        }
        return sections
    }

    private static func heading(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }
        return "Earlier"
    }
}

struct LibraryGridView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(RuntimeManager.self) private var runtime
    @Environment(AppNavigation.self) private var navigation

    let filter: LibraryFilter
    @AppStorage("librarySort") private var sort = LibrarySort.name

    private var games: [Game] {
        var result = library.games
        switch filter {
        case .all: result = sort.sorted(result)
        case .favorites: result = sort.sorted(result.filter(\.isFavorite))
        case .recent:
            result = result.filter { $0.lastPlayedAt != nil }
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        }
        let query = navigation.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { result = result.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        return result
    }

    /// The game shown in the "Continue playing" banner: whatever is running, else the most recently played.
    private var featured: Game? {
        guard filter == .all, navigation.searchText.isEmpty, library.games.count > 1 else { return nil }
        if let running = library.games.first(where: { library.state(of: $0.id).isRunning }) { return running }
        return library.games.filter { $0.lastPlayedAt != nil && !$0.executablePath.isEmpty }
            .max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) }
    }

    private var needsSetup: Bool {
        runtime.current == nil || engines.installed.isEmpty || !runtime.isRosettaInstalled
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if needsSetup {
                    SetupView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let featured {
                    FeaturedGameBanner(game: featured)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if games.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: needsSetup ? 220 : 420)
                } else if filter == .recent {
                    ForEach(RecentSection.group(games), id: \.title) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.title)
                                .font(.title2.bold())
                            grid(section.games, startIndex: section.offset)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        if featured != nil {
                            Text("Library")
                                .font(.title2.bold())
                        }
                        grid(games)
                    }
                }
            }
            // 20pt matches the navigation title's inset, so the content lines up under it.
            .padding(20)
            .animation(.smooth(duration: 0.35), value: needsSetup)
            .animation(.smooth(duration: 0.35), value: featured?.id)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: games.map(\.id))
        }
        .navigationTitle(filter.title)
        .navigationSubtitle(games.isEmpty ? "" : "\(games.count) game\(games.count == 1 ? "" : "s")")
        .toolbar {
            if filter != .recent {
                ToolbarItem {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort By", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort by \(sort.title.lowercased())")
                }
            }
        }
    }

    private func grid(_ games: [Game], startIndex: Int = 0) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 210), spacing: 24)], spacing: 28) {
            ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                GameCard(game: game, showsPlaytime: filter != .recent && sort == .playtime)
                    .staggeredAppear(startIndex + index, id: game.id)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch filter {
        case .all where navigation.searchText.isEmpty:
            ContentUnavailableView {
                Label {
                    Text("No Games Yet")
                } icon: {
                    BreathingSymbol(name: "gamecontroller.fill")
                }
            } description: {
                Text("Add a game you've already installed, run a setup file into a fresh prefix, or bring over a Sikarugir wrapper. You can also drop an .exe anywhere in this window.")
            } actions: {
                Button("Add Installed Game…") { navigation.addGameMode = .existing }
                    .buttonStyle(.borderedProminent)
                Button("Install from Setup File…") { navigation.addGameMode = .installer }
                Button("Import Sikarugir Wrapper…") { navigation.importWrapper(into: library) }
                    .buttonStyle(.link)
            }
        case .favorites:
            ContentUnavailableView {
                Label { Text("No Favorites") } icon: { SymbolTile(symbol: filter.symbol, tint: filter.tint, size: 64) }
            } description: {
                Text("Right-click a game and choose Add to Favorites.")
            }
        case .recent:
            ContentUnavailableView {
                Label { Text("Nothing Played Yet") } icon: { SymbolTile(symbol: filter.symbol, tint: filter.tint, size: 64) }
            } description: {
                Text("Games you launch show up here.")
            }
        default:
            ContentUnavailableView.search(text: navigation.searchText)
        }
    }
}

struct BreathingSymbol: View {
    let name: String

    var body: some View {
        if #available(macOS 15.0, *) {
            Image(systemName: name).symbolEffect(.breathe)
        } else {
            Image(systemName: name).symbolEffect(.pulse)
        }
    }
}

// MARK: - Featured banner

struct FeaturedGameBanner: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let game: Game
    @State private var hovering = false

    var body: some View {
        let state = library.state(of: game.id)
        let icon = library.icons[game.id]
        let palette = library.palettes[game.id]

        HStack(spacing: 26) {
            GameIconView(icon: icon, size: 112)
                .shadow(color: (palette?.glow ?? .black).opacity(0.6), radius: 22, y: 8)
                .scaleEffect(hovering ? 1.05 : 1)
                .rotationEffect(.degrees(hovering ? -2 : 0))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if state.isRunning { PixelInvader(pixel: 1, color: .white) }
                    Text(state.isRunning ? "NOW PLAYING" : "CONTINUE PLAYING")
                        .font(.system(.caption, design: .monospaced).weight(.heavy))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.75))
                }
                Text(game.name)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 14) {
                    Label(state.isRunning && game.totalPlaytime == 0 ? "First session" : Format.playtime(game.totalPlaytime), systemImage: "clock")
                    Label(state.isRunning ? "Running" : Format.relative(game.lastPlayedAt), systemImage: state.isRunning ? "dot.radiowaves.left.and.right" : "calendar")
                }
                .font(.callout)
                .foregroundStyle(.white.opacity(0.8))

                PlayControl(game: game, tint: .white, foreground: .black.opacity(0.85))
                    .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .leading)
        .background {
            ArtworkBackground(backdrop: library.backdrops[game.id], palette: palette)
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .overlay {
            if state.isRunning { RunningGlow(cornerRadius: 24, lineWidth: 2.5) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14)))
        .shadow(color: (palette?.primary ?? .black).opacity(0.35), radius: 24, y: 12)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onHover { h in withAnimation(.smooth(duration: 0.5)) { hovering = h } }
        .onTapGesture { navigation.selection = .game(game.id) }
        .contextMenu { GameContextMenu(game: game) }
    }
}

/// Play / Stop / progress control shared by the banner and the game page.
struct PlayControl: View {
    @Environment(GameLibrary.self) private var library
    let game: Game
    var tint: Color = .accentColor
    var foreground: Color = .white
    @State private var bounce = 0

    var body: some View {
        let state = library.state(of: game.id)
        HStack(spacing: 12) {
            switch state {
            case .idle:
                Button {
                    bounce += 1
                    library.play(game.id)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .symbolEffect(.bounce, value: bounce)
                        .foregroundStyle(foreground)
                }
                .buttonStyle(PlayButtonStyle(tint: tint))
                .disabled(game.executablePath.isEmpty)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .preparing(let message):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message)
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(.thinMaterial, in: Capsule())
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .running(let since):
                Button { library.stop(game.id) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(PlayButtonStyle(tint: .red))
                .transition(.scale(scale: 0.9).combined(with: .opacity))
                HStack(spacing: 7) {
                    PixelInvader(pixel: 1)
                    Text(since, style: .timer).monospacedDigit()
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(.thinMaterial, in: Capsule())
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: state)
    }
}

// MARK: - Card

struct GameCard: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    let game: Game
    var showsPlaytime = false
    @State private var isHovering = false
    @State private var playBounce = 0

    var body: some View {
        let state = library.state(of: game.id)
        let icon = library.icons[game.id]
        let palette = library.palettes[game.id]

        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                ArtworkBackground(backdrop: library.backdrops[game.id], palette: palette)
                GameIconView(icon: icon, size: 88)
                    .shadow(color: .black.opacity(0.4), radius: isHovering ? 16 : 9, y: isHovering ? 10 : 4)
                    .scaleEffect(isHovering ? 1.08 : 1)
                    .offset(y: isHovering && state == .idle ? -6 : 0)

                if isHovering || state.isBusy {
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                        .transition(.opacity)
                    VStack {
                        Spacer()
                        playOverlay(state)
                            .padding(.bottom, 14)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(isHovering ? 0.3 : 0.12), lineWidth: 1)
            }
            .overlay {
                if state.isRunning { RunningGlow() }
            }
            .overlay(alignment: .topLeading) {
                if game.isSteamGame {
                    Label("Steam", systemImage: "cloud.fill")
                        .font(.caption2.weight(.bold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if game.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .tiltOnHover()
            .shadow(color: (palette?.primary ?? .black).opacity(isHovering ? 0.45 : 0.18), radius: isHovering ? 20 : 8, y: isHovering ? 12 : 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .font(.headline)
                    .lineLimit(1)
                Group {
                    switch state {
                    case .running:
                        HStack(spacing: 5) {
                            PixelInvader(pixel: 1)
                            Text("Playing now").foregroundStyle(.green)
                        }
                    case .preparing(let message): Text(message)
                    case .idle where game.executablePath.isEmpty: Text("Needs an executable")
                    case .idle: Text(showsPlaytime ? Format.playtime(game.totalPlaytime) : Format.relative(game.lastPlayedAt))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { isHovering = hovering } }
        .onTapGesture(count: 2) { library.play(game.id) }
        .onTapGesture { navigation.selection = .game(game.id) }
        .contextMenu { GameContextMenu(game: game) }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: state)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: game.isFavorite)
        .help(game.name)
    }

    @ViewBuilder
    private func playOverlay(_ state: RunState) -> some View {
        switch state {
        case .idle:
            Button {
                playBounce += 1
                library.play(game.id)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .symbolEffect(.bounce, value: playBounce)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .background(.white, in: Capsule())
            .foregroundStyle(.black)
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .disabled(game.executablePath.isEmpty)
        case .preparing:
            ProgressView()
                .controlSize(.small)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        case .running:
            Button { library.stop(game.id) } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: Capsule())
            .help("Stop")
        }
    }
}
