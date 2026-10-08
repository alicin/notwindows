import SwiftUI

/// First-run checklist: Rosetta, the shared runtime and at least one engine.
struct SetupView: View {
    @Environment(EngineManager.self) private var engines
    @Environment(RuntimeManager.self) private var runtime
    @Environment(GameLibrary.self) private var library
    @State private var isInstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: "wineglass.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(
                        LinearGradient(colors: [IconPalette.fallback.glow, IconPalette.fallback.primary, IconPalette.fallback.secondary],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .shadow(color: IconPalette.fallback.primary.opacity(0.5), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finish setting up notwindows").font(.title2.bold())
                    Text("Games share one runtime and one or more Wine engines, downloaded once from the Sikarugir project.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                step(
                    done: runtime.isRosettaInstalled,
                    title: "Rosetta 2",
                    detail: runtime.isRosettaInstalled
                        ? "Installed."
                        : "Wine engines are Intel builds. Run `softwareupdate --install-rosetta --agree-to-license` in Terminal, then relaunch."
                ) { EmptyView() }

                Divider().padding(.leading, 40)

                step(
                    done: runtime.current != nil,
                    title: "Runtime",
                    detail: runtime.current.map { "\($0.name) installed." }
                        ?? "MoltenVK, DXVK, DXMT, D3DMetal, GStreamer and friends (~96 MB download)."
                ) {
                    if let progress = runtime.progress {
                        ProgressView(value: progress).frame(width: 140)
                    } else if runtime.current == nil {
                        Button("Download") { install { try await runtime.installLatest() } }
                    }
                }

                Divider().padding(.leading, 40)

                step(
                    done: !engines.installed.isEmpty,
                    title: "Wine engine",
                    detail: engines.defaultEngine.map { "\($0.displayName) installed." }
                        ?? engines.suggested.map { "\($0.displayName) (\(Format.bytes($0.size)) download)." }
                        ?? engines.catalogError
                        ?? "Looking up available engines…"
                ) {
                    if let item = engines.suggested, engines.installed.isEmpty {
                        if let progress = engines.progress[item.name] {
                            ProgressView(value: progress).frame(width: 140)
                        } else {
                            Button("Download") { install { try await engines.install(item) } }
                        }
                    } else if engines.installed.isEmpty && engines.isRefreshingCatalog {
                        ProgressView().controlSize(.small)
                    } else if engines.installed.isEmpty && engines.catalogError != nil {
                        Button("Retry") { Task { await engines.refreshCatalog() } }
                    }
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if runtime.current == nil && engines.installed.isEmpty, let item = engines.suggested {
                Button {
                    install {
                        async let r: Void = runtime.installLatest()
                        async let e: Void = engines.install(item)
                        _ = try await (r, e)
                    }
                } label: {
                    Label("Download Everything", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(PlayButtonStyle(tint: .accentColor))
                .disabled(isInstalling)
            }
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: runtime.current?.name)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: engines.installed.count)
    }

    private func step<Accessory: View>(done: Bool, title: String, detail: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2)
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: done)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(.init(detail)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            accessory()
        }
        .padding(12)
    }

    private func install(_ work: @escaping () async throws -> Void) {
        isInstalling = true
        Task {
            defer { isInstalling = false }
            do { try await work() } catch { library.report("Download failed", error) }
        }
    }
}
