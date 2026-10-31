import Foundation
import GRDB
import UniformTypeIdentifiers

/// How the app shows an artifact. Worked out from its MIME type rather than stored, so new kinds need no migration.
public enum ArtifactKind: String, Sendable, CaseIterable {
    case markdown, html, text, image, pdf, file

    public init(mimeType: String) {
        let type = mimeType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        switch type {
        case "text/markdown": self = .markdown
        case "text/html": self = .html
        case "application/pdf": self = .pdf
        case "application/json", "application/xml", "application/yaml", "application/x-yaml", "application/javascript":
            self = .text
        case _ where type.hasPrefix("text/"): self = .text
        // SVG can carry scripts, so it is kept as a file rather than drawn.
        case _ where type.hasPrefix("image/") && type != "image/svg+xml": self = .image
        default: self = .file
        }
    }
}

/// An artifact's details without its content, which can be large. Lists and the change log use this.
public struct ArtifactSummary: Codable, Hashable, Sendable, Identifiable, FetchableRecord, TableRecord {
    public static let databaseTableName = "artifact"
    public var id: String
    public var projectId: String
    public var name: String
    public var summary: String
    public var mimeType: String
    public var byteCount: Int
    public var creatorId: String
    public var updaterId: String
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date

    public var kind: ArtifactKind { ArtifactKind(mimeType: mimeType) }
}

/// A file an agent saved to a project: a spec, a report, a diagram. Kept in the database, so a backup includes it
/// and a write is one transaction like any other.
public struct Artifact: Hashable, Sendable {
    public var summary: ArtifactSummary
    public var content: Data

    /// The text of a text artifact; nil when the content is binary.
    public var text: String? {
        switch summary.kind {
        case .markdown, .html, .text: String(bytes: content, encoding: .utf8)
        case .image, .pdf, .file: nil
        }
    }
}

public enum ArtifactType {
    /// The MIME type for a new artifact: the one the caller gave, else from the name's extension, else from the
    /// content. Text with no other hint is treated as Markdown, which is what agents mostly write.
    public static func resolve(mimeType: String?, name: String, content: Data) -> String {
        if let mimeType = mimeType?.trimmingCharacters(in: .whitespaces).lowercased(), !mimeType.isEmpty { return mimeType }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        if ["md", "markdown"].contains(fileExtension) { return "text/markdown" }
        if !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension)?.preferredMIMEType { return type }
        let isText = !content.contains(0) && String(bytes: content, encoding: .utf8) != nil
        if !fileExtension.isEmpty { return isText ? "text/plain" : "application/octet-stream" }
        return isText ? "text/markdown" : "application/octet-stream"
    }

    /// A name to save or open the artifact under: no folders in it, and for opening, an extension chosen from what
    /// it is. A `.command` file from an agent would otherwise run in Terminal when opened.
    public static func fileName(for summary: ArtifactSummary, forOpening: Bool = false) -> String {
        let cleaned = summary.name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        var name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if name.isEmpty { name = "artifact" }
        guard forOpening else { return name }
        let stem = (name as NSString).deletingPathExtension
        switch summary.kind {
        case .markdown: return "\(stem).md"
        case .html: return "\(stem).html"
        case .text: return "\(stem).txt"
        case .pdf: return "\(stem).pdf"
        case .image: return "\(stem).\(UTType(mimeType: summary.mimeType)?.preferredFilenameExtension ?? "png")"
        case .file: return "\(stem).bin"
        }
    }
}
