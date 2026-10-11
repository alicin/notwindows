import AppKit

/// Tiny background app registered as the macOS handler for one URL scheme that a Windows program claimed inside
/// a prefix. It forwards the link to notwindows, which opens it inside the right prefix.
final class Forwarder: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
    }

    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let link = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        var components = URLComponents()
        components.scheme = "notwindows"
        components.host = "open-url"
        components.queryItems = [URLQueryItem(name: "url", value: link)]
        guard let url = components.url else { return }
        // Go back to the copy of notwindows that created this helper, not whichever copy LaunchServices prefers.
        if let path = Bundle.main.object(forInfoDictionaryKey: "NotWindowsAppPath") as? String,
           FileManager.default.fileExists(atPath: path) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: path), configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
}

let app = NSApplication.shared
let forwarder = Forwarder()
app.delegate = forwarder
app.setActivationPolicy(.prohibited)
app.run()
