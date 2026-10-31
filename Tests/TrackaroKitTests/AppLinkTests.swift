import Foundation
import Testing
@testable import TrackaroKit

@Suite("Deep links")
struct AppLinkTests {
    @Test("Parses every link form", arguments: [
        ("trackaro://issue/ENG-42", AppLink.issue("ENG-42")),
        ("TRACKARO://Issue/eng-1", .issue("eng-1")),
        ("trackaro://my-issues", .myIssues),
        ("trackaro://agent-activity", .agentActivity),
        ("trackaro://team/ENG", .team(key: "ENG", page: nil)),
        ("trackaro://team/ENG/Active", .team(key: "ENG", page: "active")),
        ("trackaro://view/Ready%20for%20agent", .view("Ready for agent")),
        ("trackaro://projects", .projects),
        ("trackaro://project/mobile-launch", .project("mobile-launch")),
        ("trackaro://cycles/ENG", .cycles(teamKey: "ENG")),
        ("trackaro://cycle/ENG/Current", .cycle(teamKey: "ENG", cycle: "current")),
        ("trackaro://command/palette", .command(.palette)),
    ])
    func parses(text: String, expected: AppLink) throws {
        #expect(AppLink(url: try #require(URL(string: text))) == expected)
    }

    @Test("Rejects anything else", arguments: [
        "https://issue/ENG-1", "trackaro://issue", "trackaro://issue/a/b", "trackaro://command/rm-rf", "trackaro://nowhere",
    ])
    func rejects(text: String) throws {
        #expect(AppLink(url: try #require(URL(string: text))) == nil)
    }

    @Test func buildsIssueLinksThatRoundTrip() throws {
        let url = try #require(AppLink.issueURL("ENG-7"))
        #expect(url.absoluteString == "trackaro://issue/ENG-7")
        #expect(AppLink(url: url) == .issue("ENG-7"))
    }
}
