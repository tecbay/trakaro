import Foundation
import Testing
@testable import TrackaroKit

@Suite("Markdown rendering")
struct MarkdownTests {
    private func plain(_ block: MarkdownBlock) -> String { String(block.text.characters) }

    @Test func headingsParagraphsAndLineBreaks() {
        let blocks = Markdown.blocks("# Title\n\n## Sub\n\nOne line\nsame paragraph\n\nNext")
        #expect(blocks.map(\.kind) == [.heading(1), .heading(2), .paragraph, .paragraph])
        #expect(plain(blocks[0]) == "Title")
        #expect(plain(blocks[2]).contains("One line"))
        #expect(plain(blocks[2]).contains("same paragraph"))
        #expect(blocks[3].id != blocks[2].id)
    }

    @Test func commentsKeepTheirLineBreaks() {
        #expect(plain(Markdown.blocks("one\ntwo")[0]) == "one two")
        #expect(plain(Markdown.blocks("one\ntwo", keepingLineBreaks: true)[0]) == "one\ntwo")
    }

    @Test func inlineStylesAndLinksSurvive() {
        let block = Markdown.blocks("Use **bold**, *it*, `code` and [a link](https://example.com).")[0]
        let intents = block.text.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
        #expect(intents.contains(.code))
        #expect(block.text.runs.compactMap(\.link).map(\.absoluteString) == ["https://example.com"])
    }

    @Test(arguments: ["file:///Applications/Calculator.app", "x-apple.systempreferences:foo", "ssh://host"])
    func linksThatCouldTouchTheMacBecomePlainText(url: String) {
        let block = Markdown.blocks("[click me](\(url))")[0]
        #expect(plain(block) == "click me")
        #expect(block.text.runs.allSatisfy { $0.link == nil })
    }

    @Test(arguments: ["https://example.com", "mailto:a@example.com", "trackaro://issue/ENG-1"])
    func usefulLinksStay(url: String) {
        #expect(Markdown.blocks("[go](\(url))")[0].text.runs.contains { $0.link?.absoluteString == url })
    }

    @Test func imagesStayAsAltTextSoNothingIsFetched() {
        let block = Markdown.blocks("![the diagram](https://example.com/tracker.png)")[0]
        #expect(plain(block) == "the diagram")
        #expect(block.text.runs.allSatisfy { $0.imageURL == nil })
    }

    @Test func listsKeepOrderDepthAndMarkers() {
        let blocks = Markdown.blocks("- one\n- two\n  - nested\n\n1. first\n2. second")
        #expect(blocks.map(plain) == ["one", "two", "nested", "first", "second"])
        #expect(blocks.map(\.listDepth) == [1, 1, 2, 1, 1])
        #expect(blocks.map(\.marker) == [.bullet, .bullet, .bullet, .number(1), .number(2)])
    }

    @Test func taskLists() {
        let blocks = Markdown.blocks("- [ ] open\n- [x] done\n- [X] also done\n- [nope] plain")
        #expect(blocks.map(\.marker) == [.task(done: false), .task(done: true), .task(done: true), .bullet])
        #expect(blocks.map(plain) == ["open", "done", "also done", "[nope] plain"])
    }

    @Test func codeBlocksKeepTheirTextAndLanguage() {
        let block = Markdown.blocks("```swift\nlet a = 1\n\nlet b = 2\n```")[0]
        #expect(block.kind == .code(language: "swift"))
        #expect(plain(block) == "let a = 1\n\nlet b = 2")
    }

    @Test func quotesAndRules() {
        let blocks = Markdown.blocks("> Said\n\n---\n\nAfter")
        #expect(blocks.first?.quoteDepth == 1)
        #expect(plain(blocks[0]) == "Said")
        #expect(blocks.contains { $0.kind == .rule })
        #expect(blocks.last.map(plain) == "After")
    }

    @Test func tablesKeepRowsColumnsAndAlignment() throws {
        let blocks = Markdown.blocks("""
            Before

            | Name | Count | Done |
            | :--- | :---: | ---: |
            | **a** | 1 | yes |
            | b | 2 | no |

            After
            """)
        #expect(blocks.count == 3)
        guard case let .table(table) = blocks[1].kind else {
            Issue.record("Expected a table, got \(blocks[1].kind)")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.header.map { String($0.characters) } == ["Name", "Count", "Done"])
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["a", "1", "yes"], ["b", "2", "no"]])
        #expect(blocks[2].id > blocks[1].id)
    }

    @Test(arguments: ["", "   \n\n "])
    func nothingToShow(source: String) {
        #expect(Markdown.blocks(source).isEmpty)
    }

    @Test func oddInputNeverLosesItsText() {
        let source = "<div>raw</div> **unclosed [link]( and `tick"
        #expect(Markdown.blocks(source).map(plain).joined().contains("unclosed"))
    }
}

@Suite("Markdown toolbar")
struct MarkdownFormatTests {
    private func apply(_ format: MarkdownFormat, _ text: String, _ location: Int, _ length: Int = 0) -> MarkdownFormat.Edit {
        format.apply(to: text, selection: NSRange(location: location, length: length))
    }

    @Test func boldWrapsTheSelectionAndKeepsItSelected() {
        let edit = apply(.bold, "make this strong", 10, 6)
        #expect(edit.text == "make this **strong**")
        #expect(edit.selection == NSRange(location: 12, length: 6))
    }

    @Test func boldAgainRemovesIt() {
        let on = apply(.bold, "a word", 2, 4)
        let off = MarkdownFormat.bold.apply(to: on.text, selection: on.selection)
        #expect(off.text == "a word")
        #expect(off.selection == NSRange(location: 2, length: 4))
    }

    @Test func withNoSelectionAPlaceholderIsSelected() {
        let edit = apply(.code, "x ", 2)
        #expect(edit.text == "x `code`")
        #expect(edit.selection == NSRange(location: 3, length: 4))
    }

    @Test func linkPutsTheCursorInTheAddress() {
        let edit = apply(.link, "see docs", 4, 4)
        #expect(edit.text == "see [docs](https://)")
        #expect(edit.selection == NSRange(location: 19, length: 0))
    }

    @Test func listsApplyToEverySelectedLineAndToggleOff() {
        let on = apply(.bulletList, "one\ntwo\nthree", 0, 7)
        #expect(on.text == "- one\n- two\nthree")
        let off = MarkdownFormat.bulletList.apply(to: on.text, selection: on.selection)
        #expect(off.text == "one\ntwo\nthree")
    }

    @Test func numberedAndTaskListsAndHeadings() {
        #expect(apply(.numberedList, "a\nb", 0, 3).text == "1. a\n2. b")
        #expect(apply(.taskList, "todo", 2).text == "- [ ] todo")
        #expect(apply(.heading, "one\ntwo", 5).text == "one\n## two")
        #expect(apply(.quote, "said", 0).text == "> said")
    }

    @Test func aCodeBlockStartsOnItsOwnLine() {
        let edit = apply(.codeBlock, "before after", 7, 5)
        #expect(edit.text == "before \n```\nafter\n```")
        #expect(edit.selection == NSRange(location: 12, length: 5))
    }

    @Test func emojiDoNotBreakRanges() {
        let edit = apply(.bold, "🚀 go", 3, 2)
        #expect(edit.text == "🚀 **go**")
    }
}
