import AppKit
import SwiftUI
import TrackaroCore

/// Back up now, restore from a file, or go back to one of the automatic copies.
struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let entries = model.backupFolder?.entries() ?? []
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Backup and Restore").font(.title2.weight(.semibold))
                Text("A backup holds all your issues, projects, automations and artifacts in one file. Trackaro also keeps a copy each day, and before every upgrade or restore.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Back Up Now…") { model.backUpToChosenFile() }.buttonStyle(.borderedProminent)
                Button("Restore from File…") { model.chooseFileToRestore() }
                Spacer()
                if model.isRestoring { ProgressView().controlSize(.small) }
            }
            Divider()
            Text("Automatic copies").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("None yet. The first daily copy is made the next time Trackaro opens.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(entries) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                            Text("\(entry.kind.title) · \(ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }.controlSize(.small)
                        Button("Restore") { model.restoreCandidate = entry.url }.controlSize(.small)
                    }
                }
                .listStyle(.inset)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
        .disabled(model.isRestoring)
        .confirmationDialog(
            "Replace everything in Trackaro with this backup?",
            isPresented: Binding(get: { model.restoreCandidate != nil }, set: { if !$0 { model.restoreCandidate = nil } }),
            presenting: model.restoreCandidate
        ) { url in
            Button("Replace Everything", role: .destructive) { model.restore(from: url) }
            Button("Cancel", role: .cancel) {}
        } message: { url in
            Text("Your current data is replaced by \(url.lastPathComponent). A copy of it is kept first and appears in this list, so you can go back.")
        }
    }
}
