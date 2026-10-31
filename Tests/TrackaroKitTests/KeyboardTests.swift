import Foundation
import Testing
@testable import TrackaroKit

@Suite("Key strokes and bindings")
struct KeyStrokeTests {
    @Test func parsesModifiersAndNormalisesShift() {
        #expect(KeyStroke(parsing: "cmd+k") == KeyStroke("k", .command))
        #expect(KeyStroke(parsing: "Shift+E") == KeyStroke("e", .shift))
        #expect(KeyStroke(parsing: "shift+?") == KeyStroke("?"))
        #expect(KeyStroke(parsing: "shift+cmd+z") == KeyStroke("z", [.shift, .command]))
        #expect(KeyStroke(parsing: "hyper+k") == nil)
        #expect(KeyStroke(parsing: "") == nil)
    }

    @Test func eventsMapToTheSameStrokesAsBindings() {
        #expect(KeyStroke.fromEvent(characters: "K", keyCode: 40, modifiers: [.shift]) == KeyStroke(parsing: "shift+k"))
        #expect(KeyStroke.fromEvent(characters: "?", keyCode: 44, modifiers: [.shift]) == KeyStroke(parsing: "?"))
        #expect(KeyStroke.fromEvent(characters: "\r", keyCode: 36, modifiers: []) == KeyStroke(parsing: "enter"))
        #expect(KeyStroke.fromEvent(characters: "\u{7f}", keyCode: 51, modifiers: [.command]) == KeyStroke(parsing: "cmd+backspace"))
        #expect(KeyStroke.fromEvent(characters: "", keyCode: 200, modifiers: []) == nil)
    }

    @Test func displaysWithMacGlyphs() {
        #expect(KeyBinding("shift+cmd+z")?.description == "⇧⌘Z")
        #expect(KeyBinding("g m")?.description == "G M")
        #expect(KeyBinding("enter")?.description == "↵")
        #expect(KeyBinding("g  m") != nil)
    }
}

@Suite("Chord matcher")
struct ChordMatcherTests {
    let commands = [
        KeyCommand("palette", "Palette", section: "", binding: "cmd+k", worksInTextFields: true),
        KeyCommand("new", "New", section: "", binding: "c"),
        KeyCommand("goMine", "Go mine", section: "", binding: "g m"),
        KeyCommand("goBacklog", "Go backlog", section: "", binding: "g b"),
        KeyCommand("status", "Status", section: "", binding: "s", scope: .list),
        KeyCommand("globalS", "Global s", section: "", binding: "s"),
        KeyCommand("estimate", "Estimate", section: "", binding: "shift+e", scope: .list),
    ]

    @Test func runsSingleKeys() {
        var matcher = ChordMatcher(commands: commands)
        #expect(matcher.handle(KeyStroke("c"), scopes: [.global]) == .run("new"))
        #expect(matcher.handle(KeyStroke("z"), scopes: [.global]) == .unhandled)
    }

    @Test func waitsForSequencesAndCompletesThem() {
        var matcher = ChordMatcher(commands: commands)
        let start = Date()
        #expect(matcher.handle(KeyStroke("g"), scopes: [.global], now: start) == .pending)
        #expect(matcher.handle(KeyStroke("m"), scopes: [.global], now: start.addingTimeInterval(0.3)) == .run("goMine"))
        #expect(!matcher.isPending)
    }

    @Test func aBrokenSequenceRetriesTheNewKey() {
        var matcher = ChordMatcher(commands: commands)
        #expect(matcher.handle(KeyStroke("g"), scopes: [.global]) == .pending)
        #expect(matcher.handle(KeyStroke("c"), scopes: [.global]) == .run("new"))
    }

    @Test func staleSequencesAreForgotten() {
        var matcher = ChordMatcher(commands: commands)
        let start = Date()
        #expect(matcher.handle(KeyStroke("g"), scopes: [.global], now: start) == .pending)
        #expect(matcher.handle(KeyStroke("m"), scopes: [.global], now: start.addingTimeInterval(2)) == .unhandled)
    }

    @Test func higherPriorityScopeWins() {
        var matcher = ChordMatcher(commands: commands)
        #expect(matcher.handle(KeyStroke("s"), scopes: [.global, .list]) == .run("status"))
        #expect(matcher.handle(KeyStroke("s"), scopes: [.global]) == .run("globalS"))
    }

    @Test func modifiersMustMatchExactly() {
        var matcher = ChordMatcher(commands: commands)
        #expect(matcher.handle(KeyStroke("e"), scopes: [.list]) == .unhandled)
        #expect(matcher.handle(KeyStroke("e", .shift), scopes: [.list]) == .run("estimate"))
    }

    @Test func onlyTextFieldSafeCommandsRunWhileTyping() {
        var matcher = ChordMatcher(commands: commands)
        #expect(matcher.handle(KeyStroke("c"), scopes: [.global], typing: true) == .unhandled)
        #expect(matcher.handle(KeyStroke("k", .command), scopes: [.global], typing: true) == .run("palette"))
    }

    @Test func disabledCommandsAreSkipped() {
        var matcher = ChordMatcher(commands: commands)
        #expect(matcher.handle(KeyStroke("c"), scopes: [.global], isEnabled: { $0 != "new" }) == .unhandled)
    }

    @Test func appCatalogHasNoConflictsAndEveryBindingParses() {
        let catalog = AppCommand.catalog
        #expect(ChordMatcher.conflicts(in: catalog).isEmpty)
        #expect(catalog.allSatisfy { $0.binding != nil || $0.inPalette })
        #expect(Set(catalog.map(\.section)).isSubset(of: Set(AppCommand.sections)))
        #expect(ChordMatcher.conflicts(in: catalog + [KeyCommand("dup", "Dup", section: "", binding: "c")]).count == 1)
    }

    @Test func appCatalogRoutesTheDocumentedKeys() {
        var matcher = ChordMatcher(commands: AppCommand.catalog)
        let scopes: Set<KeyScope> = [.global, .list]
        #expect(matcher.handle(KeyStroke("g"), scopes: scopes) == .pending)
        #expect(matcher.handle(KeyStroke("a"), scopes: scopes) == .run(AppCommand.goAgentActivity.rawValue))
        #expect(matcher.handle(KeyStroke("a"), scopes: scopes) == .run(AppCommand.setAssignee.rawValue))
        #expect(matcher.handle(KeyStroke("?"), scopes: scopes) == .run(AppCommand.shortcuts.rawValue))
        #expect(matcher.handle(KeyStroke("backspace", .command), scopes: scopes) == .run(AppCommand.archive.rawValue))
        #expect(matcher.handle(KeyStroke("j"), scopes: [.global]) == .unhandled)
    }
}

@Suite("Fuzzy matching")
struct FuzzyMatchTests {
    @Test func matchesSubsequencesAndRejectsOthers() {
        #expect(FuzzyMatch.score("gmy", in: "Go to My issues") != nil)
        #expect(FuzzyMatch.score("go my", in: "Go to My issues") != nil)
        #expect(FuzzyMatch.score("xyz", in: "Go to My issues") == nil)
        #expect(FuzzyMatch.score("", in: "anything") == 0)
    }

    @Test func prefersPrefixesWordStartsAndShortText() {
        let ranked = FuzzyMatch.rank(["Change priority", "Go to project", "Copy issue identifier", "Change status"], query: "ch") { $0 }
        #expect(ranked.prefix(2) == ["Change status", "Change priority"])
        let words = FuzzyMatch.rank(["Toggle sidebar", "Keyboard shortcuts"], query: "ks") { $0 }
        #expect(words.first == "Keyboard shortcuts")
        #expect(FuzzyMatch.rank(["b", "a"], query: " ") { $0 } == ["b", "a"])
    }
}
