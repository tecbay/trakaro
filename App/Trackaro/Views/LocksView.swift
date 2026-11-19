import SwiftUI
import TrackaroCore
import TrackaroKit

/// Every shared-resource lock: who holds it, for how long, and who waits in what order.
struct LocksPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TimelineView(.periodic(from: .now, by: 15)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if model.lockStates.isEmpty {
                        ContentUnavailableView(SidebarItem.locks.emptyMessage, systemImage: "lock")
                    }
                    ForEach(model.lockStates) { state in
                        LockCard(state: state, now: context.date)
                    }
                }
                .padding(16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog(
            "Force release \(model.lockToForceRelease?.resource ?? "lock")?",
            isPresented: Binding(get: { model.lockToForceRelease != nil }, set: { if !$0 { model.lockToForceRelease = nil } }),
            presenting: model.lockToForceRelease
        ) { state in
            Button("Force release", role: .destructive) { model.forceRelease(state) }
            Button("Cancel", role: .cancel) { model.lockToForceRelease = nil }
        } message: { state in
            Text(forceMessage(state))
        }
        .sheet(isPresented: $model.newLockPresented) {
            NewLockView()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Chats take these through MCP before using a shared resource. A lock is freed when its chat stops sending heartbeats or closes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Add lock…") { model.newLockPresented = true }
        }
    }

    private func forceMessage(_ state: LockState) -> String {
        let holder = state.holder.map { "\(model.identifier($0.issueId)) (\(TrackaroStore.chat($0.sessionTitle, $0.sessionId)))" } ?? "its chat"
        let next = state.queue.first.map { " \(model.identifier($0.issueId)) is next and gets it." } ?? ""
        return "\(holder) is told it no longer holds the lock.\(next) This can't be undone."
    }
}

private struct LockCard: View {
    @Environment(AppModel.self) private var model
    let state: LockState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: state.holder == nil ? "lock.open" : "lock.fill")
                    .foregroundStyle(state.holder == nil ? Color.secondary : Color.accentTheme)
                    .frame(width: 18)
                Text(state.resource).font(.headline)
                if !state.conflictsWith.isEmpty {
                    Text("Excludes \(state.conflictsWith.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if state.holder != nil {
                    Button("Force release…") { model.lockToForceRelease = state }
                        .controlSize(.small)
                }
            }
            if let holder = state.holder {
                holderRow(holder)
            } else if let blocker = blocker {
                Text("Free, but blocked while \(blocker) is held").font(.callout).foregroundStyle(.secondary).padding(.leading, 26)
            } else {
                Text("Free").font(.callout).foregroundStyle(.secondary).padding(.leading, 26)
            }
            if !state.queue.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Waiting").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(state.queue.enumerated()), id: \.element.id) { index, waiter in
                        HStack(spacing: 8) {
                            Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            issueButton(waiter.issueId)
                            Text(TrackaroStore.chat(waiter.sessionTitle, waiter.sessionId)).foregroundStyle(.secondary)
                            Text("· waiting \(TrackaroStore.duration(now.timeIntervalSince(waiter.enqueuedAt)))").foregroundStyle(.secondary)
                            if let note = waiter.note {
                                Text("· \(note)").foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .font(.callout)
                    }
                }
                .padding(.leading, 26)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .contextMenu {
            if state.holder == nil && state.queue.isEmpty {
                Button("Delete lock", role: .destructive) { model.deleteLock(state.resource) }
            }
        }
    }

    /// A conflicting lock that is held, which is why waiters stay queued while this one is free.
    private var blocker: String? {
        let held = model.lockStates.filter { $0.holder != nil && state.conflictsWith.contains($0.resource) }.map(\.resource)
        return held.isEmpty ? nil : held.joined(separator: " and ")
    }

    private func holderRow(_ holder: LockHolder) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                issueButton(holder.issueId)
                Text(TrackaroStore.chat(holder.sessionTitle, holder.sessionId))
            }
            .font(.callout)
            Text(timing(holder))
                .font(.caption)
                .foregroundStyle(holder.expiresAt.timeIntervalSince(now) < 120 ? Color(nsColor: Theme.danger) : Color.secondary)
            if let note = holder.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 26)
    }

    private func timing(_ holder: LockHolder) -> String {
        var parts = ["Held \(TrackaroStore.duration(now.timeIntervalSince(holder.acquiredAt)))"]
        if holder.acquiredAt.timeIntervalSince(holder.requestedAt) >= 1 {
            parts.append("waited \(TrackaroStore.duration(holder.acquiredAt.timeIntervalSince(holder.requestedAt)))")
        }
        parts.append("last heartbeat \(TrackaroStore.duration(now.timeIntervalSince(holder.heartbeatAt))) ago")
        let left = holder.expiresAt.timeIntervalSince(now)
        parts.append(left > 0 ? "expires in \(TrackaroStore.duration(left))" : "expiring")
        return parts.joined(separator: " · ")
    }

    private func issueButton(_ issueId: String) -> some View {
        Button(model.identifier(issueId)) { model.focus(issueId) }
            .buttonStyle(.link)
            .font(.system(.callout, design: .monospaced))
    }
}

private struct NewLockView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var conflicts: Set<String> = []

    var body: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("staging-db"))
            if !model.lockStates.isEmpty {
                Section("Can't be held at the same time as") {
                    ForEach(model.lockStates) { state in
                        Toggle(state.resource, isOn: Binding(
                            get: { conflicts.contains(state.resource) },
                            set: { if $0 { conflicts.insert(state.resource) } else { conflicts.remove(state.resource) } }
                        ))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .frame(minHeight: 300)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    model.addLock(named: name, conflictsWith: Array(conflicts))
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
