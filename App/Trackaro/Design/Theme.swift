import AppKit
import SwiftUI
import TrackaroCore

/// Design tokens. System semantic colors carry text and surfaces so the app looks native in light and dark;
/// these add the accent, priority and agent colors on top. Every color adapts to the appearance.
enum Theme {
    static let accent = NSColor.dynamic(light: 0x4D57BD, dark: 0x7B83EB)
    static let accentSoft = NSColor.dynamic(light: 0xE6E8FA, dark: 0x1E2140)
    static let agent = NSColor.dynamic(light: 0x8E4EC6, dark: 0xB58AF2)
    static let urgent = NSColor.dynamic(light: 0xC33C41, dark: 0xE5484D)
    static let high = NSColor.dynamic(light: 0x96570C, dark: 0xF2C94C)
    static let danger = NSColor.dynamic(light: 0xBA3237, dark: 0xEA5A5F)

    static let rowHeight: CGFloat = 32
    static let groupRowHeight: CGFloat = 30
    static let bodySize: CGFloat = 13

    static func priorityColor(_ priority: Priority) -> NSColor {
        switch priority {
        case .urgent: urgent
        case .high: high
        case .medium: accent
        case .low, .none: .secondaryLabelColor
        }
    }

    /// A workflow state's stored color, falling back to grey for anything unparseable.
    static func stateColor(_ hex: String) -> NSColor {
        NSColor(hexString: hex) ?? .secondaryLabelColor
    }
}

enum Symbols {
    static func state(_ category: StateCategory) -> String {
        switch category {
        case .triage: "exclamationmark.circle"
        case .backlog: "circle.dashed"
        case .unstarted: "circle"
        case .started: "circle.lefthalf.filled"
        case .review: "circle.righthalf.filled"
        case .completed: "checkmark.circle.fill"
        case .canceled: "xmark.circle.fill"
        }
    }

    /// Bars that fill with priority; urgent gets its own glyph so it reads at a glance.
    static func priority(_ priority: Priority) -> (name: String, fill: Double?) {
        switch priority {
        case .urgent: ("exclamationmark.square.fill", nil)
        case .high: ("cellularbars", 1.0)
        case .medium: ("cellularbars", 0.66)
        case .low: ("cellularbars", 0.33)
        case .none: ("ellipsis", nil)
        }
    }

    static func image(_ name: String, fill: Double? = nil, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSImage? {
        let image = fill.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return image?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }
}

extension NSColor {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    convenience init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

extension Color {
    static let accentTheme = Color(nsColor: Theme.accent)
    static let agent = Color(nsColor: Theme.agent)
}

/// Relative times like "2 min ago", shared by the list and the activity feed.
enum RelativeTime {
    @MainActor private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    @MainActor static func string(_ date: Date, now: Date = Date()) -> String {
        now.timeIntervalSince(date) < 45 ? "just now" : formatter.localizedString(for: date, relativeTo: now)
    }
}
