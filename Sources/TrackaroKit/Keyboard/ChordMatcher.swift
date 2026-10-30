import Foundation

/// Where a shortcut applies. A higher priority wins when two commands share a binding.
public struct KeyScope: Hashable, Sendable {
    public let name: String
    public let priority: Int

    public static let global = KeyScope(name: "global", priority: 0)
    public static let list = KeyScope(name: "list", priority: 10)
}

/// A command the keyboard, the palette and the shortcuts overlay all read from. The app maps `id` to an action.
public struct KeyCommand: Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let section: String
    public let binding: KeyBinding?
    public let scope: KeyScope
    /// True for the few shortcuts that must work while typing, such as the command palette.
    public let worksInTextFields: Bool
    /// False hides it from the palette, for commands that only make sense as a key (moving the cursor).
    public let inPalette: Bool

    public init(_ id: String, _ title: String, section: String, binding: String?, scope: KeyScope = .global,
                worksInTextFields: Bool = false, inPalette: Bool = true) {
        self.id = id
        self.title = title
        self.section = section
        self.binding = binding.flatMap(KeyBinding.init)
        self.scope = scope
        self.worksInTextFields = worksInTextFields
        self.inPalette = inPalette
    }
}

/// Turns key presses into commands, including multi-key sequences.
///
/// Rules, in order: a sequence that could still grow into a longer binding waits for the next key; among exact
/// matches the higher-priority scope wins, then the one with more modifiers. A key that breaks a sequence is
/// retried on its own, so `g` followed by `x` still runs `x`. A sequence older than `chordTimeout` is forgotten.
public struct ChordMatcher: Sendable {
    public enum Outcome: Equatable, Sendable {
        case run(String)
        case pending
        case unhandled
    }

    public static let chordTimeout: TimeInterval = 1.2

    public let commands: [KeyCommand]
    private var buffer: [KeyStroke] = []
    private var bufferStarted: Date?

    public init(commands: [KeyCommand]) {
        self.commands = commands.filter { $0.binding != nil }
    }

    public var isPending: Bool { !buffer.isEmpty }

    public mutating func reset() {
        buffer = []
        bufferStarted = nil
    }

    public mutating func handle(
        _ stroke: KeyStroke, scopes: Set<KeyScope>, typing: Bool = false,
        isEnabled: (String) -> Bool = { _ in true }, now: Date = Date()
    ) -> Outcome {
        if let started = bufferStarted, now.timeIntervalSince(started) > Self.chordTimeout { reset() }
        let candidates = commands.filter {
            scopes.contains($0.scope) && (!typing || $0.worksInTextFields) && isEnabled($0.id)
        }
        if let outcome = resolve(buffer + [stroke], among: candidates, now: now) { return outcome }
        if !buffer.isEmpty {
            reset()
            if let outcome = resolve([stroke], among: candidates, now: now) { return outcome }
        }
        reset()
        return .unhandled
    }

    private mutating func resolve(_ sequence: [KeyStroke], among candidates: [KeyCommand], now: Date) -> Outcome? {
        let canGrow = candidates.contains {
            guard let strokes = $0.binding?.strokes else { return false }
            return strokes.count > sequence.count && strokes.starts(with: sequence)
        }
        if canGrow {
            if buffer.isEmpty { bufferStarted = now }
            buffer = sequence
            return .pending
        }
        let exact = candidates.filter { $0.binding?.strokes == sequence }
        let best = exact.max {
            ($0.scope.priority, $0.binding?.strokes.last?.modifiers.count ?? 0)
                < ($1.scope.priority, $1.binding?.strokes.last?.modifiers.count ?? 0)
        }
        guard let best else { return nil }
        reset()
        return .run(best.id)
    }

    /// Pairs of commands that share a binding in the same scope. Should always be empty.
    public static func conflicts(in commands: [KeyCommand]) -> [(String, String)] {
        var seen: [String: String] = [:]
        var conflicts: [(String, String)] = []
        for command in commands {
            guard let binding = command.binding else { continue }
            let key = "\(command.scope.name) \(binding)"
            if let other = seen[key] { conflicts.append((other, command.id)) } else { seen[key] = command.id }
        }
        return conflicts
    }
}
