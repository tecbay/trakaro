import Foundation

/// One block of rendered Markdown, flat rather than nested: a list item knows its depth and marker, so the view is
/// a plain column of rows. Inline styles and links are in `text`.
public struct MarkdownBlock: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(Int)
        case code(language: String?)
        case rule
        case table(MarkdownTable)
    }

    public enum Marker: Equatable, Sendable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }

    public let id: Int
    public var kind: Kind
    public var text: AttributedString
    public var listDepth = 0
    public var quoteDepth = 0
    public var marker: Marker?
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public var alignments: [Alignment]
    public var header: [AttributedString]
    public var rows: [[AttributedString]]
}

public enum Markdown {
    /// Links that may stay clickable. Text an agent wrote must not be one click away from opening a local file or
    /// launching an app, so anything else becomes plain text.
    static let linkSchemes: Set<String> = ["http", "https", "mailto", AppLink.scheme]

    /// Parses GitHub-flavored Markdown. Never fails: text that cannot be parsed comes back as a plain paragraph.
    /// `keepingLineBreaks` shows a single newline as a line break, as GitHub does in comments.
    public static func blocks(_ source: String, keepingLineBreaks: Bool = false) -> [MarkdownBlock] {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
        }

        var blocks: [MarkdownBlock] = []
        var seenItems: Set<Int> = []
        var table: (identity: Int, block: MarkdownTable, row: Int?)?

        func finishTable() {
            guard let finished = table else { return }
            blocks.append(MarkdownBlock(id: blocks.count, kind: .table(finished.block), text: AttributedString()))
            table = nil
        }

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let content = sanitized(AttributedString(parsed[range]), keepingLineBreaks: keepingLineBreaks)
            let components = intent?.components ?? []

            if let tableIdentity = components.first(where: { if case .table = $0.kind { true } else { false } })?.identity {
                if table?.identity != tableIdentity {
                    finishTable()
                    table = (tableIdentity, MarkdownTable(alignments: alignments(components), header: [], rows: []), nil)
                }
                addCell(content, components: components, to: &table)
                continue
            }
            finishTable()

            var block = MarkdownBlock(id: blocks.count, kind: .paragraph, text: content)
            for component in components {
                switch component.kind {
                case let .header(level): block.kind = .heading(level)
                case let .codeBlock(language):
                    block.kind = .code(language: language)
                    block.text = trimmedTrailingNewlines(content)
                case .thematicBreak:
                    block.kind = .rule
                    block.text = AttributedString()
                case .blockQuote: block.quoteDepth += 1
                case .listItem: block.listDepth += 1
                default: break
                }
            }
            if let item = components.first(where: { if case .listItem = $0.kind { true } else { false } }),
               seenItems.insert(item.identity).inserted, case let .listItem(ordinal) = item.kind {
                let ordered = components.first { if case .orderedList = $0.kind { true } else if case .unorderedList = $0.kind { true } else { false } }
                if case .orderedList = ordered?.kind {
                    block.marker = .number(ordinal)
                } else {
                    block.marker = .bullet
                    applyTaskMarker(to: &block)
                }
            }
            blocks.append(block)
        }
        finishTable()
        return blocks
    }

    private static func sanitized(_ source: AttributedString, keepingLineBreaks: Bool) -> AttributedString {
        var text = source
        text.presentationIntent = nil
        for run in text.runs.reversed() where keepingLineBreaks && run.inlinePresentationIntent?.contains(.softBreak) == true {
            text.replaceSubrange(run.range, with: AttributedString("\n"))
        }
        for run in text.runs {
            // Images stay as their alt text: the app does not reach out to the network to fetch one.
            if run.imageURL != nil { text[run.range].imageURL = nil }
            if let link = run.link, !linkSchemes.contains(link.scheme?.lowercased() ?? "") { text[run.range].link = nil }
        }
        return text
    }

    private static func applyTaskMarker(to block: inout MarkdownBlock) {
        let plain = String(block.text.characters)
        let done: Bool
        if plain.hasPrefix("[ ] ") {
            done = false
        } else if plain.hasPrefix("[x] ") || plain.hasPrefix("[X] ") {
            done = true
        } else {
            return
        }
        block.marker = .task(done: done)
        block.text.removeSubrange(block.text.startIndex..<block.text.index(block.text.startIndex, offsetByCharacters: 4))
    }

    private static func trimmedTrailingNewlines(_ source: AttributedString) -> AttributedString {
        var text = source
        while text.characters.last?.isNewline == true {
            text.removeSubrange(text.index(text.endIndex, offsetByCharacters: -1)..<text.endIndex)
        }
        return text
    }

    private static func alignments(_ components: [PresentationIntent.IntentType]) -> [MarkdownTable.Alignment] {
        for component in components {
            if case let .table(columns) = component.kind {
                return columns.map { column in
                    switch column.alignment {
                    case .center: .center
                    case .right: .trailing
                    default: .leading
                    }
                }
            }
        }
        return []
    }

    private static func addCell(
        _ content: AttributedString, components: [PresentationIntent.IntentType], to table: inout (identity: Int, block: MarkdownTable, row: Int?)?
    ) {
        var column = 0
        var isHeader = false
        var rowNumber = 0
        for component in components {
            switch component.kind {
            case let .tableCell(index): column = index
            case .tableHeaderRow: isHeader = true
            case let .tableRow(index): rowNumber = index
            default: break
            }
        }
        func place(_ cells: inout [AttributedString]) {
            while cells.count <= column { cells.append(AttributedString()) }
            cells[column].append(content)
        }
        if isHeader {
            place(&table!.block.header)
            return
        }
        if table?.row != rowNumber {
            table!.block.rows.append([])
            table!.row = rowNumber
        }
        let last = table!.block.rows.count - 1
        place(&table!.block.rows[last])
    }
}

/// What the description editor's toolbar does to the text. Works on UTF-16 ranges, as `NSTextView` does.
public enum MarkdownFormat: String, CaseIterable, Sendable {
    case bold, italic, code, link, heading, bulletList, numberedList, taskList, quote, codeBlock

    public struct Edit: Equatable, Sendable {
        public let text: String
        public let selection: NSRange

        public init(text: String, selection: NSRange) {
            self.text = text
            self.selection = selection
        }
    }

    public func apply(to text: String, selection: NSRange) -> Edit {
        switch self {
        case .bold: wrap(text, selection, with: "**", placeholder: "bold")
        case .italic: wrap(text, selection, with: "*", placeholder: "italic")
        case .code: wrap(text, selection, with: "`", placeholder: "code")
        case .link: link(text, selection)
        case .heading: prefixLines(text, selection) { _ in "## " }
        case .bulletList: prefixLines(text, selection) { _ in "- " }
        case .numberedList: prefixLines(text, selection) { "\($0 + 1). " }
        case .taskList: prefixLines(text, selection) { _ in "- [ ] " }
        case .quote: prefixLines(text, selection) { _ in "> " }
        case .codeBlock: codeBlock(text, selection)
        }
    }

    /// Wraps the selection, or removes the wrapping when it is already there.
    private func wrap(_ text: String, _ selection: NSRange, with mark: String, placeholder: String) -> Edit {
        let source = text as NSString
        let length = (mark as NSString).length
        let selected = source.substring(with: selection)
        let before = selection.location >= length ? source.substring(with: NSRange(location: selection.location - length, length: length)) : ""
        let afterStart = NSMaxRange(selection)
        let after = afterStart + length <= source.length ? source.substring(with: NSRange(location: afterStart, length: length)) : ""
        if before == mark, after == mark {
            let outer = NSRange(location: selection.location - length, length: selection.length + 2 * length)
            return Edit(text: source.replacingCharacters(in: outer, with: selected),
                        selection: NSRange(location: outer.location, length: selection.length))
        }
        let inner = selected.isEmpty ? placeholder : selected
        return Edit(text: source.replacingCharacters(in: selection, with: "\(mark)\(inner)\(mark)"),
                    selection: NSRange(location: selection.location + length, length: (inner as NSString).length))
    }

    private func link(_ text: String, _ selection: NSRange) -> Edit {
        let source = text as NSString
        let title = selection.length > 0 ? source.substring(with: selection) : "title"
        let url = "https://"
        let insertion = "[\(title)](\(url))"
        let urlStart = selection.location + (title as NSString).length + 3
        return Edit(text: source.replacingCharacters(in: selection, with: insertion),
                    selection: NSRange(location: urlStart + (url as NSString).length, length: 0))
    }

    /// Adds a prefix to each selected line, or removes it when every line already has it.
    private func prefixLines(_ text: String, _ selection: NSRange, prefix: (Int) -> String) -> Edit {
        let source = text as NSString
        let lineRange = source.lineRange(for: selection)
        let block = source.substring(with: lineRange)
        let endsWithNewline = block.hasSuffix("\n")
        let lines = (endsWithNewline ? String(block.dropLast()) : block).components(separatedBy: "\n")
        let prefixes = lines.indices.map(prefix)
        let hasAll = zip(lines, prefixes).allSatisfy { $0.hasPrefix($1) }
        let changed = zip(lines, prefixes).map { hasAll ? String($0.dropFirst($1.count)) : $1 + $0 }
        let replacement = changed.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        let result = source.replacingCharacters(in: lineRange, with: replacement)
        let contentLength = (changed.joined(separator: "\n") as NSString).length
        return Edit(text: result, selection: selection.length == 0
            ? NSRange(location: lineRange.location + contentLength, length: 0)
            : NSRange(location: lineRange.location, length: contentLength))
    }

    private func codeBlock(_ text: String, _ selection: NSRange) -> Edit {
        let source = text as NSString
        let inner = selection.length > 0 ? source.substring(with: selection) : "code"
        let leading = selection.location > 0 && source.character(at: selection.location - 1) != 10 ? "\n" : ""
        let end = NSMaxRange(selection)
        let trailing = end < source.length && source.character(at: end) != 10 ? "\n" : ""
        let opening = "\(leading)```\n"
        let replacement = "\(opening)\(inner)\n```\(trailing)"
        return Edit(text: source.replacingCharacters(in: selection, with: replacement),
                    selection: NSRange(location: selection.location + (opening as NSString).length, length: (inner as NSString).length))
    }
}
