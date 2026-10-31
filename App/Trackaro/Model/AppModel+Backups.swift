import AppKit
import Foundation
import TrackaroCore
import TrackaroKit
import UniformTypeIdentifiers

/// Backing up and restoring the database. The work itself is in `TrackaroStore+Backup`.
extension AppModel {
    var backupFolder: BackupFolder? {
        (try? Self.databaseURL()).map(BackupFolder.init(database:))
    }

    /// Runs off the main thread, so a large database does not slow launch.
    func makeDailyBackup() {
        guard let store, let backupFolder else { return }
        Task.detached(priority: .utility) {
            do {
                try store.backupIfDue(in: backupFolder)
            } catch {
                AppModel.log.error("Daily backup failed: \(String(describing: error))")
            }
        }
    }

    func backUpToChosenFile() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.title = "Back Up Trackaro"
        panel.nameFieldStringValue = "Trackaro Backup \(Date().formatted(.iso8601.year().month().day())).sqlite"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let result = await Task.detached { Result { try store.backup(to: url) } }.value
            switch result {
            case .success: showToast("Saved a backup to \(url.lastPathComponent)")
            case let .failure(error): showError(error)
            }
        }
    }

    func chooseFileToRestore() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Trackaro Backup"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        restoreCandidate = url
    }

    /// Replaces everything with a backup. Automations stop reading the feed for the length of it.
    func restore(from url: URL) {
        guard let store, let backupFolder, !isRestoring else { return }
        isRestoring = true
        Task {
            await automationRunner?.suspend()
            let safetyCopy = backupFolder.newURL(.beforeRestore, at: Date())
            let result = await Task.detached { Result { try store.restore(from: url, safetyCopy: safetyCopy) } }.value
            switch result {
            case let .success(restored):
                try? backupFolder.prune(.beforeRestore)
                resetAfterRestore()
                _ = try? store.interruptRunningRuns()
                showToast("Restored \(restored.issueCount) issues and \(restored.artifactCount) artifacts")
            case let .failure(error):
                showError(error)
            }
            try? await automationRunner?.resume()
            isRestoring = false
            backupsPresented = false
        }
    }
}
