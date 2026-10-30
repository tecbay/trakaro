import AppKit
import TrackaroKit

/// Routes key presses to commands before AppKit dispatches them.
///
/// A local event monitor sees every key-down in the app first. While the user types in a text field, only
/// commands marked `worksInTextFields` (the palette) are considered and everything else goes to the field.
/// While an overlay is open, the arrow keys, Return and Escape drive it and typing goes to its search field.
/// While a sheet is up, the sheet owns the keyboard.
@MainActor
final class KeyboardController {
    private weak var model: AppModel?
    private var matcher = ChordMatcher(commands: AppCommand.catalog)
    private var monitor: Any?

    func install(on model: AppModel) {
        self.model = model
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let pressed = event
            let consumed = MainActor.assumeIsolated { self?.consumes(pressed) ?? false }
            return consumed ? nil : event
        }
    }

    /// True when the press ran a command or continued a sequence, so AppKit should not see it.
    private func consumes(_ event: NSEvent) -> Bool {
        guard let model, let window = event.window, window.isKeyWindow, window.attachedSheet == nil,
              !model.quickCreatePresented, !(window is NSPanel) else { return false }
        guard let stroke = KeyStroke.fromEvent(
            characters: event.charactersIgnoringModifiers, keyCode: event.keyCode, modifiers: Self.modifiers(of: event)
        ) else { return false }

        if let overlay = model.overlay {
            return handleOverlay(overlay, stroke: stroke, model: model)
        }

        let typing = window.firstResponder is NSText
        let outcome = matcher.handle(stroke, scopes: [.global, .list], typing: typing) { id in
            AppCommand(rawValue: id).map(model.canPerform) ?? false
        }
        switch outcome {
        case let .run(id):
            if let command = AppCommand(rawValue: id) { model.perform(command) }
            return true
        case .pending:
            return true
        case .unhandled:
            return false
        }
    }

    private func handleOverlay(_ overlay: AppModel.Overlay, stroke: KeyStroke, model: AppModel) -> Bool {
        let plain = stroke.modifiers.isEmpty
        switch (stroke.key, overlay) {
        case ("escape", _):
            model.overlay = nil
            return true
        case ("k", .palette) where stroke.modifiers == .command:
            model.overlay = nil
            return true
        case ("?", .shortcuts):
            model.overlay = nil
            return true
        case ("down", _) where plain, ("n", _) where stroke.modifiers == .control:
            model.moveOverlaySelection(by: 1)
            return true
        case ("up", _) where plain, ("p", _) where stroke.modifiers == .control:
            model.moveOverlaySelection(by: -1)
            return true
        case ("enter", _) where plain:
            model.confirmOverlay()
            return true
        default:
            return false
        }
    }

    private static func modifiers(of event: NSEvent) -> KeyStroke.Modifiers {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyStroke.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }
}
