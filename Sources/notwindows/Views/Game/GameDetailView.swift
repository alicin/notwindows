import SwiftUI

enum GameTab: String, CaseIterable, Identifiable {
    case general, graphics, performance, input, advanced
    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: "info.circle"
        case .graphics: "display"
        case .performance: "gauge.with.dots.needle.67percent"
        case .input: "keyboard"
        case .advanced: "gearshape.2"
        }
    }
}

enum TabBadge: Equatable {
    case count(Int)
    case warning
}

struct GameDetailView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    let gameID: UUID

    @State private var tab: GameTab = .general
    @State private var showingWinetricks = false
    @State private var showingLog = false
    @State private var report: ExecutableReport?
    @State private var collapsed = false
    @State private var topInset: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var headerRestingTop: CGFloat?
    @State private var stripHeight: CGFloat = 56

    private static let space = "gamePage"
    private static let topAnchor = "top"
    private static let contentAnchor = "content"
    private static let bottomAnchor = "bottom"

    var body: some View {
        if let game = library.game(gameID) {
            let tint = library.palettes[gameID]?.accent ?? .accentColor
            let actions = GamePageActions(showWinetricks: { showingWinetricks = true }, showLog: { showingLog = true })

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        GameHeaderView(game: game, report: headerReport, topBleed: topInset, showWinetricks: actions.showWinetricks,
                                       showLog: actions.showLog, showCompat: { library.compatSheetGameID = gameID })
                            .background { metric { PageMetrics(headerTop: $0.minY, headerHeight: $0.height) } }
                            .id(Self.topAnchor)
                        Section {
                            VStack(spacing: 0) {
                                Color.clear.frame(height: 0).id(Self.contentAnchor)
                                // Pages swap instantly, like a native tab view.
                                GameSettingsPage(gameID: gameID, tab: tab, report: report, actions: actions)
                                    .id(tab)
                                    .padding(.top, 8)
                                    .padding(.bottom, 36)
                                Color.clear.frame(height: 0).id(Self.bottomAnchor)
                            }
                            // Short tabs still fill the page, so switching to one keeps the header scrolled away.
                            .frame(minHeight: viewportHeight, alignment: .top)
                                .environment(\.gameTint, tint)
                        } header: {
                            GameTabStrip(game: game, selection: $tab, collapsed: collapsed, tint: tint, badges: badges(for: game))
                                .background { GeometryReader { Color.clear.onAppear { [height = $0.size.height] in stripHeight = height } } }
                        }
                    }
                }
                .coordinateSpace(name: Self.space)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                topInset = proxy.safeAreaInsets.top
                                viewportHeight = proxy.size.height
                            }
                            .onChange(of: proxy.safeAreaInsets.top) { _, inset in topInset = inset }
                            .onChange(of: proxy.size.height) { _, height in viewportHeight = height }
                    }
                }
                .onPreferenceChange(PageMetricsKey.self) { metrics in
                    // The page always opens scrolled to the top, so the first position seen once the scroll view has
                    // its size (and the toolbar inset) is the header's resting one.
                    guard viewportHeight > 0 else { return }
                    guard let top = metrics.headerTop, let height = metrics.headerHeight else {
                        if !collapsed { collapsed = true }
                        return
                    }
                    let rest = headerRestingTop ?? top
                    if headerRestingTop == nil { headerRestingTop = top }
                    // A little slack, so landing exactly on the pin point (as scrollTo does) still counts.
                    let isCollapsed = rest - top >= height - 24
                    if isCollapsed != collapsed { collapsed = isCollapsed }
                }
                .onChange(of: tab) {
                    if collapsed { proxy.scrollTo(Self.contentAnchor, anchor: belowStrip) }
                }
                #if DEBUG || DEBUG_HOOKS
                .onAppear {
                    DebugSnapshots.tabHandler = { name in
                        if name == "winetricks" { showingWinetricks = true }
                        else if name == "smart" { library.compatSheetGameID = gameID }
                        else if name == "collapse" { withAnimation(.smooth(duration: 0.7)) { proxy.scrollTo(Self.contentAnchor, anchor: belowStrip) } }
                        else if name == "expand" { withAnimation(.smooth(duration: 0.7)) { proxy.scrollTo(Self.topAnchor, anchor: .top) } }
                        else if name == "bottom" { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                        else if let t = GameTab(rawValue: name) { tab = t }
                    }
                }
                #endif
            }
            .navigationTitle(game.name)
            .task(id: game.executablePath) {
                guard let url = game.executableURL else { report = nil; return }
                report = await Task.detached(priority: .utility) { PEFile(url: url) == nil ? nil : ExecutableAnalyzer.analyze(url) }.value
            }
            .sheet(isPresented: $showingWinetricks) { WinetricksSheet(gameID: gameID) }
            .sheet(isPresented: $showingLog) { LogSheet(game: game) }
            .sheet(isPresented: Binding(get: { library.compatSheetGameID == gameID },
                                        set: { if !$0 { library.compatSheetGameID = nil } })) {
                CompatSheet(gameID: gameID)
            }
        }
    }

    /// The executable's report, with the engine Smart Setup learned elsewhere (PCGamingWiki) when the file didn't show it.
    private var headerReport: ExecutableReport? {
        guard var report, report.engine == nil, let learned = library.compatReports[gameID]?.executable, learned.engine != nil else { return report }
        report.engine = learned.engine
        report.engineDetail = learned.engineDetail
        return report
    }

    /// Lines the top of a tab's content up with the bottom of the pinned tab strip, rather than tucking it beneath.
    private var belowStrip: UnitPoint {
        UnitPoint(x: 0.5, y: stripHeight / max(viewportHeight - topInset, 1))
    }

    private func metric(_ make: @escaping (CGRect) -> PageMetrics) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PageMetricsKey.self, value: make(proxy.frame(in: .named(Self.space))))
        }
    }

    /// Dots and counts on the tabs that have something worth looking at.
    private func badges(for game: Game) -> [GameTab: TabBadge] {
        var badges: [GameTab: TabBadge] = [:]
        let engine = engines.engine(named: library.launcher(of: game)?.engineName ?? game.engineName)
        let pending = library.pendingSuggestionCount(gameID)
        let archMismatch = engine.flatMap { engine in game.isPrefix32Bit.map { $0 != engine.isWin32Only } } ?? false
        if pending > 0 {
            badges[.general] = .count(pending)
        } else if game.executablePath.isEmpty || archMismatch {
            badges[.general] = .warning
        }
        if let report, engine?.capabilities.rendererHooks != false {
            let backend = game.settings.direct3DBackend
            if (backend == .d3dmetal && !report.is64Bit) || (report.graphicsAPI == .d3d12 && backend != .d3dmetal) {
                badges[.graphics] = .warning
            }
        }
        if game.settings.wineRosetta, report?.is64Bit == true {
            badges[.performance] = .warning
        }
        return badges
    }
}

private struct PageMetrics: Equatable {
    var headerTop: CGFloat?
    var headerHeight: CGFloat?
}

private struct PageMetricsKey: PreferenceKey {
    static let defaultValue = PageMetrics()

    static func reduce(value: inout PageMetrics, nextValue: () -> PageMetrics) {
        let next = nextValue()
        if next.headerTop != nil { value = next }
    }
}

// MARK: - Tab strip

/// The tab bar under the header. Once the header scrolls away it pins to the top, tightens up and gains the game's
/// icon, name and play button.
private struct GameTabStrip: View {
    @Environment(GameLibrary.self) private var library
    let game: Game
    @Binding var selection: GameTab
    let collapsed: Bool
    let tint: Color
    let badges: [GameTab: TabBadge]

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .leading) {
                Color.clear.frame(height: 1)
                if collapsed {
                    HStack(spacing: 9) {
                        GameIconView(icon: library.icons[game.id], size: 26)
                        Text(game.name).font(.headline).lineLimit(1)
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GameTabBar(selection: $selection, compact: collapsed, tint: tint, badges: badges)
                .fixedSize()

            ZStack(alignment: .trailing) {
                Color.clear.frame(height: 1)
                if collapsed {
                    CompactPlayControl(game: game, tint: tint)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background {
            if collapsed {
                Rectangle()
                    .fill(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: collapsed)
    }
}

private struct CompactPlayControl: View {
    @Environment(GameLibrary.self) private var library
    let game: Game
    let tint: Color

    var body: some View {
        let state = library.state(of: game.id)
        Group {
            switch state {
            case .idle:
                Button { library.play(game.id) } label: {
                    capsule("Play", symbol: "play.fill", fill: tint)
                }
                .buttonStyle(.plain)
                .disabled(game.executablePath.isEmpty)
            case .preparing:
                ProgressView().controlSize(.small)
            case .running(let since):
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        PixelInvader(pixel: 1)
                        Text(since, style: .timer).monospacedDigit()
                    }
                    .font(.callout.weight(.medium))
                    Button { library.stop(game.id) } label: {
                        capsule("Stop", symbol: "stop.fill", fill: .red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state)
    }

    private func capsule(_ title: String, symbol: String, fill: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(fill.gradient, in: Capsule())
            .shadow(color: fill.opacity(0.4), radius: 5, y: 2)
    }
}

struct GameTabBar: View {
    @Binding var selection: GameTab
    var compact = false
    var tint: Color = .accentColor
    var badges: [GameTab: TabBadge] = [:]
    @Namespace private var namespace
    @State private var hovered: GameTab?

    private enum Layer { case buttons, selected, badges }

    var body: some View {
        labels(.buttons)
            .background {
                Capsule()
                    .fill(LinearGradient(colors: [tint.mix(with: .white, amount: 0.15), tint], startPoint: .top, endPoint: .bottom))
                    .shadow(color: tint.opacity(0.45), radius: 7, y: 2)
                    .matchedGeometryEffect(id: selection, in: namespace, isSource: false)
            }
            // The selected label is a white copy clipped to the pill, so its colour follows the pill as it slides
            // instead of flipping before the pill gets there.
            .overlay {
                labels(.selected)
                    .allowsHitTesting(false)
                    .mask {
                        Capsule().matchedGeometryEffect(id: selection, in: namespace, isSource: false)
                    }
            }
            .overlay { labels(.badges).allowsHitTesting(false) }
            .padding(4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selection)
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: compact)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func labels(_ layer: Layer) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(GameTab.allCases.enumerated()), id: \.element) { index, tab in
                // Compact tabs show only icons, except the selected one. One weight for every state, so selecting a
                // tab doesn't change its width and nudge its neighbours.
                let showsTitle = !compact || tab == selection
                let label = HStack(spacing: 6) {
                    Image(systemName: tab.symbol)
                    if showsTitle { Text(tab.title).fixedSize() }
                }
                .font(.callout.weight(.medium))
                .padding(.horizontal, showsTitle ? 14 : 10)
                .frame(height: 30)

                switch layer {
                case .selected:
                    label.foregroundStyle(.white)
                case .badges:
                    label.hidden().overlay(alignment: .topTrailing) { badge(badges[tab]) }
                case .buttons:
                    Button {
                        selection = tab
                    } label: {
                        label
                            .background {
                                if hovered == tab && tab != selection { Capsule().fill(.quaternary) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .matchedGeometryEffect(id: tab, in: namespace)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .help("\(tab.title) (⌘\(index + 1))")
                    .onHover { hovered = $0 ? tab : (hovered == tab ? nil : hovered) }
                }
            }
        }
    }

    @ViewBuilder
    private func badge(_ badge: TabBadge?) -> some View {
        switch badge {
        case .count(let count):
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Color.purple, in: Capsule())
                .offset(x: 3, y: -3)
                .transition(.scale.combined(with: .opacity))
        case .warning:
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
                .offset(x: 1, y: 1)
                .transition(.scale.combined(with: .opacity))
        case nil:
            EmptyView()
        }
    }
}

extension GameLibrary {
    /// Two-way binding into a stored game; writes persist immediately.
    func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<Game, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.game(id)?[keyPath: keyPath] ?? fallback },
            set: { newValue in self.update(id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    func setting<Value>(_ id: UUID, _ keyPath: WritableKeyPath<GameSettings, Value>) -> Binding<Value> {
        binding(id, (\Game.settings).appending(path: keyPath), default: GameSettings()[keyPath: keyPath])
    }
}
