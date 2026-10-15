import AppKit

/// The panels, confirmations and follow-ups around shared settings files.
@MainActor
enum SettingsTransfer {
    static func export(_ game: Game, library: GameLibrary) {
        guard library.game(game.id) != nil else { return }
        let panel = NSSavePanel()
        panel.message = "Export \(game.name)'s settings so someone else can import them. Your Mac's model, chip and macOS version go with them."
        panel.nameFieldStringValue = "\(game.name).\(SharedSettings.fileExtension)"
        panel.allowedContentTypes = [.notwindowsSettings]
        let note = NSTextField(string: "")
        note.placeholderString = "Optional note, e.g. “Smooth at 1920x1243, 60 fps”"
        note.frame = NSRect(x: 0, y: 0, width: 420, height: 22)
        let label = NSTextField(labelWithString: "Note:")
        let accessory = NSStackView(views: [label, note])
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url,
              let shared = library.sharedSettings(of: game.id, note: note.stringValue) else { return }
        do {
            try shared.encoded().write(to: url, options: .atomic)
            library.show(Toast(symbol: "square.and.arrow.up", title: "Settings exported", detail: url.lastPathComponent), for: game.id)
        } catch {
            library.report("Couldn't export the settings", error)
        }
    }

    /// Opens GitHub with the setup filled in as a new file in community/setups, to be proposed as a pull request.
    static func shareWithCommunity(_ game: Game, library: GameLibrary) {
        let machine = SharedSettings.Machine.current
        let alert = NSAlert()
        alert.messageText = "Share \(game.name)'s setup with other players?"
        alert.informativeText = "GitHub opens with the setup filled in, ready to propose for the shared list (you need a GitHub account). "
            + "It holds the settings, launch arguments, engine, Winetricks components and .ini changes, and this Mac's model, chip and macOS version"
            + " (\([machine.chip ?? machine.model, machine.macOS.map { "macOS \($0)" }].compactMap { $0 }.joined(separator: ", "))). Paths and play history stay here."
            + (game.isKnownGood ? "" : "\n\nThis setup hasn't had a long session yet. Setups that ran well for a while help others most.")
        let note = NSTextField(string: "")
        note.placeholderString = "Optional note, e.g. “Smooth at 1920x1243, 60 fps”"
        note.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        alert.accessoryView = note
        alert.addButton(withTitle: "Open GitHub")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = note
        guard alert.runModal() == .alertFirstButtonReturn, let shared = library.sharedSettings(of: game.id, note: note.stringValue) else { return }
        do {
            guard let url = try CommunitySetups.submissionURL(for: shared) else { return }
            NSWorkspace.shared.open(url)
        } catch {
            library.report("Couldn't prepare the setup", error)
        }
    }

    static func chooseAndImport(into game: Game, library: GameLibrary) {
        guard let url = Panels.chooseFile(message: "Choose a settings file to apply to \(game.name)", types: [.notwindowsSettings]),
              let shared = read(url, library: library) else { return }
        if !shared.matches(game) {
            guard confirm("Apply settings for “\(shared.game)” to “\(game.name)”?",
                          info: "They were exported from a different game. \(game.name)'s current settings will be replaced.") else { return }
        }
        apply(shared, to: game, library: library)
    }

    /// A settings file opened from Finder goes to the game it was exported from, or else to the selected game.
    static func open(_ url: URL, library: GameLibrary, navigation: AppNavigation) {
        guard let shared = read(url, library: library) else { return }
        let matches = library.games.filter { shared.matches($0) }
        if matches.count == 1, let game = matches.first {
            navigation.selection = .game(game.id)
            guard confirm("Apply the settings in “\(url.lastPathComponent)” to “\(game.name)”?",
                          info: "\(game.name)'s current settings will be replaced.") else { return }
            apply(shared, to: game, library: library)
        } else if let game = library.game(navigation.selection?.gameID) {
            chooseTarget(shared, game: game, library: library)
        } else {
            library.alert = AppAlert(title: "Add “\(shared.game)” first",
                                     message: "These settings belong to a game that isn't in your library. Add the game, then open the file again or import it from the game's Advanced tab.")
        }
    }

    private static func chooseTarget(_ shared: SharedSettings, game: Game, library: GameLibrary) {
        guard confirm("Apply settings for “\(shared.game)” to “\(game.name)”?",
                      info: "No game in your library matches them exactly. \(game.name)'s current settings will be replaced.") else { return }
        apply(shared, to: game, library: library)
    }

    private static func read(_ url: URL, library: GameLibrary) -> SharedSettings? {
        do {
            return try SharedSettings.decode(Data(contentsOf: url))
        } catch {
            library.report("Couldn't read “\(url.lastPathComponent)”", error)
            return nil
        }
    }

    static func apply(_ shared: SharedSettings, to game: Game, library: GameLibrary) {
        let result = library.importSettings(shared, into: game.id)
        let detail = result.missingEngine.map { "\($0) isn't installed, so the engine stays as it was" } ?? "From \(shared.game)"
        library.show(Toast(symbol: "square.and.arrow.down", title: "Settings imported", detail: detail), for: game.id)

        let verbs = result.missingWinetricks
        if !verbs.isEmpty,
           confirm("Install \(verbs.count) Winetricks component\(verbs.count == 1 ? "" : "s")?",
                   info: "The settings came with \(verbs.formatted(.list(type: .and))), which \(game.name)'s prefix doesn't have yet.",
                   button: "Install") {
            library.startWinetricks(verbs, force: false, unattended: true, for: game.id)
        }
    }

    private static func confirm(_ message: String, info: String, button: String = "Apply") -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
