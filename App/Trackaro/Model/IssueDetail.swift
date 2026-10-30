import Foundation
import TrackaroCore
import TrackaroKit

/// Everything the inspector shows for one issue, loaded in one pass.
struct IssueDetail: Equatable {
    struct Link: Equatable, Identifiable {
        let id: String
        let identifier: String
        let title: String
        let caption: String
    }

    struct FeedEntry: Equatable, Identifiable {
        enum Kind: Equatable {
            case event(String)
            case comment(String)
        }

        let id: String
        let actor: String
        let isAgent: Bool
        let at: Date
        let kind: Kind
    }

    let issue: Issue
    let state: WorkflowState?
    let labels: [IssueLabel]
    let parent: Link?
    let children: [Link]
    let relations: [Link]
    let isBlocked: Bool
    let feed: [FeedEntry]

    static func load(_ issueId: String, store: TrackaroStore, snapshot: WorkspaceSnapshot) throws -> IssueDetail {
        let issue = try store.issue(issueId)
        let relations = try store.relations(of: issue.id)
        let children = try store.children(of: issue.id)
        let activity = try store.activity(issueId: issue.id)
        let comments = try store.comments(on: issue.id)
        let referenced = relations.map(\.relatedIssueId) + [issue.parentId].compactMap { $0 }
            + activity.compactMap { $0.field == .parent ? $0.toValue.flatMap(decodeString) : nil }
        let identifiers = try store.identifiers(forIssueIds: referenced)
        let formatter = ActivityFormatter(snapshot: snapshot, identifiers: identifiers)

        func member(_ id: String) -> (String, Bool) {
            let member = snapshot.membersById[id]
            return (member?.name ?? "Someone", member?.kind == .agent)
        }

        let events = activity.map { entry -> FeedEntry in
            let (name, isAgent) = member(entry.memberId)
            return FeedEntry(id: entry.id, actor: name, isAgent: isAgent, at: entry.createdAt, kind: .event(formatter.describe(entry)))
        }
        let notes = comments.map { comment -> FeedEntry in
            let (name, isAgent) = member(comment.authorId)
            return FeedEntry(id: comment.id, actor: name, isAgent: isAgent, at: comment.createdAt, kind: .comment(comment.body))
        }

        let parent: Link? = try issue.parentId.map { parentId in
            let parentIssue = try store.issue(parentId)
            return Link(id: parentIssue.id, identifier: parentIssue.identifier, title: parentIssue.title, caption: "Parent")
        }

        return IssueDetail(
            issue: issue,
            state: snapshot.statesById[issue.stateId],
            labels: try store.labels(forIssue: issue.id),
            parent: parent,
            children: children.map {
                Link(id: $0.id, identifier: $0.identifier, title: $0.title, caption: "Sub-issue")
            },
            relations: relations.map {
                Link(id: $0.relatedIssueId, identifier: identifiers[$0.relatedIssueId] ?? "?", title: "",
                     caption: $0.type.rawValue.replacingOccurrences(of: "_", with: " "))
            },
            isBlocked: try store.isBlocked(issue.id),
            feed: (events + notes).sorted { $0.at < $1.at }
        )
    }

    private static func decodeString(_ json: String) -> String? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
    }
}
