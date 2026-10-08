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
                GameHeaderView(game: game, showWinetricks: { showingWinetricks = true }, showLog: { showingLog = true })

                GameTabBar(selection: $tab)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.bar)

                Divider()

                ZStack {
                    GameSettingsForm(gameID: gameID, tab: tab)
                        .id(tab)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)),
                            removal: .opacity
                        ))
                }
                .animation(.smooth(duration: 0.28), value: tab)
            }
            .navigationTitle(game.name)
            .sheet(isPresented: $showingWinetricks) { WinetricksSheet(gameID: gameID) }
            .sheet(isPresented: $showingLog) { LogSheet(game: game) }
            #if DEBUG
            .onAppear {
                DebugSnapshots.tabHandler = { name in
                    if name == "winetricks" { showingWinetricks = true } else if let t = GameTab(rawValue: name) { tab = t }
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
        HStack(spacing: 4) {
            ForEach(GameTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = tab }
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : .primary)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.accentColor.gradient)
                                    .shadow(color: .accentColor.opacity(0.4), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "tab", in: namespace)
                            } else if hovered == tab {
                                Capsule().fill(.quaternary)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? tab : (hovered == tab ? nil : hovered) }
            }
        }
        .padding(4)
        .background(.quinary, in: Capsule())
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
