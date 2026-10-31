import SwiftUI
import TrackaroCore
import TrackaroKit

/// The strip above the list while a filter is set or a saved view is open: one chip per filtered dimension, a
/// text field, and the actions to save, discard or clear.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    @FocusState private var textFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.filterChips) { chip in
                        FilterChipView(chip: chip)
                    }
                    Button {
                        model.openFilterPicker()
                    } label: {
                        Label(model.filterChips.isEmpty ? "Filter" : "Add", systemImage: "plus")
                            .font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a filter (F)")
                }
                .padding(.vertical, 1)
            }
            TextField("Filter by text", text: Binding(get: { model.filterDraft }, set: { model.setFilterText($0) }))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 180)
                .focused($textFocused)
                .onExitCommand { textFocused = false }
                .help("Filter by text (/)")
            if model.isViewModified {
                Button("Discard") { model.perform(.revertView) }
                    .controlSize(.small)
                Button("Save") { model.updateCurrentView() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help("Save these filters to the view")
            } else if model.savedView == nil, !model.filter.isEmpty {
                Button("Save as view…") { model.perform(.saveView) }
                    .controlSize(.small)
                    .help("Save as view (⌘S)")
            }
            if !model.filter.isEmpty {
                Button {
                    model.perform(.clearFilters)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Clear filters (⇧F)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onChange(of: model.filterFocusRequest) { textFocused = true }
    }
}

struct FilterChipView: View {
    @Environment(AppModel.self) private var model
    let chip: FilterChip

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.openFilterPicker(query: chip.dimension.title)
            } label: {
                HStack(spacing: 4) {
                    Text(chip.dimension.title).foregroundStyle(.secondary)
                    Text(chip.summary).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Change \(chip.dimension.title.lowercased()) filter")
            Button {
                model.clearFilter(chip.dimension)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove this filter")
        }
        .font(.callout)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(Color(nsColor: Theme.accentSoft), in: Capsule())
    }
}
