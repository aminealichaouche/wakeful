import SwiftUI

/// Small grey section heading.
struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

/// Plain row button with a hover highlight, like a menu item.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBackground(isPressed: configuration.isPressed) { configuration.label }
    }

    private struct RowBackground<Label: View>: View {
        let isPressed: Bool
        @ViewBuilder let label: () -> Label
        @State private var isHovering = false

        var body: some View {
            label()
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.primary.opacity(isPressed ? 0.14 : isHovering ? 0.08 : 0))
                )
                .onHover { isHovering = $0 }
        }
    }
}

/// Icon + title row that performs an action.
struct ActionRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RowIcon(icon: icon)
                Text(title)
                Spacer(minLength: 0)
            }
            .frame(height: 26)
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Icon + title row that opens another page, with a trailing chevron.
struct NavigationRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                RowIcon(icon: icon)
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 26)
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Row with a round icon that fills with the accent color when on (BetterDisplay style).
/// An optional detail line explains the option underneath the title.
struct ToggleRow: View {
    let icon: String
    let title: String
    let isOn: Bool
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: detail == nil ? .center : .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isOn ? Color.accentColor : Color.primary.opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .frame(minHeight: 22)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, detail == nil ? 3 : 5)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Row that reveals extra content below it, with a rotating chevron.
struct ExpandableRow<Content: View>: View {
    let icon: String
    let title: String
    let section: MenuView.Section
    @Binding var expanded: MenuView.Section?
    @ViewBuilder let content: () -> Content

    private var isExpanded: Bool { expanded == section }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded = isExpanded ? nil : section
            } label: {
                HStack(spacing: 8) {
                    RowIcon(icon: icon)
                    Text(title)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(height: 26)
            }
            .buttonStyle(RowButtonStyle())

            if isExpanded {
                content()
                    .padding(.leading, 34)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }
}

/// A row of capsule buttons for quick durations.
struct ChipRow: View {
    let values: [Int]
    let columns: Int
    let label: (Int) -> String
    let action: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(values, id: \.self) { value in
                Chip(title: label(value)) { action(value) }
            }
        }
        .padding(.vertical, 4)
    }

    private struct Chip: View {
        let title: String
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .foregroundStyle(isHovering ? Color.white : Color.primary)
                    .background(Capsule().fill(isHovering ? Color.accentColor : Color.primary.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
    }
}

/// Small title + switch line used in the settings section.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

/// Small "i" that shows or hides explanations, filled while they're shown.
struct InfoButton: View {
    @Binding var isOn: Bool
    @State private var isHovering = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "info.circle.fill" : "info.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn || isHovering ? Color.accentColor : .secondary)
                .frame(width: 18, height: 18)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
        .help(isOn ? "Hide explanations" : "Explain these options")
        .onHover { isHovering = $0 }
    }
}

/// Round icon button for the footer.
struct CircleButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.primary.opacity(isHovering ? 0.18 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

/// Fixed-width SF Symbol so row titles line up.
private struct RowIcon: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 22)
    }
}
