import SwiftUI

/// Browser for every winetricks verb, with installed status, multi-select, live log and cancel.
struct WinetricksSheet: View {
    enum Filter: Hashable {
        case recommended, installed, all
        case category(WinetricksVerb.Category)
    }

    @Environment(GameLibrary.self) private var library
    @Environment(RuntimeManager.self) private var runtime
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID

    @State private var verbs: [WinetricksVerb] = []
    @State private var installed: [String] = []
    @State private var loadError: String?
    @State private var filter: Filter = .recommended
    @State private var search = ""
    @State private var selected: [String] = []
    @State private var force = false
    @State private var unattended = true
    @State private var logText = ""

    private var job: WinetricksJob? { library.winetricksJobs[gameID] }

    private var visible: [WinetricksVerb] {
        var list: [WinetricksVerb]
        switch filter {
        case .recommended:
            let order = Dictionary(uniqueKeysWithValues: WinetricksCatalog.recommended.enumerated().map { ($1, $0) })
            list = verbs.filter { order[$0.name] != nil }.sorted { order[$0.name]! < order[$1.name]! }
        case .installed:
            let set = Set(installed)
            list = verbs.filter { set.contains($0.name) }
        case .all:
            list = verbs
        case .category(let category):
            list = verbs.filter { $0.category == category }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = verbs.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
                    || ($0.publisher?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                verbList
            }
            if let job {
                Divider()
                jobPanel(job)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            footer
        }
        .frame(width: 960, height: 680)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: job?.status)
        .task { await load() }
        #if DEBUG
        .onAppear {
            DebugSnapshots.winetricksHandler = { command in
                if command == "clear" { library.clearWinetricksJob(gameID) }
                else if command == "all" { filter = .all }
                else { selected = command.split(separator: " ").map(String.init) }
            }
        }
        #endif
        .task(id: job?.isRunning) { await followLog() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Winetricks").font(.title2.bold())
                Text("Install runtimes, fonts and tweaks into \(library.game(gameID)?.name ?? "this game")'s prefix.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search \(verbs.count) verbs", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
        }
        .padding(18)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { filter }, set: { if let value = $0 { filter = value } })) {
            Section {
                row("Recommended", "star", count: verbs.filter { WinetricksCatalog.recommended.contains($0.name) }.count).tag(Filter.recommended)
                row("Installed", "checkmark.circle", count: installed.count).tag(Filter.installed)
                row("All", "square.grid.2x2", count: verbs.count).tag(Filter.all)
            }
            Section("Categories") {
                ForEach(WinetricksVerb.Category.allCases) { category in
                    row(category.title, category.symbol, count: verbs.filter { $0.category == category }.count)
                        .tag(Filter.category(category))
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 220)
    }

    private func row(_ title: String, _ symbol: String, count: Int) -> some View {
        Label(title, systemImage: symbol).badge(count)
    }

    @ViewBuilder
    private var verbList: some View {
        if let loadError {
            ContentUnavailableView("Couldn't load winetricks", systemImage: "exclamationmark.triangle", description: Text(loadError))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if verbs.isEmpty {
            ProgressView("Loading verbs…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView.search(text: search).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visible) { verb in
                VerbRow(
                    verb: verb,
                    isInstalled: installed.contains(verb.name),
                    isSelected: selected.contains(verb.name),
                    conflictsWithSelection: verb.conflicts.contains(where: selected.contains)
                ) { toggle(verb.name) }
            }
            .listStyle(.inset)
            .animation(.smooth(duration: 0.25), value: filter)
        }
    }

    private func jobPanel(_ job: WinetricksJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch job.status {
                case .preparing, .running:
                    ProgressView().controlSize(.small)
                    Text("Installing \(job.verbs.joined(separator: ", "))…").font(.headline)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Finished \(job.verbs.joined(separator: ", "))").font(.headline)
                case .cancelled:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    Text("Cancelled").font(.headline)
                case .failed(let code):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Failed with status \(code)").font(.headline)
                }
                Spacer()
                Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.log]) }
                    .buttonStyle(.link)
                if job.isRunning {
                    Button("Cancel", role: .destructive) { library.cancelWinetricks(gameID) }
                } else {
                    Button("Dismiss") { library.clearWinetricksJob(gameID) }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logText.isEmpty ? "Waiting for output…" : logText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("log")
                }
                .frame(height: 150)
                .padding(8)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: logText) { proxy.scrollTo("log", anchor: .bottom) }
            }
        }
        .padding(14)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if selected.isEmpty {
                Text("Select verbs to install").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selected, id: \.self) { name in
                            HStack(spacing: 4) {
                                Text(name).font(.callout.monospaced())
                                Button { toggle(name) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.tint.opacity(0.15), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
                }
            }
            Spacer(minLength: 8)
            Toggle("Reinstall", isOn: $force)
                .toggleStyle(.checkbox)
                .help("Pass --force so already-installed verbs run again")
            Toggle("Silent", isOn: $unattended)
                .toggleStyle(.checkbox)
                .help("Run installers unattended where possible")
            Menu {
                Button("Open Download Cache") {
                    try? FileManager.default.createDirectory(at: WinetricksCatalog.cacheDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(WinetricksCatalog.cacheDirectory)
                }
                Button("Update Winetricks") {
                    Task {
                        do { try await runtime.refreshWinetricks(); await load() }
                        catch { library.report("Couldn't update winetricks", error) }
                    }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Install \(selected.isEmpty ? "" : "\(selected.count) ")") {
                library.startWinetricks(selected, force: force, unattended: unattended, for: gameID)
                selected = []
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty || job?.isRunning == true)
        }
        .padding(14)
    }

    // MARK: Data

    private func toggle(_ name: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            if let index = selected.firstIndex(of: name) { selected.remove(at: index) } else { selected.append(name) }
        }
    }

    private func load() async {
        do {
            let script = try await runtime.winetricksScript()
            let parsed = try await Task.detached(priority: .userInitiated) {
                WinetricksCatalog.parse(try String(contentsOf: script, encoding: .utf8))
            }.value
            verbs = parsed.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            refreshInstalled()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshInstalled() {
        if let prefix = library.game(gameID)?.prefixURL { installed = WinetricksCatalog.installedVerbs(in: prefix) }
    }

    /// Tails the job's log while it runs, then refreshes installed status once.
    private func followLog() async {
        while !Task.isCancelled {
            if let log = job?.log, let text = try? String(contentsOf: log, encoding: .utf8) {
                let tail = String(text.suffix(20_000))
                if tail != logText { logText = tail }
            }
            guard job?.isRunning == true else { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        refreshInstalled()
    }
}

private struct VerbRow: View {
    let verb: WinetricksVerb
    let isInstalled: Bool
    let isSelected: Bool
    let conflictsWithSelection: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: verb.category.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verb.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(verb.title)
                HStack(spacing: 6) {
                    Text(verb.name).font(.caption.monospaced())
                    if let publisher = verb.publisher { Text("· \(publisher)").font(.caption) }
                    if let year = verb.year { Text("· \(year)").font(.caption) }
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if conflictsWithSelection && !isSelected {
                badge("Conflicts", .red)
            }
            if verb.needsManualDownload {
                badge("Manual download", .orange)
                    .help("The installer must be downloaded by hand into the winetricks cache first.")
            }
            if isInstalled {
                badge("Installed", .green)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
