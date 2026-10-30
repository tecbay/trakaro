import SwiftUI
import TrackaroCore
import TrackaroKit

/// Dims the window and shows the palette, a picker or the shortcuts sheet. Clicking outside closes it.
struct OverlayHost: View {
    @Environment(AppModel.self) private var model
    let overlay: AppModel.Overlay

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.overlay = nil }
            Group {
                switch overlay {
                case .palette, .picker:
                    CommandMenuView()
                case .shortcuts:
                    ShortcutsView()
                }
            }
            .padding(.top, 72)
        }
        .transition(.opacity)
    }
}

/// The palette and every property picker: a search field over a ranked, keyboard-driven list.
struct CommandMenuView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if case .picker = model.overlay, model.pickerTargets.count > 1 {
                Text("\(model.pickerTargets.count) issues")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            TextField(model.overlayPlaceholder, text: $model.overlayQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .padding(16)
                .focused($searchFocused)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.overlayItems.enumerated()), id: \.element.id) { index, item in
                            OverlayRow(item: item, highlighted: index == model.overlayIndex)
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.confirmOverlay(at: index) }
                                .onHover { inside in if inside { model.overlayIndex = index } }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .onChange(of: model.overlayIndex) { _, index in
                    if model.overlayItems.indices.contains(index) {
                        proxy.scrollTo(model.overlayItems[index].id)
                    }
                }
            }
            if model.overlayItems.isEmpty {
                Text("No matches")
                    .foregroundStyle(.secondary)
                    .padding(20)
            }
        }
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .onAppear { searchFocused = true }
    }
}

private struct OverlayRow: View {
    let item: OverlayItem
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 18)
            }
            Text(item.title).lineLimit(1)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.checked {
                Image(systemName: "checkmark").foregroundStyle(Color.accentTheme)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7).fill(highlighted ? Color.accentTheme.opacity(0.18) : .clear))
    }

    private var tint: Color {
        switch item.tint {
        case let .hex(hex): Color(nsColor: Theme.stateColor(hex))
        case let .priority(priority): Color(nsColor: Theme.priorityColor(priority))
        case .agent: .agent
        case .secondary: .secondary
        }
    }
}

/// Generated from `AppCommand.catalog`, so it can never disagree with the real bindings.
struct ShortcutsView: View {
    var body: some View {
        let catalog = AppCommand.catalog
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 28) {
                ForEach(AppCommand.sections, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(section).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(catalog.filter { $0.section == section }) { command in
                            HStack {
                                Text(command.title).font(.callout)
                                Spacer(minLength: 16)
                                Text(command.binding?.description ?? "")
                                    .font(.system(.caption, design: .rounded).weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)))
                            }
                        }
                    }
                    .frame(width: 210)
                }
            }
            Text("Esc or ? to close").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
    }
}
