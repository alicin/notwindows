import SwiftUI

extension EnvironmentValues {
    /// The current game's colour, for switches and selections on its settings page.
    @Entry var gameTint: Color = .accentColor
}

// MARK: - Card

/// A group of related settings: a tinted header with an icon and an optional status, rows below, and a footnote.
struct SettingsCard<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var subtitle: String?
    var footer: String?
    /// Why the settings in this card don't apply right now. They're shown greyed out with the values in effect.
    var locked: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    SymbolTile(symbol: symbol, tint: tint, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background {
                    LinearGradient(colors: [tint.opacity(0.13), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                }

                Divider().opacity(0.5)
                if let locked {
                    NoticeRow(locked, symbol: "lock.fill", tint: .secondary)
                    Divider().opacity(0.5)
                }
                content
                    .disabled(locked != nil)
            }
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(title: String, symbol: String, tint: Color, subtitle: String? = nil, footer: String? = nil, locked: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, subtitle: subtitle, footer: footer, locked: locked,
                  accessory: { EmptyView() }, content: content)
    }
}

// MARK: - Rows

/// A title and description on the left, the control on the right, like a System Settings row.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    var badge: String?
    var badgeTint: Color = .orange
    @ViewBuilder var control: Control
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(badgeTint.opacity(0.15), in: Capsule())
                            .foregroundStyle(badgeTint)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .opacity(isEnabled ? 1 : 0.5)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

extension SettingRow where Control == EmptyView {
    init(title: String, detail: String? = nil, badge: String? = nil) {
        self.init(title: title, detail: detail, badge: badge) { EmptyView() }
    }
}

struct ToggleRow: View {
    let title: String
    var detail: String?
    var badge: String?
    @Binding var isOn: Bool
    @Environment(\.gameTint) private var tint

    var body: some View {
        SettingRow(title: title, detail: detail, badge: badge) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(tint)
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 14).opacity(0.6)
    }
}

/// An inline notice inside a card, e.g. a warning about the current combination of settings.
struct NoticeRow<Accessory: View>: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.09))
    }
}

extension NoticeRow where Accessory == EmptyView {
    init(_ text: String, symbol: String = "exclamationmark.triangle.fill", tint: Color = .orange) {
        self.init(text: text, symbol: symbol, tint: tint) { EmptyView() }
    }
}

// MARK: - Indicators

/// A small coloured capsule summarising a card's state.
struct StatusPill: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A keyboard key drawn as a keycap, lit when the mapping it describes is on.
struct KeyCap: View {
    let symbol: String
    let label: String
    var lit = false
    var tint: Color = .accentColor

    var body: some View {
        VStack(spacing: 1) {
            Text(symbol).font(.system(size: 15, weight: .medium))
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .frame(width: 50, height: 42)
        .foregroundStyle(lit ? Color.white : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(lit ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
                .shadow(color: .black.opacity(0.25), radius: 0, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(lit ? 0 : 0.12)))
    }
}

// MARK: - Option tiles

/// A selectable card for one of a few mutually exclusive choices.
struct OptionTile: View {
    let symbol: String
    let title: String
    let caption: String
    let detail: String
    var tags: [(String, Color)] = []
    let isSelected: Bool
    var tint: Color = .accentColor
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? tint : .secondary)
                        .frame(width: 22)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.5))
                        .contentTransition(.symbolEffect(.replace))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(caption).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.0) { tag in
                            Text(tag.0)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(tag.1.opacity(0.15), in: Capsule())
                                .foregroundStyle(tag.1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.12) : Color.primary.opacity(hovering ? 0.06 : 0.03))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? tint : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Render pipeline

/// One API family and the chain of layers its calls pass through on the way to the GPU.
struct PipelineRow: View {
    let api: String
    let stages: [String]
    var isUsedByGame = false
    var tint: Color = .accentColor

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(api).font(.callout.weight(.medium))
                if isUsedByGame {
                    Text("THIS GAME")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(0.8)
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 130, alignment: .leading)
            HStack(spacing: 5) {
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(stage)
                        .font(.caption.weight(.semibold).monospaced())
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(index == 0 ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(index == 0 ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                        }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isUsedByGame ? tint.opacity(0.07) : .clear)
    }
}
