import Foundation
import XCTest
@testable import XZIPDomain

final class OperationDescriptorTests: XCTestCase {
    func testOperationIdentityTypesRoundTrip() throws {
        let values = [
            try JSONEncoder().encode(OperationID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)),
            try JSONEncoder().encode(ArchiveSessionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)),
            try JSONEncoder().encode(AuthenticationContextID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!))
        ]

        let editKey = EditSessionKey(
            archiveID: ArchiveID(identity: .canonicalPath(
                path: "/archive-a.zip",
                incarnation: ArchiveIncarnationToken(
                    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
                )
            )),
            entryPath: "docs/report.txt"
        )
        let decodedEditKey = try JSONDecoder().decode(
            EditSessionKey.self,
            from: JSONEncoder().encode(editKey)
        )

        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(decodedEditKey, editKey)
    }

    func testCompressionPayloadPreservesExactRetryOptions() throws {
        let payload = CompressionOperationPayload(
            sources: [.init(identity: nil, url: URL(fileURLWithPath: "/input"))],
            destination: .init(identity: nil, url: URL(fileURLWithPath: "/output.7z")),
            formatIdentifier: "7z",
            compressionLevel: 9,
            encryptFileNames: true,
            volumeSizeBytes: 64 * 1_024 * 1_024,
            exclusionPatterns: ["*.tmp", ".DS_Store"],
            preserveTimestamps: true,
            conflictPolicy: .fail
        )

        let decoded = try JSONDecoder().decode(
            CompressionOperationPayload.self,
            from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded, payload)
    }

    func testCreateEntryPayloadPreservesArchivePathNameAndKind() throws {
        let payload = CreateEntryOperationPayload(
            archive: .init(
                identity: .canonicalPath(
                    path: "/archive.zip",
                    incarnation: ArchiveIncarnationToken(
                        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
                    )
                ),
                url: URL(fileURLWithPath: "/archive.zip")
            ),
            parentPath: "docs",
            name: "report.txt",
            kind: .file
        )

        let decoded = try JSONDecoder().decode(
            CreateEntryOperationPayload.self,
            from: JSONEncoder().encode(payload)
        )
        XCTAssertEqual(decoded, payload)
    }

    func testOperationDescriptorRoundTripsEveryCompressionRetryOptionWithoutCredentials() throws {
        let archiveID = ArchiveID(identity: .canonicalPath(
            path: "/output.7z",
            incarnation: ArchiveIncarnationToken(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
            )
        ))
        let descriptor = OperationDescriptor(
            operationID: OperationID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
            ),
            archiveID: archiveID,
            sessionID: ArchiveSessionID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
            ),
            payload: .compress(.init(
                sources: [.init(identity: nil, url: URL(fileURLWithPath: "/input"))],
                destination: .init(
                    identity: archiveID.identity,
                    url: URL(fileURLWithPath: "/output.7z")
                ),
                formatIdentifier: "7z",
                compressionLevel: 9,
                encryptFileNames: true,
                volumeSizeBytes: 64 * 1_024 * 1_024,
                exclusionPatterns: ["*.tmp"],
                preserveTimestamps: true,
                conflictPolicy: .fail
            )),
            resourcePolicy: .production,
            ui: .init(title: "Compress")
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(OperationDescriptor.self, from: data)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8)).lowercased()

        XCTAssertEqual(decoded, descriptor)
        XCTAssertEqual(decoded.kind, .compress)
        for forbidden in ["password", "credential", "token", "closure"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }
}
