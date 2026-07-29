import Darwin
import Foundation
import XCTest
import XZIPCore
@testable import XZIPRuntime

final class TransactionNamespaceProviderTests: XCTestCase {
    func testProviderProvisionsExactPrivateNamespaceAndReturnsOnlyMatchingVolume() async throws {
        let root = try makeRoot()
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(applicationSupport.path, 0o700), 0)
        let fileSystem = DarwinFileSystemOperations()

        let provider = try AppSupportTransactionNamespaceProvider(
            applicationSupportDirectory: applicationSupport,
            namespaceName: "transactions",
            fileSystem: fileSystem
        )
        let trusted = await provider.trustedNamespace()
        let matched = try await provider.namespace(forDestinationIdentity: trusted.identity)

        XCTAssertEqual(matched, trusted)
        XCTAssertEqual(trusted.url, applicationSupport.appendingPathComponent("transactions", isDirectory: true))
        let handle = try fileSystem.openTransactionOwnedDirectoryNoFollow(
            at: trusted.url,
            expected: trusted.identity
        )
        XCTAssertEqual(try fileSystem.identity(of: handle), trusted.identity)

        let differentDevice = FileNodeIdentity(
            device: trusted.identity.device ^ 1,
            inode: trusted.identity.inode,
            generation: trusted.identity.generation,
            kind: .directory
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await provider.namespace(forDestinationIdentity: differentDevice)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applicationSupport.path), ["transactions"])
    }

    func testProviderReopensSameIdentityWithoutOnDemandSiblingCreation() async throws {
        let root = try makeRoot()
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(applicationSupport.path, 0o700), 0)
        let fileSystem = DarwinFileSystemOperations()
        let first = try AppSupportTransactionNamespaceProvider(
            applicationSupportDirectory: applicationSupport,
            namespaceName: "transactions",
            fileSystem: fileSystem
        )
        let firstLocator = await first.trustedNamespace()

        let reopened = try AppSupportTransactionNamespaceProvider(
            applicationSupportDirectory: applicationSupport,
            namespaceName: "transactions",
            fileSystem: fileSystem
        )
        let secondLocator = await reopened.trustedNamespace()

        XCTAssertEqual(secondLocator, firstLocator)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applicationSupport.path), ["transactions"])
    }

    func testProviderRejectsSymlinkFileAndWrongModeNamespace() throws {
        for kind in ["symlink", "file", "wrong-mode"] {
            let root = try makeRoot()
            let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            XCTAssertEqual(chmod(applicationSupport.path, 0o700), 0)
            let namespace = applicationSupport.appendingPathComponent("transactions")
            switch kind {
            case "symlink":
                let target = root.appendingPathComponent("target", isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(
                    atPath: namespace.path,
                    withDestinationPath: target.path
                )
            case "file":
                try Data().write(to: namespace)
            default:
                try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
                XCTAssertEqual(chmod(namespace.path, 0o755), 0)
            }

            XCTAssertThrowsError(try AppSupportTransactionNamespaceProvider(
                applicationSupportDirectory: applicationSupport,
                namespaceName: "transactions",
                fileSystem: DarwinFileSystemOperations()
            ))
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransactionNamespaceProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
