import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(RuntimeManager.self) private var runtime
    @Environment(AppNavigation.self) private var navigation
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var navigation = navigation
        @Bindable var library = library

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
                .transition(.opacity)
                .animation(.smooth(duration: 0.25), value: navigation.selection)
        }
        .searchable(text: $navigation.searchText, placement: .sidebar, prompt: "Search games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add Installed Game…", systemImage: "plus.app") { navigation.addGameMode = .existing }
                    Button("Install from Setup File…", systemImage: "shippingbox") { navigation.addGameMode = .installer }
                    Divider()
                    Button("Import Sikarugir Wrapper…", systemImage: "square.and.arrow.down") { navigation.importWrapper(into: library) }
                } label: {
                    Label("Add Game", systemImage: "plus")
                } primaryAction: {
                    navigation.addGameMode = .existing
                }
                .help("Add a game")
            }
        }
        .sheet(item: $navigation.addGameMode) { mode in
            AddGameSheet(mode: mode)
        }
        .alert(item: $library.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .task {
            if runtime.current == nil || engines.installed.isEmpty {
                async let catalog: Void = engines.refreshCatalog()
                async let latest: Void = runtime.checkForUpdate()
                _ = await (catalog, latest)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        Label("Drop to add to your library", systemImage: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = library.toast {
                ToastView(toast: toast.toast, icon: toast.gameID.flatMap { library.icons[$0] })
                    .padding(.bottom, 24)
                    .id(toast.toast.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
                    .onTapGesture { if let id = toast.gameID { navigation.selection = .game(id) } }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: library.toast?.toast)
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection {
        case .game(let id) where library.game(id) != nil:
            GameDetailView(gameID: id)
                .id(id)
        case .favorites:
            LibraryGridView(title: "Favorites", filter: .favorites)
        case .recent:
            LibraryGridView(title: "Recently Played", filter: .recent)
        default:
            LibraryGridView(title: "All Games", filter: .all)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in navigation.open([url], into: library) }
            }
        }
        return !providers.isEmpty
    }
}
