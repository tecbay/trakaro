import Foundation

/// Every command in the app. The keyboard layer, the command palette and the `?` overlay all read this one list,
/// and the app switches over it exhaustively, so a command cannot exist without an action or a shortcut drift
/// out of the overlay.
public enum AppCommand: String, CaseIterable, Sendable {
    case palette, shortcuts, newIssue, toggleLayout, toggleSidebar, toggleInspector, undo, redo
    case goMyIssues, goAgentActivity, goIssues, goActive, goBacklog
    case next, previous, extendDown, extendUp, toggleSelect, open, clearSelection
    case cardUp, cardDown, columnLeft, columnRight, moveToPreviousStatus, moveToNextStatus
    case setStatus, setPriority, setAssignee, setLabels, setEstimate, assignToMe, copyIdentifier, archive

    public var definition: KeyCommand {
        switch self {
        case .palette: KeyCommand(rawValue, "Command palette", section: "General", binding: "cmd+k", worksInTextFields: true, inPalette: false)
        case .shortcuts: KeyCommand(rawValue, "Keyboard shortcuts", section: "General", binding: "?")
        case .newIssue: KeyCommand(rawValue, "New issue", section: "General", binding: "c")
        case .toggleLayout: KeyCommand(rawValue, "Switch between board and list", section: "General", binding: "cmd+b")
        case .toggleSidebar: KeyCommand(rawValue, "Toggle sidebar", section: "General", binding: "[")
        case .toggleInspector: KeyCommand(rawValue, "Toggle details panel", section: "General", binding: "]")
        case .undo: KeyCommand(rawValue, "Undo", section: "General", binding: "cmd+z")
        case .redo: KeyCommand(rawValue, "Redo", section: "General", binding: "shift+cmd+z")

        case .goMyIssues: KeyCommand(rawValue, "Go to My issues", section: "Navigation", binding: "g m")
        case .goAgentActivity: KeyCommand(rawValue, "Go to Agent activity", section: "Navigation", binding: "g a")
        case .goIssues: KeyCommand(rawValue, "Go to team issues", section: "Navigation", binding: "g i")
        case .goActive: KeyCommand(rawValue, "Go to active issues", section: "Navigation", binding: "g t")
        case .goBacklog: KeyCommand(rawValue, "Go to backlog", section: "Navigation", binding: "g b")

        case .next: KeyCommand(rawValue, "Next issue", section: "List", binding: "j", scope: .list, inPalette: false)
        case .previous: KeyCommand(rawValue, "Previous issue", section: "List", binding: "k", scope: .list, inPalette: false)
        case .extendDown: KeyCommand(rawValue, "Extend selection down", section: "List", binding: "shift+j", scope: .list, inPalette: false)
        case .extendUp: KeyCommand(rawValue, "Extend selection up", section: "List", binding: "shift+k", scope: .list, inPalette: false)
        case .toggleSelect: KeyCommand(rawValue, "Select or deselect", section: "List", binding: "x", scope: .list, inPalette: false)
        case .open: KeyCommand(rawValue, "Open issue", section: "List", binding: "enter", scope: .list, inPalette: false)
        case .clearSelection: KeyCommand(rawValue, "Clear selection", section: "List", binding: "escape", scope: .list, inPalette: false)

        case .cardUp: KeyCommand(rawValue, "Card above", section: "Board", binding: "up", scope: .list, inPalette: false)
        case .cardDown: KeyCommand(rawValue, "Card below", section: "Board", binding: "down", scope: .list, inPalette: false)
        case .columnLeft: KeyCommand(rawValue, "Column to the left", section: "Board", binding: "left", scope: .list, inPalette: false)
        case .columnRight: KeyCommand(rawValue, "Column to the right", section: "Board", binding: "right", scope: .list, inPalette: false)
        case .moveToPreviousStatus: KeyCommand(rawValue, "Move to previous status", section: "Board", binding: "shift+left", scope: .list)
        case .moveToNextStatus: KeyCommand(rawValue, "Move to next status", section: "Board", binding: "shift+right", scope: .list)

        case .setStatus: KeyCommand(rawValue, "Change status", section: "Issue", binding: "s", scope: .list)
        case .setPriority: KeyCommand(rawValue, "Change priority", section: "Issue", binding: "p", scope: .list)
        case .setAssignee: KeyCommand(rawValue, "Assign to", section: "Issue", binding: "a", scope: .list)
        case .setLabels: KeyCommand(rawValue, "Change labels", section: "Issue", binding: "l", scope: .list)
        case .setEstimate: KeyCommand(rawValue, "Set estimate", section: "Issue", binding: "shift+e", scope: .list)
        case .assignToMe: KeyCommand(rawValue, "Assign to me", section: "Issue", binding: "i", scope: .list)
        case .copyIdentifier: KeyCommand(rawValue, "Copy issue identifier", section: "Issue", binding: "shift+cmd+c", scope: .list)
        case .archive: KeyCommand(rawValue, "Archive", section: "Issue", binding: "cmd+backspace", scope: .list)
        }
    }

    public static var catalog: [KeyCommand] { allCases.map(\.definition) }

    /// Section order for the shortcuts overlay.
    public static let sections = ["General", "Navigation", "List", "Board", "Issue"]
}
