import SwiftUI

/// Review sheet for compatibility suggestions gathered from the executable and online fix databases.
struct CompatSheet: View {
    @Environment(GameLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let gameID: UUID

    @State private var selected: Set<String> = []
    @State private var seededFor: Date?

    private var game: Game? { library.game(gameID) }
    private var report: CompatReport? { library.compatReports[gameID] }
    private var isLoading: Bool { library.compatLoading.contains(gameID) }
    private var installed: Set<String> { library.installedWinetricksVerbs(gameID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                if let report, !isLoading {
                    content(report)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Scanning the executable and checking umu-protonfixes, Lutris and ProtonDB…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.3), value: isLoading)
            Divider()
            footer
        }
        .frame(width: 760, height: 640)
        .task {
            if report == nil { await library.analyzeCompatibility(gameID) }
        }
        .onChange(of: report?.suggestions.map(\.id), initial: true) { _, _ in seedSelection() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GameIconView(icon: library.icons[gameID], size: 52)
            VStack(alignment: .leading, spacing: 6) {
                Text("Smart Setup").font(.title2.bold())
                if let report {
                    FlowChips(chips: chips(for: report))
                } else {
                    Text(game?.name ?? "").foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let report, !report.alternatives.isEmpty {
                Menu {
                    Section("Match this game to…") {
                        ForEach(report.alternatives, id: \.self) { candidate in
                            Button {
                                Task { await library.analyzeCompatibility(gameID, match: candidate) }
                            } label: {
                                if candidate.steamAppID == report.match?.steamAppID {
                                    Label(candidate.title, systemImage: "checkmark")
                                } else {
                                    Text(candidate.title)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Scan Again") { Task { await library.analyzeCompatibility(gameID) } }
                } label: {
                    Label(report.match?.title ?? "Not matched", systemImage: "scope")
                }
                .fixedSize()
                .help("Which game this is, for looking up fixes")
            }
        }
        .padding(18)
    }

    private func chips(for report: CompatReport) -> [Chip] {
        var chips: [Chip] = []
        if let exe = report.executable {
            chips.append(Chip(text: exe.is64Bit ? "64-bit" : "32-bit", symbol: "cpu"))
            if let dx = exe.directXLabel { chips.append(Chip(text: dx, symbol: "cube.transparent")) }
            if let engine = exe.engine { chips.append(Chip(text: engine.rawValue, symbol: "gearshape.2")) }
            if exe.isDotNet { chips.append(Chip(text: ".NET", symbol: "curlybraces")) }
            if exe.hasSteamAPI { chips.append(Chip(text: "Steamworks", symbol: "cloud")) }
            for name in exe.antiCheat { chips.append(Chip(text: name, symbol: "exclamationmark.shield", tint: .red)) }
        }
        if let match = report.match {
            let id = match.steamAppID.map { " · \($0)" } ?? ""
            chips.append(Chip(text: "\(match.title)\(id)", symbol: "scope", tint: .purple))
        }
        if let tier = report.protonDBTier {
            chips.append(Chip(text: "ProtonDB \(tier.capitalized)", symbol: "chart.bar", tint: tierColor(tier)))
        }
        return chips
    }

    private func tierColor(_ tier: String) -> Color {
        switch tier.lowercased() {
        case "platinum": .cyan
        case "gold": .yellow
        case "silver": .gray
        case "bronze": .orange
        case "borked": .red
        default: .secondary
        }
    }

    @ViewBuilder
    private func content(_ report: CompatReport) -> some View {
        let groups = Dictionary(grouping: report.suggestions, by: \.source)
        let order: [CompatSource] = report.suggestions.map(\.source).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        List {
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .listRowSeparator(.hidden)
            }
            if report.suggestions.isEmpty {
                ContentUnavailableView("Nothing to change", systemImage: "checkmark.seal",
                                       description: Text("No fixes are known for this game and the defaults already fit what the executable uses."))
            }
            ForEach(order, id: \.self) { source in
                Section {
                    ForEach(groups[source] ?? []) { suggestion in
                        SuggestionRow(
                            suggestion: suggestion,
                            isSatisfied: game.map { suggestion.action.isSatisfied(by: $0, installedVerbs: installed) } ?? false,
                            isOn: Binding(get: { selected.contains(suggestion.id) },
                                          set: { if $0 { selected.insert(suggestion.id) } else { selected.remove(suggestion.id) } })
                        )
                    }
                } header: {
                    HStack {
                        Text(sourceTitle(source, report: report))
                        if case .protonFixes(let file) = source {
                            Text(file).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !report.notes.isEmpty {
                Section {
                    DisclosureGroup("\(report.notes.count) part\(report.notes.count == 1 ? "" : "s") of the fix can't be applied on macOS") {
                        ForEach(report.notes) { note in
                            Text(note.text).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            if !report.errors.isEmpty {
                Section("Couldn't reach") {
                    ForEach(report.errors, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.inset)
    }

    private func sourceTitle(_ source: CompatSource, report: CompatReport) -> String {
        if case .protonFixes = source, let match = report.match { return "umu-protonfixes for \(match.title)" }
        return source.title
    }

    private var footer: some View {
        let actionable = report?.suggestions.filter { selected.contains($0.id) } ?? []
        let installs = actionable.filter(\.action.needsInstall).count
        return HStack {
            Text("Sources: the game's executable, [umu-protonfixes](https://github.com/Open-Wine-Components/umu-protonfixes), [Lutris](https://lutris.net) and [ProtonDB](https://www.protondb.com).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(actionable.isEmpty ? "Apply" : "Apply \(actionable.count)\(installs > 0 ? " (\(installs) install\(installs == 1 ? "" : "s"))" : "")") {
                library.applyCompat(actionable, to: gameID)
                library.show(Toast(symbol: "sparkles", title: "Applied \(actionable.count) change\(actionable.count == 1 ? "" : "s")",
                                   detail: installs > 0 ? "Winetricks is installing \(installs) component\(installs == 1 ? "" : "s")." : nil, tint: .purple), for: gameID)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(actionable.isEmpty || isLoading)
        }
        .padding(14)
    }

    private func seedSelection() {
        guard let report, let game else { return }
        selected = Set(report.suggestions.filter { $0.recommended && !$0.action.isSatisfied(by: game, installedVerbs: installed) }.map(\.id))
    }
}

private struct SuggestionRow: View {
    let suggestion: CompatSuggestion
    let isSatisfied: Bool
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isSatisfied)
            Image(systemName: suggestion.action.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.action.title)
                Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSatisfied {
                badge("Already set", .green)
            } else if !suggestion.recommended {
                badge("Optional", .secondary)
            }
        }
        .padding(.vertical, 3)
        .opacity(isSatisfied ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !isSatisfied { isOn.toggle() } }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct Chip: Hashable {
    let text: String
    let symbol: String
    var tint: Color = .secondary
}

/// Wraps chips onto as many lines as needed.
struct FlowChips: View {
    let chips: [Chip]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                Label(chip.text, systemImage: chip.symbol)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(chip.tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(chip.tint == .secondary ? .primary : chip.tint)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
