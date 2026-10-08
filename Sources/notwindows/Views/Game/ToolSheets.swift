import SwiftUI

struct WinetricksSheet: View {
    @Environment(GameLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID

    @State private var verbs = ""
    @State private var selected: Set<String> = []
    @State private var isRunning = false
    @State private var result: (status: Int32, log: String)?

    private static let common: [(verb: String, title: String)] = [
        ("vcrun2022", "Visual C++ 2015–2022"),
        ("d3dcompiler_47", "D3DCompiler 47"),
        ("d3dx9", "DirectX 9 (d3dx9)"),
        ("xact", "XAudio / XACT"),
        ("dotnet48", ".NET Framework 4.8"),
        ("dotnetdesktop8", ".NET Desktop 8"),
        ("corefonts", "Core fonts"),
        ("physx", "PhysX"),
        ("faudio", "FAudio"),
        ("dxvk", "DXVK (into prefix)"),
    ]

    private var allVerbs: [String] {
        Self.common.map(\.verb).filter(selected.contains) + verbs.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Winetricks", systemImage: "wand.and.stars").font(.title2.bold())
            Text("Install runtime libraries and fonts into this game's prefix.")
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Self.common, id: \.verb) { item in
                    Toggle(isOn: Binding(get: { selected.contains(item.verb) },
                                         set: { if $0 { selected.insert(item.verb) } else { selected.remove(item.verb) } })) {
                        Text(item.title)
                    }
                    .toggleStyle(.checkbox)
                    .help(item.verb)
                }
            }

            TextField("Other verbs", text: $verbs, prompt: Text("Other verbs, space-separated"))
                .textFieldStyle(.roundedBorder)

            if let result {
                GroupBox {
                    ScrollView {
                        Text(result.log)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                } label: {
                    Label(result.status == 0 ? "Finished" : "Exited with status \(result.status)",
                          systemImage: result.status == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.status == 0 ? .green : .orange)
                }
            }

            HStack {
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running… this can take a while.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(allVerbs.isEmpty || isRunning)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func run() {
        isRunning = true
        result = nil
        Task {
            defer { isRunning = false }
            guard let outcome = await library.winetricks(allVerbs, for: gameID) else { return }
            let text = (try? String(contentsOf: outcome.log, encoding: .utf8)) ?? ""
            result = (outcome.status, String(text.suffix(6000)))
        }
    }
}

struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Last run log", systemImage: "doc.text").font(.headline)
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { load() }
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([game.lastLogURL.exists ? game.lastLogURL : game.logsDirectory])
                }
            }
            .padding(14)
            Divider()
            ScrollView {
                Text(text.isEmpty ? "No log yet. Launch the game, then come back here." : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .defaultScrollAnchor(.bottom)
            Divider()
            HStack {
                Text("Raise the log level in Advanced settings for more detail.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 760, height: 520)
        .onAppear(perform: load)
    }

    private func load() {
        let raw = (try? String(contentsOf: game.lastLogURL, encoding: .utf8)) ?? ""
        text = String(raw.suffix(200_000))
    }
}
