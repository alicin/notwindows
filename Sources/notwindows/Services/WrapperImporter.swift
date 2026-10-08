import AppKit

/// Turns an existing Sikarugir/Wineskin wrapper into a library entry that uses the wrapper's prefix in place.
enum WrapperImporter {
    struct Result {
        let game: Game
        let icon: NSImage?
    }

    static func importWrapper(at app: URL) throws -> Result {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let prefix = contents.appendingPathComponent("SharedSupport/prefix", isDirectory: true)
        guard let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any],
              prefix.appendingPathComponent("system.reg").exists else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "\(app.lastPathComponent) isn't a Sikarugir or Wineskin wrapper with a set-up prefix."])
        }

        func flag(_ key: String) -> Bool? {
            switch plist[key] {
            case let n as NSNumber: n.boolValue
            case let s as String: (s as NSString).boolValue
            default: nil
            }
        }

        var settings = GameSettings()
        if flag("D3DMETAL") == true {
            settings.direct3DBackend = .d3dmetal
        } else if flag("DXVK") == true {
            settings.direct3DBackend = .dxvk
        } else if flag("DXMT") == false {
            settings.direct3DBackend = .wined3d
        }
        if let d9vk = flag("D9VK") { settings.direct3D9Backend = d9vk ? .d9vk : .wined3d }
        if let cnc = flag("CNC_DDRAW") { settings.cncDDraw = cnc }
        if let msync = flag("WINEMSYNC") { settings.msync = msync }
        if let esync = flag("WINEESYNC") { settings.esync = esync }
        if let hud = flag("METAL_HUD") { settings.metalHUD = hud }
        if let fastMath = flag("FASTMATH") { settings.moltenVKFastMath = fastMath }
        if let skip = flag("Skip Mono") { settings.skipMono = skip }
        if let skip = flag("Skip Gecko") { settings.skipGecko = skip }
        readRegistry(prefix.appendingPathComponent("user.reg"), into: &settings)

        let name = (plist["CFBundleName"] as? String).flatMap { $0 == "SikarugirNavyWrapper" ? nil : $0 }
            ?? app.deletingPathExtension().lastPathComponent
        var game = Game(name: name, settings: settings)
        game.externalPrefixPath = prefix.path
        game.arguments = plist["Program Flags"] as? String ?? ""

        if let runPath = plist["Program Name and Path"] as? String, runPath != "/nothing.exe", !runPath.isEmpty {
            let relative = runPath.replacingOccurrences(of: "\\", with: "/")
            let trimmed = relative.hasPrefix("C:") || relative.hasPrefix("c:") ? String(relative.dropFirst(2)) : relative
            game.executablePath = prefix.appendingPathComponent("drive_c").path + (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        }

        return Result(game: game, icon: NSWorkspace.shared.icon(forFile: app.path))
    }

    /// Picks up the Mac-driver toggles that Sikarugir stores in the prefix registry.
    private static func readRegistry(_ url: URL, into settings: inout GameSettings) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var section = ""
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                section = String(line)
                continue
            }
            if section.hasPrefix(#"[Software\\Wine\\Mac Driver]"#) {
                if line.hasPrefix("\"RetinaMode\"") { settings.retinaMode = line.hasSuffix("\"Y\"") }
                if line.hasPrefix("\"LeftCommandIsCtrl\"") { settings.commandAsControl = line.hasSuffix("\"Y\"") }
                if line.hasPrefix("\"LeftOptionIsAlt\"") { settings.optionAsAlt = line.hasSuffix("\"Y\"") }
            } else if section.hasPrefix(#"[Software\\Wine]"#), line.hasPrefix("\"Version\"") {
                let value = line.split(separator: "=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if let value, let version = WindowsVersion(rawValue: value) { settings.windowsVersion = version }
            }
        }
    }
}
