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

struct GameDetailView: View {
    @Environment(GameLibrary.self) private var library
    let gameID: UUID

    @State private var tab: GameTab = .general
    @State private var showingWinetricks = false
    @State private var showingLog = false

    var body: some View {
        if let game = library.game(gameID) {
            VStack(spacing: 0) {
                GameHeaderView(game: game, showWinetricks: { showingWinetricks = true }, showLog: { showingLog = true },
                               showCompat: { library.compatSheetGameID = gameID })

                GameTabBar(selection: $tab)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.bar)

                Divider()

                ZStack {
                    GameSettingsForm(gameID: gameID, tab: tab)
                        .id(tab)
                        .transition(.paneSwap)
                }
            }
            .navigationTitle(game.name)
            .sheet(isPresented: $showingWinetricks) { WinetricksSheet(gameID: gameID) }
            .sheet(isPresented: $showingLog) { LogSheet(game: game) }
            .sheet(isPresented: Binding(get: { library.compatSheetGameID == gameID },
                                        set: { if !$0 { library.compatSheetGameID = nil } })) {
                CompatSheet(gameID: gameID)
            }
            #if DEBUG
            .onAppear {
                DebugSnapshots.tabHandler = { name in
                    if name == "winetricks" { showingWinetricks = true }
                    else if name == "smart" { library.compatSheetGameID = gameID }
                    else if let t = GameTab(rawValue: name) { tab = t }
                }
            }
            #endif
        }
    }
}

struct GameTabBar: View {
    @Binding var selection: GameTab
    @Namespace private var namespace
    @State private var hovered: GameTab?

    var body: some View {
        labels(selected: false)
            .background {
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .shadow(color: .accentColor.opacity(0.35), radius: 5, y: 2)
                    .matchedGeometryEffect(id: selection, in: namespace, isSource: false)
            }
            // The selected label is a white copy clipped to the pill, so its colour follows the pill as it slides
            // instead of flipping before the pill gets there.
            .overlay {
                labels(selected: true)
                    .allowsHitTesting(false)
                    .mask {
                        Capsule().matchedGeometryEffect(id: selection, in: namespace, isSource: false)
                    }
            }
            .padding(4)
            .background(.quinary, in: Capsule())
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selection)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func labels(selected: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(GameTab.allCases.enumerated()), id: \.element) { index, tab in
                // One weight for every state, so selecting a tab doesn't change its width and nudge its neighbours.
                let label = Label(tab.title, systemImage: tab.symbol)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                if selected {
                    label.foregroundStyle(.white)
                } else {
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
