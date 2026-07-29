import XCTest
@testable import XZIPCore

/// Round-trip tests for the app<->extension URL command format.
final class AppCommandTests: XCTestCase {

    func testCompressRoundtrip() throws {
        let command = AppCommand.compress(
            paths: ["/tmp/a.txt", "/tmp/b folder"], presetID: "zip-normal", quick: false, format: nil)
        let url = try XCTUnwrap(command.url)
        XCTAssertEqual(url.scheme, "xzip")
        let decoded = try XCTUnwrap(AppCommand(url: url))
        XCTAssertEqual(decoded, command)
    }

    func testCompressQuickRoundtrip() throws {
        let command = AppCommand.compress(paths: ["/tmp/x"], presetID: nil, quick: true, format: nil)
        let url = try XCTUnwrap(command.url)
        let decoded = try XCTUnwrap(AppCommand(url: url))
        XCTAssertEqual(decoded, command)
        XCTAssertEqual(decoded, .compress(paths: ["/tmp/x"], presetID: nil, quick: true, format: nil))
    }

    func testCompressWithFormatRoundtrip() throws {
        let command = AppCommand.compress(paths: ["/tmp/x"], presetID: nil, quick: false, format: "7z")
        let url = try XCTUnwrap(command.url)
        let decoded = try XCTUnwrap(AppCommand(url: url))
        XCTAssertEqual(decoded, .compress(paths: ["/tmp/x"], presetID: nil, quick: false, format: "7z"))
    }

    func testExtractRoundtrip() throws {
        let command = AppCommand.extract(paths: ["/tmp/archive.7z"], destination: nil, withPassword: false)
        let url = try XCTUnwrap(command.url)
        let decoded = try XCTUnwrap(AppCommand(url: url))
        XCTAssertEqual(decoded, command)
    }

    func testExtractWithDestinationAndPasswordRoundtrip() throws {
        let here = AppCommand.extract(paths: ["/tmp/a.7z"], destination: .here, withPassword: false)
        XCTAssertEqual(try XCTUnwrap(AppCommand(url: try XCTUnwrap(here.url))), here)
        let downloads = AppCommand.extract(paths: ["/tmp/a.7z"], destination: .downloads, withPassword: true)
        XCTAssertEqual(try XCTUnwrap(AppCommand(url: try XCTUnwrap(downloads.url))), downloads)
    }

    func testCompressWithoutPreset() throws {
        let command = AppCommand.compress(paths: ["/tmp/x"], presetID: nil, quick: false, format: nil)
        let url = try XCTUnwrap(command.url)
        let decoded = try XCTUnwrap(AppCommand(url: url))
        XCTAssertEqual(decoded, .compress(paths: ["/tmp/x"], presetID: nil, quick: false, format: nil))
    }

    func testPathsWithSpacesAndSpecialChars() throws {
        let tricky = "/tmp/my file (2026) & stuff.txt"
        let command = AppCommand.compress(paths: [tricky], presetID: nil, quick: false, format: nil)
        let url = try XCTUnwrap(command.url)
        let decoded = try XCTUnwrap(AppCommand(url: url))
        XCTAssertEqual(decoded, .compress(paths: [tricky], presetID: nil, quick: false, format: nil))
    }

    func testInvalidURLReturnsNil() {
        XCTAssertNil(AppCommand(url: URL(string: "https://example.com")!))
        XCTAssertNil(AppCommand(url: URL(string: "xzip://unknownhost?path=/a")!))
    }
}
