import Foundation

/// Renders the registry-backed settings as a REGEDIT4 file for `regedit /S`.
enum RegistryWriter {
    static func document(for settings: GameSettings) -> String {
        func yn(_ value: Bool) -> String { value ? "\"Y\"" : "\"N\"" }

        let smoothing = settings.fontSmoothing
        let sections: [(String, [(String, String)])] = [
            (#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, [
                ("RetinaMode", yn(settings.retinaMode)),
                ("LeftCommandIsCtrl", yn(settings.commandAsControl)),
                ("RightCommandIsCtrl", yn(settings.commandAsControl)),
                ("LeftOptionIsAlt", yn(settings.optionAsAlt)),
                ("RightOptionIsAlt", yn(settings.optionAsAlt)),
            ]),
            (#"HKEY_CURRENT_USER\Control Panel\Desktop"#, [
                ("LogPixels", settings.retinaMode ? "dword:000000c0" : "dword:00000060"),
                ("FontSmoothing", smoothing ? "\"2\"" : "\"0\""),
                ("FontSmoothingGamma", smoothing ? "dword:00000578" : "dword:00000000"),
                ("FontSmoothingOrientation", smoothing ? "dword:00000001" : "dword:00000000"),
                ("FontSmoothingType", smoothing ? "dword:00000002" : "dword:00000000"),
            ]),
            (#"HKEY_CURRENT_USER\Software\Wine"#, [
                ("Version", "\"\(settings.windowsVersion.rawValue)\""),
            ]),
        ]

        var lines = ["REGEDIT4", ""]
        for (key, values) in sections {
            lines.append("[\(key)]")
            for (name, value) in values { lines.append("\"\(name)\"=\(value)") }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }
}
