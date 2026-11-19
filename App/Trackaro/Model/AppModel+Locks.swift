import Foundation
import TrackaroCore
import TrackaroKit

/// Shared-resource locks that chats take through MCP. The app shows them, frees expired ones and lets the user
/// take one back from a stuck chat.
extension AppModel {
    static let lockSweepInterval: TimeInterval = 5

    /// Frees locks whose chat stopped sending heartbeats or went away. The servers do this too; the app covers the
    /// time when no chat is connected. A sweep that frees something writes, so the next poll reloads.
    func sweepLocksIfDue() {
        guard let store, Date().timeIntervalSince(lastLockSweep) >= Self.lockSweepInterval else { return }
        lastLockSweep = Date()
        do {
            try store.expireLocks()
        } catch {
            Self.log.error("Lock sweep failed: \(String(describing: error))")
        }
    }

    /// Takes the lock away from its chat and hands it to the next one. The chat is told. There is no undo: the
    /// next chat may already be using the resource.
    func forceRelease(_ state: LockState) {
        guard let store, let user else { return }
        do {
            let granted = try store.forceReleaseLock(state.resource, by: user.id)
            let next = granted.first { $0.resource == state.resource }.map { " Now held by \(identifier($0.issueId))." } ?? ""
            showToast("Released \(state.resource).\(next)")
            reloadAll()
        } catch {
            showError(error)
        }
    }

    func addLock(named name: String, conflictsWith others: [String]) {
        guard let store else { return }
        do {
            try store.defineLockResource(name, conflictsWith: others)
            reloadAll()
        } catch {
            showError(error)
        }
    }

    func deleteLock(_ name: String) {
        guard let store else { return }
        do {
            try store.deleteLockResource(name)
            reloadAll()
        } catch {
            showError(error)
        }
    }

    func identifier(_ issueId: String) -> String {
        (try? store?.issue(issueId).identifier) ?? "an issue"
    }

    /// How many locks are held right now, for the sidebar.
    var heldLockCount: Int { lockStates.filter { $0.holder != nil }.count }
}
