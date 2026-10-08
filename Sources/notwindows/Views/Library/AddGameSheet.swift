import SwiftUI

struct AddGameSheet: View {
    @Environment(GameLibrary.self) private var library
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    @State var mode: AddGameMode
    @State private var file: URL?
    @State private var name = ""
    @State private var icon: NSImage?
    @State private var palette: IconPalette?
    @State private var backdrop: NSImage?
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 18) {
            Picker("", selection: $mode.animation(.smooth)) {
                Label("Installed Game", systemImage: "gamecontroller").tag(AddGameMode.existing)
                Label("Install from Setup", systemImage: "shippingbox").tag(AddGameMode.installer)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            dropWell

            Form {
                TextField("Name", text: $name, prompt: Text("Game name"))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 64)
            .padding(.horizontal, -20)

            Text(mode == .existing
                 ? "Point at the game's .exe — it can live anywhere on your Mac. notwindows gives it its own Windows prefix and settings."
                 : "notwindows creates a fresh prefix and runs the installer. When it finishes you'll pick the game's executable.")
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
    }

    private func commit() {
        guard let file else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .existing:
            let game = library.addGame(executable: file, name: trimmed)
            navigation.selection = .game(game.id)
        case .installer:
            let game = library.installGame(setup: file, name: trimmed)
            navigation.selection = .game(game.id)
        }
        dismiss()
    }
}
