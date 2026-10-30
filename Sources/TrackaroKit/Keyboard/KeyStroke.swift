import Foundation

/// One key press, normalised so a binding written as text matches what the keyboard sends.
///
/// Letters are stored lowercase with Shift as a modifier (`shift+e`). Other printable characters already carry
/// Shift in the character itself (`?` is Shift+/), so Shift is dropped for them and `?` is bound as `?`.
public struct KeyStroke: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)

        var count: Int { [Modifiers.command, .shift, .option, .control].filter(contains).count }
    }

    /// A lowercase character, or a named key from `NamedKey`.
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        let lowered = key.lowercased()
        self.key = lowered
        let isLetter = lowered.count == 1 && lowered.first?.isLetter == true
        let isNamed = NamedKey(rawValue: lowered) != nil
        self.modifiers = (isLetter || isNamed) ? modifiers : modifiers.subtracting(.shift)
    }

    /// Parses `cmd+k`, `shift+e`, `?`, `enter`. Returns nil for empty or unknown modifier names.
    public init?(parsing text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { return nil }
        let key = last.isEmpty && text.hasSuffix("+") ? "+" : last
        guard !key.isEmpty else { return nil }
        var modifiers: Modifiers = []
        for name in parts.dropLast() where !name.isEmpty {
            switch name {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default: return nil
            }
        }
        self.init(key, modifiers)
    }

    /// Builds a stroke from what AppKit reports: `charactersIgnoringModifiers`, the modifier flags and the key code.
    public static func fromEvent(characters: String?, keyCode: UInt16, modifiers: Modifiers) -> KeyStroke? {
        if let named = NamedKey(keyCode: keyCode) { return KeyStroke(named.rawValue, modifiers) }
        guard let characters, let first = characters.first, characters.count == 1 else { return nil }
        return KeyStroke(String(first), modifiers)
    }

    /// Display form, such as `⌘K`, `⇧E`, `?`, `↵`.
    public var description: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + (NamedKey(rawValue: key)?.symbol ?? key.uppercased())
    }
}

public enum NamedKey: String, CaseIterable, Sendable {
    case enter, escape, space, tab, backspace, delete, up, down, left, right

    init?(keyCode: UInt16) {
        switch keyCode {
        case 36, 76: self = .enter
        case 53: self = .escape
        case 49: self = .space
        case 48: self = .tab
        case 51: self = .backspace
        case 117: self = .delete
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .enter: "↵"
        case .escape: "Esc"
        case .space: "Space"
        case .tab: "⇥"
        case .backspace: "⌫"
        case .delete: "⌦"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        }
    }
}

/// A key or a sequence of keys pressed one after another, such as `g m`.
public struct KeyBinding: Hashable, Sendable, CustomStringConvertible {
    public let strokes: [KeyStroke]

    public init(_ strokes: [KeyStroke]) {
        self.strokes = strokes
    }

    /// Space-separated strokes: `"g m"`, `"cmd+k"`, `"shift+e"`.
    public init?(_ text: String) {
        let parts = text.split(separator: " ").map(String.init)
        let strokes = parts.compactMap(KeyStroke.init(parsing:))
        guard !strokes.isEmpty, strokes.count == parts.count else { return nil }
        self.init(strokes)
    }

    public var description: String {
        strokes.map(\.description).joined(separator: " ")
    }
}
