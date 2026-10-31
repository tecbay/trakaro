import Foundation
import MCP
import TrackaroCore
import TrackaroKit

/// Artifacts: files an agent saves to a project, such as specs, reports and designs. The user browses them in the app.
enum ArtifactTools {
    static var all: [ToolDefinition] {
        [saveArtifact, listArtifacts, getArtifact, deleteArtifact]
    }

    static let saveArtifact = ToolDefinition(
        name: "save_artifact",
        title: "Save artifact",
        description: """
            Save a file to a project so the user can browse it in the app: a spec, plan, report, HTML page, screenshot \
            or PDF. Saving under an existing name in the project replaces it and bumps its version. Pass `content` for \
            text you wrote, or `file_path` for a file on this Mac, which also suits large and binary files. Up to 25 MB.
            """,
        inputSchema: JSONSchema.object([
            "project": JSONSchema.string("Project name, slug or id."),
            "name": JSONSchema.string("Name, unique in the project ignoring case. Include an extension, such as auth-spec.md."),
            "content": JSONSchema.string("The text. GitHub-flavored Markdown shows formatted in the app. Give this or file_path."),
            "file_path": JSONSchema.string("Absolute path of a file on this Mac to copy in. Give this or content."),
            "summary": JSONSchema.string("One line on what this is, shown in the list."),
            "mime_type": JSONSchema.string("Only if the name's extension does not show the type, such as text/html."),
        ], required: ["project", "name"]),
        readOnly: false
    ) { context, arguments in
        let resolver = try Resolver(context)
        let project = try resolver.project(try arguments.requiredString("project"))
        let content = try content(from: arguments)
        let saved = try context.store.saveArtifact(
            projectId: project.id, name: try arguments.requiredString("name"), content: content,
            summary: try arguments.string("summary"), mimeType: try arguments.string("mime_type"), by: context.agent.id
        )
        var result = describe(saved.artifact, snapshot: resolver.snapshot)
        result.set("created", saved.created)
        return result.value
    }

    static let listArtifacts = ToolDefinition(
        name: "list_artifacts",
        title: "List artifacts",
        description: "List artifacts, newest first, without their content. Call get_artifact to read one.",
        inputSchema: JSONSchema.object([
            "project": JSONSchema.string("Project name, slug or id. Omit to list every project's."),
            "query": JSONSchema.string("Keep artifacts whose name or summary contains this."),
        ]),
        readOnly: true
    ) { context, arguments in
        let resolver = try Resolver(context)
        let project = try arguments.string("project").map(resolver.project)
        let artifacts = try context.store.artifacts(projectId: project?.id, query: try arguments.string("query"))
        return [
            "count": .int(artifacts.count),
            "artifacts": .array(artifacts.map { describe($0, snapshot: resolver.snapshot).value }),
        ]
    }

    static let getArtifact = ToolDefinition(
        name: "get_artifact",
        title: "Get artifact",
        description: """
            Read one artifact. Text comes back as `content`. Binary files come back without content unless `as_base64` \
            is true, since base64 uses many tokens.
            """,
        inputSchema: JSONSchema.object([
            "name": JSONSchema.string("Artifact name or id."),
            "project": JSONSchema.string("Project name, slug or id. Needed when several projects use this name."),
            "as_base64": JSONSchema.boolean("Include the content of a binary file as base64."),
        ], required: ["name"]),
        readOnly: true
    ) { context, arguments in
        let resolver = try Resolver(context)
        let project = try arguments.string("project").map(resolver.project)
        let artifact = try context.store.artifact(try arguments.requiredString("name"), projectId: project?.id)
        var result = describe(artifact.summary, snapshot: resolver.snapshot)
        if let text = artifact.text {
            result.set("content", text)
        } else if try arguments.bool("as_base64") == true {
            result.set("content_base64", artifact.content.base64EncodedString())
        }
        return result.value
    }

    static let deleteArtifact = ToolDefinition(
        name: "delete_artifact",
        title: "Delete artifact",
        description: "Remove an artifact from its project.",
        inputSchema: JSONSchema.object([
            "name": JSONSchema.string("Artifact name or id."),
            "project": JSONSchema.string("Project name, slug or id. Needed when several projects use this name."),
        ], required: ["name"]),
        readOnly: false,
        destructive: true
    ) { context, arguments in
        let resolver = try Resolver(context)
        let project = try arguments.string("project").map(resolver.project)
        let artifact = try context.store.artifact(try arguments.requiredString("name"), projectId: project?.id)
        try context.store.deleteArtifact(artifact.summary.id, by: context.agent.id)
        return ["deleted": .string(artifact.summary.name)]
    }

    private static func content(from arguments: Arguments) throws -> Data {
        let text = try arguments.text("content")
        let path = try arguments.string("file_path")
        switch (text, path) {
        case let (text?, nil):
            return Data(text.utf8)
        case let (nil, path?):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
            guard size?.isRegularFile == true else {
                throw TrackaroError.invalid(field: "file_path", message: "No file at \(url.path). Pass the absolute path of a file.")
            }
            if let bytes = size?.fileSize, bytes > TrackaroStore.maxArtifactBytes {
                throw TrackaroError.invalid(field: "file_path", message: "Artifacts can be up to \(TrackaroStore.maxArtifactBytes / 1024 / 1024) MB; this file is \(bytes / 1024 / 1024) MB.")
            }
            return try Data(contentsOf: url)
        case (nil, nil):
            throw TrackaroError.invalid(field: "content", message: "Pass content or file_path.")
        case (_?, _?):
            throw TrackaroError.invalid(field: "content", message: "Pass content or file_path, not both.")
        }
    }

    private static func describe(_ artifact: ArtifactSummary, snapshot: WorkspaceSnapshot) -> ObjectBuilder {
        let project = snapshot.projectsById[artifact.projectId]
        var object = ObjectBuilder()
        object.set("name", artifact.name)
        object.set("project", project?.name)
        object.set("summary", artifact.summary.isEmpty ? nil : artifact.summary)
        object.set("type", artifact.mimeType)
        object.set("bytes", artifact.byteCount)
        object.set("version", artifact.version)
        object.set("created_by", snapshot.membersById[artifact.creatorId]?.name)
        object.set("updated_by", snapshot.membersById[artifact.updaterId]?.name)
        object.set("updated_at", Output.timestamp(artifact.updatedAt))
        object.set("link", project.flatMap { AppLink.artifactURL(project: $0.slug, name: artifact.name)?.absoluteString })
        return object
    }
}
