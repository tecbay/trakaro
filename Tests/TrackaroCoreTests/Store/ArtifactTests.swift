import Foundation
import Testing
@testable import TrackaroCore

@Suite("Artifacts")
struct ArtifactTests {
    private func project(_ fixture: Fixture, named name: String = "Launch") throws -> Project {
        try fixture.store.createProject(name: name, by: fixture.me.id)
    }

    @Test func savingUnderAnExistingNameUpdatesIt() throws {
        let fixture = try Fixture()
        let project = try project(fixture)
        let first = try fixture.store.saveArtifact(projectId: project.id, name: "Spec.md", content: Data("one".utf8), summary: "The spec", by: fixture.me.id)
        let second = try fixture.store.saveArtifact(projectId: project.id, name: "spec.md", content: Data("two".utf8), by: fixture.me.id)

        #expect(first.created)
        #expect(!second.created)
        #expect(second.artifact.id == first.artifact.id)
        #expect(second.artifact.version == 2)
        #expect(second.artifact.summary == "The spec")
        #expect(try fixture.store.artifact(first.artifact.id).text == "two")
        #expect(try fixture.store.artifacts(projectId: project.id).count == 1)
    }

    @Test func artifactsBelongToOneProject() throws {
        let fixture = try Fixture()
        let launch = try project(fixture)
        let billing = try project(fixture, named: "Billing")
        try fixture.store.saveArtifact(projectId: launch.id, name: "notes", content: Data("launch".utf8), by: fixture.me.id)
        try fixture.store.saveArtifact(projectId: billing.id, name: "notes", content: Data("billing".utf8), by: fixture.me.id)

        #expect(try fixture.store.artifacts(projectId: launch.id).count == 1)
        #expect(try fixture.store.artifacts().count == 2)
        #expect(try fixture.store.artifact("notes", projectId: billing.id).text == "billing")
        #expect(throws: TrackaroError.self) { try fixture.store.artifact("notes") }
    }

    @Test func listingLeavesTheContentBehindAndTheChangeLogToo() throws {
        let fixture = try Fixture()
        let project = try project(fixture)
        let secret = "CONTENT-SHOULD-NOT-BE-COPIED"
        try fixture.store.saveArtifact(projectId: project.id, name: "a.md", content: Data(secret.utf8), by: fixture.me.id)

        let entry = try #require(try fixture.store.changes(since: 0).last { $0.model == "artifact" })
        #expect(entry.action == .insert)
        #expect(entry.payload?.contains(secret) == false)
        #expect(try fixture.store.artifacts().first?.byteCount == secret.utf8.count)
    }

    @Test func deletingFreesTheNameAndHidesIt() throws {
        let fixture = try Fixture()
        let project = try project(fixture)
        let saved = try fixture.store.saveArtifact(projectId: project.id, name: "a.md", content: Data("x".utf8), by: fixture.me.id)

        try fixture.store.deleteArtifact(saved.artifact.id, by: fixture.me.id)

        #expect(try fixture.store.artifacts().isEmpty)
        #expect(throws: TrackaroError.self) { try fixture.store.artifact("a.md") }
        #expect(try fixture.store.saveArtifact(projectId: project.id, name: "a.md", content: Data("y".utf8), by: fixture.me.id).created)
    }

    @Test func aMissTeachesTheNames() throws {
        let fixture = try Fixture()
        let project = try project(fixture)
        try fixture.store.saveArtifact(projectId: project.id, name: "spec.md", content: Data("x".utf8), by: fixture.me.id)

        let error = #expect(throws: TrackaroError.self) { try fixture.store.artifact("nope", projectId: project.id) }
        #expect(error?.description.contains("spec.md") == true)
    }

    @Test func oversizedAndEmptyContentAreRefused() throws {
        let fixture = try Fixture()
        let project = try project(fixture)
        #expect(throws: TrackaroError.self) {
            try fixture.store.saveArtifact(projectId: project.id, name: "big", content: Data(count: TrackaroStore.maxArtifactBytes + 1), by: fixture.me.id)
        }
        #expect(throws: TrackaroError.self) {
            try fixture.store.saveArtifact(projectId: project.id, name: "empty", content: Data(), by: fixture.me.id)
        }
    }

    @Test(arguments: [
        ("spec.md", "text", "text/markdown", ArtifactKind.markdown),
        ("Plan with no extension", "text", "text/markdown", .markdown),
        ("page.html", "<p>", "text/html", .html),
        ("data.json", "{}", "application/json", .text),
        ("run.sh", "ls", nil, .text),
    ] as [(String, String, String?, ArtifactKind)])
    func typeComesFromTheNameThenTheContent(name: String, content: String, mime: String?, kind: ArtifactKind) {
        let resolved = ArtifactType.resolve(mimeType: nil, name: name, content: Data(content.utf8))
        if let mime { #expect(resolved == mime) }
        #expect(ArtifactKind(mimeType: resolved) == kind)
    }

    @Test func binaryIsNotTreatedAsText() {
        let bytes = Data([0x89, 0x50, 0x00, 0xFF])
        #expect(ArtifactType.resolve(mimeType: nil, name: "blob", content: bytes) == "application/octet-stream")
        #expect(ArtifactType.resolve(mimeType: nil, name: "shot.png", content: bytes) == "image/png")
        #expect(ArtifactKind(mimeType: "image/svg+xml") == .file)
    }

    @Test func aFileOpenedFromAnArtifactCannotRunAsAProgram() throws {
        let fixture = try Fixture()
        let project = try project(fixture)
        let saved = try fixture.store.saveArtifact(projectId: project.id, name: "../evil.command", content: Data("rm -rf ~".utf8), mimeType: "text/plain", by: fixture.me.id)

        #expect(ArtifactType.fileName(for: saved.artifact, forOpening: true) == "-evil.txt")
        #expect(!ArtifactType.fileName(for: saved.artifact).contains("/"))
    }
}
