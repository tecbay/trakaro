import AppKit
import SwiftUI
import TrackaroCore
import TrackaroKit


/// Shows Markdown as formatted text: headings, lists, task lists, tables, code blocks, quotes and links.
struct MarkdownView: View {
    let source: String
    var keepingLineBreaks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Markdown.blocks(source, keepingLineBreaks: keepingLineBreaks)) { block in
                MarkdownBlockView(block: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if block.listDepth > 0 { marker.frame(width: 20, alignment: .trailing) }
            content
        }
        .padding(.leading, CGFloat(max(block.listDepth - 1, 0)) * 18)
        .padding(.leading, CGFloat(block.quoteDepth) * 12)
        .overlay(alignment: .leading) {
            if block.quoteDepth > 0 {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var marker: some View {
        switch block.marker {
        case .bullet: Text("•").foregroundStyle(.secondary)
        case let .number(number): Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
        case let .task(done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .foregroundStyle(done ? Color.accentTheme : Color.secondary)
        case nil: Color.clear.frame(height: 1)
        }
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .paragraph:
            if case .task(done: true) = block.marker {
                Text(block.text).foregroundStyle(.secondary)
            } else {
                Text(block.text).foregroundStyle(block.quoteDepth > 0 ? .secondary : .primary)
            }
        case let .heading(level):
            Text(block.text)
                .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 6 : 2)
        case let .code(language):
            CodeBlockView(code: String(block.text.characters), language: language)
        case .rule:
            Divider().padding(.vertical, 4)
        case let .table(table):
            MarkdownTableView(table: table)
        }
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let language, !language.isEmpty {
                    Text(language).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.callout, design: .monospaced)).fixedSize()
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        Text(cell).fontWeight(.semibold).gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                        }
                    }
                }
            }
            .font(.callout)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard table.alignments.indices.contains(column) else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Editing

/// Lets the toolbar reach the text view inside `MarkdownEditor`.
@MainActor
final class MarkdownEditorHandle {
    fileprivate weak var textView: NSTextView?

    func apply(_ format: MarkdownFormat) {
        guard let textView else { return }
        let edit = format.apply(to: textView.string, selection: textView.selectedRange())
        // Goes through insertText so undo and the delegate both see the change.
        textView.insertText(edit.text, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.setSelectedRange(edit.selection)
        textView.window?.makeFirstResponder(textView)
    }
}

/// A plain-text editor for Markdown. It wraps `NSTextView` because the toolbar needs the selection, which
/// SwiftUI's `TextEditor` does not expose on macOS 14.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let handle: MarkdownEditorHandle
    var focusOnAppear = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: Theme.bodySize)
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        textView.delegate = context.coordinator
        scrollView.drawsBackground = false
        handle.textView = textView
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        handle.textView = textView
        if textView.string != text { textView.string = text }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

struct MarkdownToolbar: View {
    let handle: MarkdownEditorHandle

    var body: some View {
        HStack(spacing: 2) {
            button(.heading, "textformat.size", "Heading")
            button(.bold, "bold", "Bold")
            button(.italic, "italic", "Italic")
            button(.code, "chevron.left.forwardslash.chevron.right", "Inline code")
            button(.link, "link", "Link")
            Divider().frame(height: 14).padding(.horizontal, 3)
            button(.bulletList, "list.bullet", "Bulleted list")
            button(.numberedList, "list.number", "Numbered list")
            button(.taskList, "checklist", "Task list")
            button(.quote, "text.quote", "Quote")
            button(.codeBlock, "curlybraces", "Code block")
        }
        .buttonStyle(.borderless)
    }

    private func button(_ format: MarkdownFormat, _ symbol: String, _ title: String) -> some View {
        Button {
            handle.apply(format)
        } label: {
            Image(systemName: symbol).frame(width: 22, height: 20)
        }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// An issue's description: formatted to read, Markdown with a toolbar to edit. Text is saved on Done, and also when
/// the panel moves to another issue, so an edit is never lost by clicking away.
struct DescriptionSection: View {
    @Environment(AppModel.self) private var model
    let issue: Issue

    @State private var isEditing = false
    @State private var isExpanded = false
    @State private var draft = ""
    /// The description when editing began, to notice an agent changing it meanwhile.
    @State private var base = ""
    @State private var handle = MarkdownEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Description").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if isEditing {
                    Button("Cancel") { isEditing = false }.controlSize(.small)
                    Button("Done") { save() }.controlSize(.small).keyboardShortcut(.return, modifiers: .command)
                } else {
                    Button { beginEditing() } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .help("Edit description")
                }
                Button {
                    if !isEditing { beginEditing() }
                    isExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Edit in a larger window, with a live preview")
            }
            if isEditing, !isExpanded {
                editor
            } else if issue.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { beginEditing() } label: {
                    Text("Add a description in Markdown").foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                MarkdownView(source: issue.description)
            }
        }
        .onDisappear { if isEditing { save() } }
        .sheet(isPresented: $isExpanded) {
            DescriptionSheet(issue: issue, draft: $draft, handle: handle, changedElsewhere: changedElsewhere) {
                isExpanded = false
                save()
            } onCancel: {
                isExpanded = false
                isEditing = false
            } onUseTheirs: {
                useTheirs()
            }
        }
    }

    private var changedElsewhere: Bool { isEditing && issue.description != base && issue.description != draft }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 4) {
            if changedElsewhere { ChangedElsewhereNote(onUseTheirs: useTheirs) }
            MarkdownToolbar(handle: handle)
            MarkdownEditor(text: $draft, handle: handle)
                .frame(minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor).opacity(0.5)))
        }
    }

    private func beginEditing() {
        draft = issue.description
        base = issue.description
        isEditing = true
    }

    private func useTheirs() {
        draft = issue.description
        base = issue.description
    }

    private func save() {
        isEditing = false
        model.setDescription(draft, of: issue.id)
    }
}

private struct ChangedElsewhereNote: View {
    let onUseTheirs: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: Theme.high))
            Text("This description changed while you were editing. Done replaces it with yours.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Use the new one", action: onUseTheirs).controlSize(.small)
        }
    }
}

private struct DescriptionSheet: View {
    let issue: Issue
    @Binding var draft: String
    let handle: MarkdownEditorHandle
    let changedElsewhere: Bool
    let onDone: () -> Void
    let onCancel: () -> Void
    let onUseTheirs: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(issue.identifier).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Text(issue.title).font(.headline).lineLimit(1)
                Spacer()
                MarkdownToolbar(handle: handle)
            }
            .padding(12)
            if changedElsewhere {
                ChangedElsewhereNote(onUseTheirs: onUseTheirs).padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            HSplitView {
                MarkdownEditor(text: $draft, handle: handle)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    MarkdownView(source: draft).padding(14)
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("GitHub-flavored Markdown").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Done", action: onDone).keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 860, idealWidth: 1040, minHeight: 560, idealHeight: 720)
    }
}
