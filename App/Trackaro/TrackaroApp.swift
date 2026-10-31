import AppKit
import SwiftUI
import TrackaroKit

@main
struct TrackaroApp: App {
    @State private var model = AppModel()
    @State private var keyboard = KeyboardController()
    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue

    var body: some Scene {
        WindowGroup("Trackaro", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    AppearancePreference(rawValue: appearance)?.apply()
                    model.start()
                    keyboard.install(on: model)
                }
                .onChange(of: appearance) { _, value in AppearancePreference(rawValue: value)?.apply() }
        }
        .defaultSize(width: 1240, height: 780)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Issue") { model.perform(.newIssue) }
                    .keyboardShortcut("n")
                Divider()
                Button("Backup and Restore…") { model.perform(.backups) }
            }
            CommandGroup(after: .sidebar) {
                Button("Command Palette") { model.perform(.palette) }
                Button("Toggle Details Panel") { model.perform(.toggleInspector) }
                Button("Column Automations…") { model.perform(.automations) }
                Button("Connect an Agent…") { model.perform(.connectAgent) }
                Divider()
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearancePreference.allCases, id: \.rawValue) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            }
            CommandMenu("Go") {
                Button("My Issues") { model.perform(.goMyIssues) }
                Button("Agent Activity") { model.perform(.goAgentActivity) }
                Divider()
                Button("Team Issues") { model.perform(.goIssues) }
                Button("Active") { model.perform(.goActive) }
                Button("Backlog") { model.perform(.goBacklog) }
                Divider()
                Button("Artifacts") { model.perform(.goArtifacts) }
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.perform(.shortcuts) }
            }
        }
    }
}

/// Light, dark, or follow the system. Stored in the app's own defaults under `appearance`.
enum AppearancePreference: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
