import AppKit
import CoreServices

struct LinkHandler: Identifiable, Hashable {
    enum Status: Hashable {
        case active
        case handledByOtherApp(String)
        case disabled
        case failed(String)
    }

    let scheme: String
    let description: String?
    let program: String?
    let gameIDs: [UUID]
    let registration: RegisteredProtocol
    var status: Status

    var id: String { scheme }
}

extension GameLibrary {
    private static var disabledKey: String { "disabledLinkSchemes" }
    private static var takeOverKey: String { "takeOverLinkSchemes" }

    var disabledLinkSchemes: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.disabledKey) }
    }

    var takeOverLinkSchemes: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.takeOverKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.takeOverKey) }
    }

    // MARK: Discovery

    /// Finds URL schemes registered inside game prefixes and makes macOS send them to notwindows.
    func refreshLinkHandlers() {
        var prefixes: [String: [UUID]] = [:]
        for game in games where game.isPrefixInitialized {
            prefixes[game.prefixURL.standardizedFileURL.path, default: []].append(game.id)
        }
        let cache = linkScanCache
        Task.detached(priority: .utility) {
            var scanned: [String: (stamp: Date, protocols: [RegisteredProtocol])] = [:]
            for path in prefixes.keys {
                let prefix = URL(fileURLWithPath: path, isDirectory: true)
                let stamp = ["system.reg", "user.reg"].compactMap { file in
                    (try? FileManager.default.attributesOfItem(atPath: prefix.appendingPathComponent(file).path))?[.modificationDate] as? Date
                }.max() ?? .distantPast
                if let cached = cache[path], cached.stamp == stamp {
                    scanned[path] = cached
                } else {
                    scanned[path] = (stamp, ProtocolRegistry.protocols(inPrefix: prefix))
                }
            }
            let result = scanned
            await MainActor.run { self.applyLinkScan(result, prefixes: prefixes) }
        }
    }

    private func applyLinkScan(_ scanned: [String: (stamp: Date, protocols: [RegisteredProtocol])], prefixes: [String: [UUID]]) {
        linkScanCache = scanned
        var byScheme: [String: (proto: RegisteredProtocol, games: [UUID])] = [:]
        for (path, entry) in scanned {
            for proto in entry.protocols {
                byScheme[proto.scheme, default: (proto, [])].games += prefixes[path] ?? []
            }
        }

        var handlers: [LinkHandler] = []
        for (scheme, entry) in byScheme.sorted(by: { $0.key < $1.key }) {
            let owner = entry.games.compactMap { game($0) }.first { !$0.isSteamGame }?.name ?? entry.games.compactMap { game($0) }.first?.name
            var handler = LinkHandler(scheme: scheme, description: entry.proto.description, program: entry.proto.programName,
                                      gameIDs: entry.games, registration: entry.proto, status: .active)
            if disabledLinkSchemes.contains(scheme) {
                handler.status = .disabled
            } else if let other = otherHandler(for: scheme), !takeOverLinkSchemes.contains(scheme) {
                handler.status = .handledByOtherApp(other)
            } else {
                do {
                    try installLinkHelper(scheme: scheme, displayName: owner ?? entry.proto.programName ?? scheme)
                } catch {
                    handler.status = .failed(error.localizedDescription)
                }
            }
            handlers.append(handler)
        }
        linkHandlers = handlers
        removeStaleLinkHelpers(keeping: Set(byScheme.keys))
    }

    /// Name of a non-notwindows app that currently opens `scheme`, if any.
    private func otherHandler(for scheme: String) -> String? {
        guard let probe = URL(string: "\(scheme)://"), let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        if app.path.hasPrefix(Paths.linkHandlers.path) || app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Helper apps

    private func helperURL(for scheme: String) -> URL {
        Paths.linkHandlers.appendingPathComponent("\(scheme).app", isDirectory: true)
    }

    private func installLinkHelper(scheme: String, displayName: String) throws {
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: "notwindows-link-helper") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "The link helper is missing from the app bundle."])
        }
        let app = helperURL(for: scheme)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contents.appendingPathComponent("Info.plist")
        let identifierSuffix = scheme.replacingOccurrences(of: #"[^A-Za-z0-9.-]"#, with: "-", options: .regularExpression)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.bunniesinc.notwindows.link.\(identifierSuffix)",
            "CFBundleName": "\(displayName) (notwindows)",
            "CFBundleDisplayName": "\(displayName) (notwindows)",
            "CFBundleExecutable": "notwindows-link-helper",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": true,
            "LSMinimumSystemVersion": "14.0",
            "NotWindowsAppPath": Bundle.main.bundleURL.path,
            "CFBundleURLTypes": [["CFBundleURLName": "\(scheme) links via notwindows", "CFBundleURLSchemes": [scheme]]],
        ]

        let existing = NSDictionary(contentsOf: infoURL) as? [String: Any]
        let upToDate = existing?["NotWindowsAppPath"] as? String == Bundle.main.bundleURL.path
            && existing?["CFBundleName"] as? String == info["CFBundleName"] as? String
            && FileManager.default.contentsEqual(atPath: binary.path, andPath: contents.appendingPathComponent("MacOS/notwindows-link-helper").path)

        if !upToDate {
            try? FileManager.default.removeItem(at: app)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: binary, to: contents.appendingPathComponent("MacOS/notwindows-link-helper"))
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", app.path]
            sign.standardOutput = FileHandle.nullDevice
            sign.standardError = FileHandle.nullDevice
            try sign.run()
            sign.waitUntilExit()
            LSRegisterURL(app as CFURL, true)
        }

        if let probe = URL(string: "\(scheme)://"), NSWorkspace.shared.urlForApplication(toOpen: probe)?.standardizedFileURL != app.standardizedFileURL {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { _ in }
        }
    }

    private func removeStaleLinkHelpers(keeping schemes: Set<String>) {
        let helpers = (try? FileManager.default.contentsOfDirectory(at: Paths.linkHandlers, includingPropertiesForKeys: nil)) ?? []
        for helper in helpers where helper.pathExtension == "app" {
            let scheme = helper.deletingPathExtension().lastPathComponent
            if !schemes.contains(scheme) || disabledLinkSchemes.contains(scheme) {
                LSRegisterURL(helper as CFURL, false)
                try? FileManager.default.removeItem(at: helper)
            }
        }
    }

    func setLinkScheme(_ scheme: String, enabled: Bool) {
        var disabled = disabledLinkSchemes
        if enabled { disabled.remove(scheme) } else { disabled.insert(scheme) }
        disabledLinkSchemes = disabled
        refreshLinkHandlers()
    }

    func takeOverLinkScheme(_ scheme: String) {
        takeOverLinkSchemes.insert(scheme)
        disabledLinkSchemes.remove(scheme)
        refreshLinkHandlers()
    }

    // MARK: Opening links

    private func directLookup(scheme: String) -> LinkHandler? {
        var registration: RegisteredProtocol?
        var owners: [UUID] = []
        for game in games where game.isPrefixInitialized {
            guard let proto = ProtocolRegistry.protocols(inPrefix: game.prefixURL).first(where: { $0.scheme == scheme }) else { continue }
            registration = registration ?? proto
            owners.append(game.id)
        }
        guard let registration else { return nil }
        return LinkHandler(scheme: scheme, description: registration.description, program: registration.programName,
                           gameIDs: owners, registration: registration, status: .active)
    }

    /// Opens a link forwarded from macOS inside the prefix that registered its scheme.
    func openForwardedLink(_ link: String) {
        guard let scheme = URL(string: link)?.scheme?.lowercased() ?? link.split(separator: ":").first.map({ $0.lowercased() }) else { return }
        // On a cold start the background scan may not have finished, so look the scheme up directly.
        let handler = linkHandlers.first { $0.scheme == scheme } ?? directLookup(scheme: scheme)
        let candidates = handler?.gameIDs ?? []
        guard let handler, let target = candidates.first(where: { state(of: $0).isBusy }) ?? candidates.first,
              let session = session(for: target) else {
            show(Toast(symbol: "link.badge.plus", title: "No game handles \(scheme):// links", detail: "Open the launcher once so it can register itself.", tint: .orange))
            return
        }
        do {
            // Run the registered command directly: Wine's ShellExecute only sees machine-wide registrations, but
            // launchers often register per-user (HKCU).
            try ProcessRunner.start(session.engine.loader, handler.registration.arguments(for: link), environment: session.environment,
                                    directory: session.game.driveC, log: session.game.logsDirectory.appendingPathComponent("links.log"))
            show(Toast(symbol: "link", title: "Opened \(scheme):// link", detail: "Handed to \(session.game.name)", tint: .blue), for: target)
        } catch {
            report("Couldn't open the \(scheme):// link", error)
        }
    }
}
