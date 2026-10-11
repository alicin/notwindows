import SwiftUI

private enum PrefixSelection: Hashable {
    case new
    case existing(URL)
    case chooseFolder
}

struct AddGameSheet: View {
    @Environment(GameLibrary.self) private var library
    @Environment(EngineManager.self) private var engines
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State var mode: AddGameMode
    @State private var file: URL?
    @State private var name = ""
    @State private var icon: NSImage?
    @State private var palette: IconPalette?
    @State private var backdrop: NSImage?
    @State private var isTargeted = false
    @State private var prefix = PrefixSelection.new
    /// nil follows the library's default engine.
    @State private var engineName: String?
    /// A prefix picked from disk that no library game uses yet.
    @State private var folderPrefix: URL?

    var body: some View {
        VStack(spacing: 18) {
            Picker("", selection: $mode.animation(.smooth)) {
                Label("Installed Game", systemImage: "gamecontroller").tag(AddGameMode.existing)
                Label("Install from Setup", systemImage: "shippingbox").tag(AddGameMode.installer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            dropWell

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 12) {
                GridRow {
                    Text("Name:")
                        .gridColumnAlignment(.trailing)
                    TextField("Name", text: $name, prompt: Text("Game name"))
                        .labelsHidden()
                }
                GridRow {
                    Text("Windows prefix:")
                    prefixPicker
                        .labelsHidden()
                        .fixedSize()
                }
                // A shared prefix already decides the engine.
                if prefix == .new, engines.installed.count > 1 {
                    GridRow {
                        Text("Wine engine:")
                        Picker("Wine engine", selection: $engineName) {
                            Text("Default (\(engines.defaultEngine?.displayName ?? "none"))").tag(String?.none)
                            Divider()
                            ForEach(engines.installed) { engine in
                                Text(engine.displayName).tag(Optional(engine.name))
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .existing ? "Add to Library" : "Install") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(file == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var prefixPicker: some View {
        Picker("Windows prefix", selection: $prefix) {
            Text("New Prefix").tag(PrefixSelection.new)
            if !library.prefixChoices.isEmpty || folderPrefix != nil {
                Divider()
                ForEach(library.prefixChoices) { choice in
                    Text(choice.title).tag(PrefixSelection.existing(choice.url))
                }
                if let folderPrefix {
                    Text(Self.displayPath(folderPrefix)).tag(PrefixSelection.existing(folderPrefix))
                }
            }
            Divider()
            Text("Other Folder…").tag(PrefixSelection.chooseFolder)
        }
        .onChange(of: prefix) { old, new in
            guard new == .chooseFolder else { return }
            prefix = old
            Task { @MainActor in choosePrefixFolder() }
        }
    }

    private var explanation: String {
        switch (mode, sharedPrefixName) {
        case (.existing, nil):
            "Point at the game's .exe — it can live anywhere on your Mac. notwindows gives it its own Windows prefix and settings."
        case (.existing, let owner?):
            "The game runs in \(owner)'s prefix, sharing its C: drive and installed programs. Its settings stay its own."
        case (.installer, nil):
            "notwindows creates a fresh prefix and runs the installer. When it finishes you'll pick the game's executable."
        case (.installer, let owner?):
            "notwindows runs the installer in \(owner)'s prefix. When it finishes you'll pick the game's executable."
        }
    }

    private var selectedPrefix: URL? {
        if case .existing(let url) = prefix { return url }
        return nil
    }

    private var sharedPrefixName: String? {
        guard let url = selectedPrefix else { return nil }
        if let choice = library.prefixChoices.first(where: { GameLibrary.key($0.url) == GameLibrary.key(url) }) { return choice.title }
        return "the chosen folder"
    }

    private static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private func choosePrefixFolder() {
        guard var url = Panels.chooseFolder(message: "Choose a Wine prefix (the folder that holds drive_c)") else { return }
        if url.lastPathComponent == "drive_c" { url.deleteLastPathComponent() }
        guard GameLibrary.isPrefix(url) else {
            let alert = NSAlert()
            alert.messageText = "That folder isn't a Wine prefix"
            alert.informativeText = "Pick the folder that contains drive_c and system.reg."
            alert.runModal()
            return
        }
        select(prefix: url)
    }

    private func select(prefix url: URL) {
        if let choice = library.prefixChoices.first(where: { GameLibrary.key($0.url) == GameLibrary.key(url) }) {
            prefix = .existing(choice.url)
        } else {
            folderPrefix = url.standardizedFileURL
            prefix = .existing(url.standardizedFileURL)
        }
    }

    private var dropWell: some View {
        Button(action: choose) {
            ZStack {
                if file != nil {
                    ArtworkBackground(backdrop: backdrop, palette: palette)
                        .transition(.opacity)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                }

                if let file {
                    HStack(spacing: 18) {
                        GameIconView(icon: icon, size: 72)
                            .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.lastPathComponent)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text((file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("Click to choose a different file")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: mode == .existing ? "plus.app" : "shippingbox")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                            .symbolEffect(.bounce, value: isTargeted)
                        Text(mode == .existing ? "Drop the game's .exe here" : "Drop the installer here")
                            .font(.headline)
                        Text("or click to browse")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in use(url) }
            }
            return true
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: file)
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private func choose() {
        let message = mode == .existing ? "Choose the game's executable" : "Choose the game's installer"
        guard let url = Panels.chooseFile(message: message, types: Panels.windowsExecutableTypes) else { return }
        use(url)
    }

    private func use(_ url: URL) {
        file = url
        icon = PEIconExtractor.image(fromExecutableAt: url)
        palette = icon?.palette()
        backdrop = icon?.backdrop()
        if name.isEmpty || mode == .installer {
            name = GameLibrary.suggestedName(for: url)
        }
        if let containing = GameLibrary.containingPrefix(of: url) { select(prefix: containing) }
    }

    private func commit() {
        guard let file else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .existing:
            let game = library.addGame(executable: file, name: trimmed, prefix: selectedPrefix, engine: selectedPrefix == nil ? engineName : nil)
            navigation.selection = .game(game.id)
        case .installer:
            let game = library.installGame(setup: file, name: trimmed, prefix: selectedPrefix, engine: selectedPrefix == nil ? engineName : nil)
            navigation.selection = .game(game.id)
        }
        dismiss()
    }
}
