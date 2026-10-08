import SwiftUI

enum SidebarItem: Hashable {
    case allGames, favorites, recent
    case game(UUID)

    var gameID: UUID? { if case .game(let id) = self { id } else { nil } }
}

enum AddGameMode: String, Identifiable {
    case existing, installer
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppNavigation {
    var selection: SidebarItem? = .allGames
    var addGameMode: AddGameMode?
    var searchText = ""

    /// Adds dropped or opened files: executables become games, .app bundles are imported as wrappers.
    func open(_ urls: [URL], into library: GameLibrary) {
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "app":
                library.importWrapper(url)
                if let game = library.games.last(where: { $0.externalPrefixPath?.hasPrefix(url.path) == true }) {
                    selection = .game(game.id)
                }
            case "exe", "msi", "bat", "lnk", "com":
                selection = .game(library.addGame(executable: url).id)
            default:
                continue
            }
        }
    }

    func importWrapper(into library: GameLibrary) {
        guard let app = Panels.chooseFile(
            message: "Choose a Sikarugir or Wineskin wrapper to import. Its prefix stays where it is.",
            types: [.applicationBundle],
            directory: FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first
        ) else { return }
        open([app], into: library)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openFiles: (([URL]) -> Void)?
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let openFiles { openFiles(urls) } else { pending += urls }
    }

    func flush() {
        guard let openFiles, !pending.isEmpty else { return }
        openFiles(pending)
        pending = []
    }
}

@main
struct NotWindowsApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var engines: EngineManager
    @State private var runtime: RuntimeManager
    @State private var library: GameLibrary
    @State private var navigation = AppNavigation()

    init() {
        let engines = EngineManager()
        let runtime = RuntimeManager()
        _engines = State(initialValue: engines)
        _runtime = State(initialValue: runtime)
        _library = State(initialValue: GameLibrary(engines: engines, runtime: runtime))
    }

    var body: some Scene {
        Window("notwindows", id: "library") {
            ContentView()
                .environment(library)
                .environment(engines)
                .environment(runtime)
                .environment(navigation)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    appDelegate.openFiles = { urls in navigation.open(urls, into: library) }
                    appDelegate.flush()
                    #if DEBUG
                    DebugSnapshots.install(library: library, navigation: navigation)
                    #endif
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { NotWindowsCommands(library: library, navigation: navigation) }

        Settings {
            SettingsView()
                .environment(library)
                .environment(engines)
                .environment(runtime)
        }
    }
}

struct NotWindowsCommands: Commands {
    let library: GameLibrary
    let navigation: AppNavigation

    private var selectedID: UUID? { navigation.selection?.gameID }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Game…") { navigation.addGameMode = .existing }
                .keyboardShortcut("n")
            Button("Install Game…") { navigation.addGameMode = .installer }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Import Sikarugir Wrapper…") { navigation.importWrapper(into: library) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandMenu("Game") {
            Button("Play") { if let id = selectedID { library.play(id) } }
                .keyboardShortcut("r")
                .disabled(selectedID.map { library.state(of: $0).isBusy } ?? true)
            Button("Stop") { if let id = selectedID { library.stop(id) } }
                .keyboardShortcut(".")
                .disabled(selectedID.map { !library.state(of: $0).isBusy } ?? true)
            Divider()
            Button("Open C: Drive") {
                if let game = library.game(selectedID) { NSWorkspace.shared.open(game.driveC) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(selectedID == nil)
            Menu("Windows Tools") {
                ForEach(WineTool.allCases) { tool in
                    Button(tool.title) { if let id = selectedID { library.open(tool, for: id) } }
                }
            }
            .disabled(selectedID == nil)
            Divider()
            Button("Stop All Games") { library.stopAll() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(library.runningCount == 0)
        }
    }
}
