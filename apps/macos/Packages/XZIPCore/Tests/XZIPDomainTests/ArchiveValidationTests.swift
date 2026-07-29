import Foundation
import XCTest
@testable import XZIPDomain

final class ArchiveValidationTests: XCTestCase {
    func testComponentValidationPreservesValidWhitespace() throws {
        XCTAssertEqual(try ArchiveComponentValidator.validate(" report "), " report ")
    }

    func testComponentValidationRejectsEffectivelyEmptyAndFragments() {
        for value in ["", " ", ".", "..", "a/b", "a\nb", "a\rb", "a\u{0}b"] {
            XCTAssertThrowsError(try ArchiveComponentValidator.validate(value))
        }
    }

    func testComponentValidationReportsTypedFailures() {
        assertComponent("", throws: .emptyComponent)
        assertComponent(" ", throws: .emptyComponent)
        assertComponent(".", throws: .reservedComponent("."))
        assertComponent("..", throws: .reservedComponent(".."))
        assertComponent("a/b", throws: .containsPathSeparator("a/b"))
        assertComponent("a\u{0}b", throws: .containsNUL("a\u{0}b"))
        assertComponent("a\nb", throws: .containsLineBreak("a\nb"))
        assertComponent("a\rb", throws: .containsLineBreak("a\rb"))
    }

    func testListFileValidationAllowsPathsAndLiteralWildcards() {
        XCTAssertNoThrow(try ArchiveListFileValidator.validate(
            entries: ["folder/a*[1]?.txt"]
        ))
    }

    func testListFileValidationRejectsControlCharacters() {
        assertListEntry("a\u{0}b", throws: .containsNUL("a\u{0}b"))
        assertListEntry("a\nb", throws: .containsLineBreak("a\nb"))
        assertListEntry("a\rb", throws: .containsLineBreak("a\rb"))
    }

    func testPathContainmentBuildsValidatedChildWithoutSanitizing() throws {
        let parent = URL(fileURLWithPath: "/tmp/archive-parent", isDirectory: true)
        let child = try ArchivePathContainment.childURL(
            parent: parent,
            component: " report "
        )

        XCTAssertEqual(child.lastPathComponent, " report ")
        XCTAssertEqual(child.deletingLastPathComponent().standardizedFileURL, parent.standardizedFileURL)
    }

    func testPathContainmentRejectsTraversalComponent() {
        let parent = URL(fileURLWithPath: "/tmp/archive-parent", isDirectory: true)

        XCTAssertThrowsError(try ArchivePathContainment.childURL(
            parent: parent,
            component: "../escape"
        ))
    }

    private func assertComponent(
        _ component: String,
        throws expected: ArchiveNameValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ArchiveComponentValidator.validate(component),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ArchiveNameValidationError, expected, file: file, line: line)
        }
    }

    private func assertListEntry(
        _ entry: String,
        throws expected: ArchiveNameValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ArchiveListFileValidator.validate(entries: [entry]),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ArchiveNameValidationError, expected, file: file, line: line)
        }
    }
}
