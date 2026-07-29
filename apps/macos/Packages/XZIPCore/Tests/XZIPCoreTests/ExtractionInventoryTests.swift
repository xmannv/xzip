import Foundation
import XCTest
import XZIPDomain
@testable import XZIPCore

final class ExtractionInventoryTests: XCTestCase {
    private func entry(
        _ path: String,
        kind: ExtractionNodeKind = .regularFile,
        size: UInt64 = 0,
        linkTarget: String? = nil,
        isExplicitDirectory: Bool? = nil
    ) -> ExtractionInventoryEntry {
        ExtractionInventoryEntry(
            path: path,
            kind: kind,
            size: size,
            linkTarget: linkTarget,
            isExplicitDirectory: isExplicitDirectory ?? (kind == .directory)
        )
    }

    private func policy(
        listingHardCap: Int = 100,
        totalPathByteCap: Int = 10_000,
        maximumPathByteCount: Int = 1_000,
        maximumPathDepth: Int = 20,
        advertisedOutputByteCap: UInt64 = 10_000,
        advertisedDictionaryByteCap: UInt64 = 10_000
    ) -> ArchiveResourcePolicy {
        let base = ArchiveResourcePolicy.production
        return ArchiveResourcePolicy(
            listing: .init(
                browserEntryCap: base.listing.browserEntryCap,
                listingHardCap: listingHardCap,
                totalPathByteCap: totalPathByteCap,
                maximumPathByteCount: maximumPathByteCount,
                maximumPathDepth: maximumPathDepth
            ),
            output: .init(
                advertisedOutputByteCap: advertisedOutputByteCap,
                advertisedDictionaryByteCap: advertisedDictionaryByteCap,
                stagingByteCap: base.output.stagingByteCap
            ),
            process: base.process,
            cache: base.cache,
            split: base.split,
            command: base.command,
            journal: base.journal,
            scheduling: base.scheduling
        )
    }

    func testImplicitParentsAreDerivedFromValidatedEntryPaths() throws {
        let inventory = try ExtractionInventory.validated(
            entries: [
                entry("folder", kind: .directory),
                entry("folder/nested/file.txt", size: 4)
            ],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )

        XCTAssertEqual(inventory.implicitDirectories, ["folder/nested"])
        XCTAssertEqual(inventory.advertisedOutputByteCount, 4)
    }

    func testInvalidEntryPathCannotContributeImplicitParents() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("safe/../escape.txt")],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .invalidPath("safe/../escape.txt")
            )
        }
    }

    func testUnsupportedNodeKindsAreRejected() {
        let unsupported: [ExtractionNodeKind] = [
            .hardLink, .fifo, .socket, .blockDevice, .characterDevice, .unknown
        ]

        for kind in unsupported {
            XCTAssertThrowsError(try ExtractionInventory.validated(
                entries: [entry("node", kind: kind)],
                advertisedDictionaryByteCount: 0,
                policy: policy()
            )) { error in
                XCTAssertEqual(
                    error as? ExtractionInventoryError,
                    .unsupportedNode(path: "node", kind: kind)
                )
            }
        }
    }

    func testSymlinkCannotBeParentOfAnotherEntry() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [
                entry("link", kind: .symbolicLink, linkTarget: "target"),
                entry("link/child.txt")
            ],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(error as? ExtractionInventoryError, .symlinkParent("link"))
        }
    }

    func testMaximumPathDepthIsEnforced() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("one/two/three")],
            advertisedDictionaryByteCount: 0,
            policy: policy(maximumPathDepth: 2)
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .pathDepthExceeded(path: "one/two/three", limit: 2)
            )
        }
    }

    func testMaximumPathByteCountIsEnforced() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("12345")],
            advertisedDictionaryByteCount: 0,
            policy: policy(maximumPathByteCount: 4)
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .pathByteCountExceeded(path: "12345", limit: 4)
            )
        }
    }

    func testTotalPathByteCountIsEnforced() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("1234"), entry("5678")],
            advertisedDictionaryByteCount: 0,
            policy: policy(totalPathByteCap: 7)
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .totalPathByteCountExceeded(limit: 7)
            )
        }
    }

    func testListingHardCapIsEnforced() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("one"), entry("two")],
            advertisedDictionaryByteCount: 0,
            policy: policy(listingHardCap: 1)
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .entryCountExceeded(limit: 1)
            )
        }
    }

    func testAdvertisedOutputByteCapIsEnforced() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("one", size: 3), entry("two", size: 4)],
            advertisedDictionaryByteCount: 0,
            policy: policy(advertisedOutputByteCap: 6)
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .advertisedOutputByteCountExceeded(limit: 6)
            )
        }
    }

    func testAdvertisedDictionaryByteCapIsEnforced() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [],
            advertisedDictionaryByteCount: 8,
            policy: policy(advertisedDictionaryByteCap: 7)
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .advertisedDictionaryByteCountExceeded(limit: 7)
            )
        }
    }

    func testCaseInsensitiveDestinationCollisionIsRejected() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("Folder/File.txt"), entry("folder/file.TXT")],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .destinationCollision(
                    first: "Folder/File.txt",
                    second: "folder/file.TXT"
                )
            )
        }
    }

    func testUnicodeCanonicalDestinationCollisionIsRejected() {
        let composed = "caf\u{00E9}.txt"
        let decomposed = "cafe\u{0301}.txt"

        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry(composed), entry(decomposed)],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .destinationCollision(first: composed, second: decomposed)
            )
        }
    }


    func testGreekSigmaDestinationCollisionIsRejected() {
        let normalSigma = "σ.txt"
        let finalSigma = "ς.txt"

        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry(normalSigma), entry(finalSigma)],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .destinationCollision(first: normalSigma, second: finalSigma)
            )
        }
    }

    func testGreekSigmaExplicitImplicitDestinationCollisionIsRejected() {
        let explicit = "σ"
        let implicit = "ς"
        let child = "\(implicit)/file.txt"

        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry(explicit, kind: .directory), entry(child)],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .destinationCollision(first: explicit, second: implicit)
            )
        }
    }

    func testLongSDestinationCollisionIsRejected() {
        let longS = "ſ.txt"
        let asciiS = "s.txt"

        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry(longS), entry(asciiS)],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .destinationCollision(first: longS, second: asciiS)
            )
        }
    }

    func testFullFoldExpansionDestinationCollisionIsRejected() {
        let sharpS = "straße.txt"
        let expansion = "strasse.txt"

        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry(sharpS), entry(expansion)],
            advertisedDictionaryByteCount: 0,
            policy: policy()
        )) { error in
            XCTAssertEqual(
                error as? ExtractionInventoryError,
                .destinationCollision(first: sharpS, second: expansion)
            )
        }
    }

    func testAdvertisedOutputByteCountOverflowIsRejected() {
        XCTAssertThrowsError(try ExtractionInventory.validated(
            entries: [entry("one", size: UInt64.max), entry("two", size: 1)],
            advertisedDictionaryByteCount: 0,
            policy: policy(advertisedOutputByteCap: UInt64.max)
        )) { error in
            XCTAssertEqual(error as? ExtractionInventoryError, .advertisedOutputByteCountOverflow)
        }
    }
}
