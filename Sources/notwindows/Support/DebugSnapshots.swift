#if DEBUG || DEBUG_HOOKS
import AppKit

/// Debug-only remote control for UI review: post the distributed notification
/// `com.bunniesinc.notwindows.debug` with an object such as `snapshot:/tmp/a.png`, `select:all`, `select:<game name>`,
/// `tab:graphics`, `fakerun:<game name>` or `settings`. `script:` and `record:` together capture walkthroughs for the README.
@MainActor
enum DebugSnapshots {
    static var tabHandler: ((String) -> Void)?
    static var openSettings: (() -> Void)?
    static var winetricksHandler: ((String) -> Void)?

    static func install(library: GameLibrary, navigation: AppNavigation) {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.bunniesinc.notwindows.debug"), object: nil, queue: .main) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { handle(command, library: library, navigation: navigation) }
        }
    }

    private static func handle(_ command: String, library: GameLibrary, navigation: AppNavigation) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "snapshot":
            let window = NSApp.orderedWindows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }
            guard let view = window?.contentView?.superview ?? window?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
        case "burst":
            // burst:<dir>|<command> runs the command, then grabs the window's composited frames while it animates.
            let pieces = argument.split(separator: "|", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.frame.width > 300 }) else { return }
            try? FileManager.default.createDirectory(atPath: pieces[0], withIntermediateDirectories: true)
            handle(pieces[1], library: library, navigation: navigation)
            burst(window: window, directory: pieces[0], frame: 0)
        case "record":
            // record:<dir>|<seconds>|<fps>[|retina] captures the window off the main thread, so the UI keeps animating.
            let pieces = argument.split(separator: "|").map(String.init)
            guard pieces.count >= 3, let seconds = Double(pieces[1]), let fps = Double(pieces[2]),
                  let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.frame.width > 300 }) else { return }
            try? FileManager.default.createDirectory(atPath: pieces[0], withIntermediateDirectories: true)
            record(windowNumber: UInt32(window.windowNumber), directory: pieces[0], seconds: seconds, fps: fps, retina: pieces.count > 3)
        case "script":
            // script:<seconds>><command>~<seconds>><command>… runs each command at its offset from now.
            for step in argument.components(separatedBy: "~") {
                let pieces = step.split(separator: ">", maxSplits: 1).map(String.init)
                guard pieces.count == 2, let delay = Double(pieces[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated { handle(pieces[1], library: library, navigation: navigation) }
                }
            }
        case "activate":
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.isVisible && $0.frame.width > 300 }?.makeKeyAndOrderFront(nil)
        case "responder":
            let responder = NSApp.keyWindow?.firstResponder
            print("first responder:", responder.map { String(describing: type(of: $0)) } ?? "none")
        case "select":
            switch argument {
            case "all": navigation.selection = .allGames
            case "favorites": navigation.selection = .favorites
            case "recent": navigation.selection = .recent
            default:
                if let game = library.games.first(where: { $0.name == argument }) { navigation.selection = .game(game.id) }
            }
        case "tab":
            tabHandler?(argument)
        case "play":
            if let game = library.games.first(where: { $0.name == argument }) { library.play(game.id) }
        case "stop":
            if let game = library.games.first(where: { $0.name == argument }) { library.stop(game.id) }
        case "fakerun":
            // Toggles a game's running state without starting Wine, for reviewing the running UI.
            if let game = library.games.first(where: { $0.name == argument }) {
                library.states[game.id] = library.state(of: game.id).isRunning ? .idle : .running(since: Date())
            }
        case "winetricks":
            let pieces = argument.split(separator: "|").map(String.init)
            if pieces.count == 2, let game = library.games.first(where: { $0.name == pieces[0] }) {
                library.startWinetricks(pieces[1].split(separator: " ").map(String.init), force: false, unattended: true, for: game.id)
            }
        case "wt":
            winetricksHandler?(argument)
        case "steamsync":
            library.syncAllSteamLibraries()
        case "settings":
            openSettings?()
        case "add":
            navigation.addGameMode = argument == "installer" ? .installer : .existing
        case "dismiss":
            navigation.addGameMode = nil
        case "appearance":
            NSApp.appearance = argument == "dark" ? NSAppearance(named: .darkAqua) : argument == "light" ? NSAppearance(named: .aqua) : nil
        case "resize":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            if size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 300 }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
        default:
            break
        }
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// CGWindowListCreateImage is hidden from newer SDKs but still captures the app's own windows with AppKit
    /// animations composited in, which `cacheDisplay` misses.
    private static let windowImage: WindowImageFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(symbol, to: WindowImageFunction.self)
    }()

    private static func burst(window: NSWindow, directory: String, frame: Int) {
        guard frame < 30 else { return }
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        if let image = windowImage?(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue() {
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(String(format: "%02d", frame)).png"))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { burst(window: window, directory: directory, frame: frame + 1) }
    }

    /// Frames are named by their slot in the timeline, so a slow capture leaves a gap rather than shifting later frames.
    private static func record(windowNumber: UInt32, directory: String, seconds: Double, fps: Double, retina: Bool) {
        guard let capture = windowImage else { return }
        let writer = DispatchQueue(label: "com.bunniesinc.notwindows.record", attributes: .concurrent)
        let inFlight = DispatchSemaphore(value: 24)
        Thread.detachNewThread {
            let start = Date()
            var slot = 0
            while slot < Int(seconds * fps) {
                let due = start.addingTimeInterval(Double(slot) / fps)
                if due.timeIntervalSinceNow > 0 { Thread.sleep(until: due) }
                slot = Int(Date().timeIntervalSince(start) * fps)
                // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | best or nominal resolution
                if let image = capture(.null, 1 << 3, windowNumber, 1 << 0 | (retina ? 1 << 3 : 1 << 4))?.takeRetainedValue() {
                    let name = "\(directory)/\(String(format: "%04d", slot)).png"
                    inFlight.wait()
                    writer.async {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
                        inFlight.signal()
                    }
                }
                slot += 1
            }
        }
    }
}
#endif
