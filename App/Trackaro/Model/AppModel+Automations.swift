import AppKit
import Foundation
import TrackaroCore
import TrackaroKit

/// Column automations: the runner lives as long as the window's model and is ticked by the same poll loop that
/// watches for agents' changes, so a card the user drops into an automated column starts its run within a poll.
extension AppModel {
    func startAutomations(store: TrackaroStore) {
        guard automationRunner == nil else { return }
        do {
            let database = try Self.databaseURL()
            let runner = AutomationRunner(
                store: store,
                logDirectory: database.deletingLastPathComponent().appendingPathComponent("automation-logs", isDirectory: true),
                databasePath: database.path,
                onEvent: { [weak self] event in Task { @MainActor in self?.automationEvent(event) } }
            )
            automationRunner = runner
            Task {
                do {
                    try await runner.start()
                } catch {
                    showError(error)
                }
            }
        } catch {
            showError(error)
        }
    }

    func runAutomations() async {
        guard let automationRunner else { return }
        do {
            try await automationRunner.tick()
        } catch {
            Self.log.error("Automation tick failed: \(String(describing: error))")
        }
    }

    func automations(forState stateId: String?) -> [Automation] {
        guard let stateId else { return [] }
        return automations.filter { $0.stateId == stateId && $0.enabled }
    }

    private func automationEvent(_ event: AutomationRunner.Event) {
        switch event {
        case let .started(_, automation, issue):
            showToast("Started “\(automation.name)” on \(issue.identifier)")
        case let .finished(run, automation, issue):
            switch run.status {
            case .succeeded: showToast("“\(automation.name)” finished on \(issue.identifier)")
            case .stopped: showToast("Stopped “\(automation.name)” on \(issue.identifier)")
            case .failed, .interrupted, .running:
                showToast("“\(automation.name)” failed on \(issue.identifier). Open the log in the details panel.", isError: true)
            }
        }
        reloadAll()
    }

    // MARK: Actions

    func openAutomations(forState stateId: String? = nil) {
        automationPreset = stateId
        automationsPresented = true
    }

    /// Runs the automations of the issue's current column now, for a retry or a first try.
    func runAutomationNow() {
        guard let automationRunner, let store, let id = targets.first, let issue = try? store.issue(id) else { return }
        let rules = automations(forState: issue.stateId)
        guard !rules.isEmpty else {
            showToast("\(snapshot?.statesById[issue.stateId]?.name ?? "This column") has no automation. Add one from the board column's menu.", isError: true)
            return
        }
        Task {
            for rule in rules {
                do {
                    try await automationRunner.launch(PlannedRun(automation: rule, issue: issue))
                } catch {
                    showError(error)
                }
            }
        }
    }

    func stopRun(_ runId: String) {
        guard let automationRunner else { return }
        Task { await automationRunner.stop(runId: runId) }
    }

    func openLog(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @discardableResult
    func saveAutomation(id: String?, _ input: AutomationInput) -> Automation? {
        guard let store, let user else { return nil }
        do {
            let saved = if let id {
                try store.updateAutomation(id, input, by: user.id)
            } else {
                try store.createAutomation(input, by: user.id)
            }
            reloadAll()
            return saved
        } catch {
            showError(error)
            return nil
        }
    }

    func deleteAutomation(_ id: String) {
        guard let store, let user else { return }
        do {
            try store.deleteAutomation(id, by: user.id)
            reloadAll()
        } catch {
            showError(error)
        }
    }
}
