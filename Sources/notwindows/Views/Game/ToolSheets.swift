import SwiftUI

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
