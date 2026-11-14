import XCTest
@testable import CallRecorderCore

final class MeetingLinkTests: XCTestCase {
    func link(url: String? = nil, loc: String? = nil, notes: String? = nil) -> String? {
        MeetingLinkExtractor.joinLink(url: url.flatMap(URL.init(string:)), location: loc, notes: notes)?.absoluteString
    }

    func testProvidersInEachField() {
        XCTAssertEqual(link(url: "https://meet.google.com/abc-defg-hij"), "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(link(loc: "https://acme.zoom.us/j/123456789?pwd=x"), "https://acme.zoom.us/j/123456789?pwd=x")
        XCTAssertEqual(link(notes: "Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x now"), "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=x")
    }

    func testProviderBeatsGenericAndFieldOrder() {
        XCTAssertEqual(link(url: "https://example.com/room", notes: "https://zoom.us/j/1"), "https://zoom.us/j/1")
        XCTAssertEqual(link(url: "https://zoom.us/j/1", loc: "https://meet.google.com/aaa-bbbb-ccc"), "https://zoom.us/j/1")
    }

    func testGenericOnlyInUrlFieldOrWholeLocation() {
        XCTAssertEqual(link(url: "https://example.com/room"), "https://example.com/room")
        XCTAssertEqual(link(loc: "https://example.com/room"), "https://example.com/room")
        XCTAssertNil(link(notes: "Agenda: https://docs.google.com/document/d/1"))
        XCTAssertNil(link(loc: "Room 4, see https://example.com/map"))
    }

    func testRejectsNonHTTPAndEmpty() {
        XCTAssertNil(link(url: "zoommtg://zoom.us/join?confno=1"))
        XCTAssertNil(link(loc: "mailto:a@b.com", notes: "tel:+1555"))
        XCTAssertNil(link(url: nil, loc: "Conference Room", notes: ""))
        XCTAssertNil(link())
    }

    func testTrailingPunctuationAndAngleBrackets() {
        XCTAssertEqual(link(notes: "Link <https://meet.google.com/abc-defg-hij>."), "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(link(notes: "see https://zoom.us/j/99, thanks"), "https://zoom.us/j/99")
    }
}
