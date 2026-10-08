import AppKit
import UniformTypeIdentifiers

enum Panels {
    static let windowsExecutableTypes: [UTType] = ["exe", "msi", "bat", "lnk", "com"]
        .compactMap { UTType(filenameExtension: $0) }

    @MainActor
    static func chooseFile(message: String, types: [UTType], directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = types
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = types != [.applicationBundle]
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFolder(message: String, directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum Format {
    static func playtime(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return seconds > 0 ? "Under a minute" : "Not played yet" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? ""
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "Never played" }
        if abs(date.timeIntervalSinceNow) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
