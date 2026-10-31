import AppKit
import Foundation
import TrackaroCore
import TrackaroKit

/// Browsing what agents saved to a project.
extension AppModel {
    /// The current project's artifacts, or every project's.
    func goToArtifacts() {
        if case let .project(id) = currentItem {
            sidebarSelection = .artifacts(id)
        } else {
            sidebarSelection = .artifacts(nil)
        }
    }

    func saveArtifactToChosenFile(_ artifact: Artifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ArtifactType.fileName(for: artifact.summary)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try artifact.content.write(to: url, options: .atomic)
            showToast("Saved \(url.lastPathComponent)")
        } catch {
            showError(error)
        }
    }

    /// Opens a temporary copy in the default app, under an extension chosen from the artifact's kind. A file of
    /// unknown kind is only ever saved, since opening it could run it.
    func openArtifactExternally(_ artifact: Artifact) {
        guard artifact.summary.kind != .file else { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Trackaro Artifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(ArtifactType.fileName(for: artifact.summary, forOpening: true))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try artifact.content.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            showError(error)
        }
    }

    func deleteArtifact(_ summary: ArtifactSummary) {
        guard let store, let user else { return }
        do {
            try store.deleteArtifact(summary.id, by: user.id)
            reloadAll()
            showToast("Deleted \(summary.name)")
        } catch {
            showError(error)
        }
    }
}
