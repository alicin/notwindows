import Foundation

/// rosettax87 swaps Rosetta 2's slow x87 floating-point handlers for fast ones inside 32-bit games.
/// Sikarugir's Wine already starts new processes through `ROSETTA_X87_PATH`; this installs the loader for it.
enum RosettaX87 {
    static var installDirectory: URL { Paths.tools.appendingPathComponent("rosettax87", isDirectory: true) }
    static var loader: URL { installDirectory.appendingPathComponent("runtime_loader") }

    private static var bundled: URL? {
        Bundle.main.url(forResource: "rosettax87", withExtension: nil)
    }

    /// Copies the bundled loader and runtime into Tools and signs the loader with its debugger entitlement.
    static func install() throws -> URL {
        guard let source = bundled else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "rosettax87 is missing from the app bundle."])
        }
        let fm = FileManager.default
        let files = ["runtime_loader", "libRuntimeRosettax87"]
        let upToDate = files.allSatisfy {
            fm.contentsEqual(atPath: source.appendingPathComponent($0).path, andPath: installDirectory.appendingPathComponent($0).path)
        }
        if upToDate, isSigned(loader) { return loader }

        try fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        for file in files {
            let target = installDirectory.appendingPathComponent(file)
            try? fm.removeItem(at: target)
            try fm.copyItem(at: source.appendingPathComponent(file), to: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--entitlements", source.appendingPathComponent("entitlements.plist").path, loader.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't sign the rosettax87 loader."])
        }
        return loader
    }

    /// Sikarugir's ntdll starts 32-bit programs through `lib/wine/i386-unix/wine`, which WoW64 engines don't ship;
    /// their 64-bit loader runs 32-bit code itself.
    static func prepare(_ engine: Engine) throws {
        let link = engine.wineLib.appendingPathComponent("i386-unix/wine")
        guard !link.exists else { return }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../x86_64-unix/wine")
    }

    private static func isSigned(_ url: URL) -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        check.arguments = ["-d", "--entitlements", "-", url.path]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = FileHandle.nullDevice
        guard (try? check.run()) != nil else { return false }
        check.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return check.terminationStatus == 0 && output.contains("com.apple.security.cs.debugger")
    }
}
