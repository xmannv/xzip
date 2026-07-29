import Foundation
import XZIPCore

public struct TransactionNamespaceLocator: Hashable, Codable, Sendable {
    public let url: URL
    public let identity: FileNodeIdentity

    public init(url: URL, identity: FileNodeIdentity) {
        self.url = url
        self.identity = identity
    }
}

public protocol TransactionNamespaceProviding: Sendable {
    func namespace(
        forDestinationIdentity destinationIdentity: FileNodeIdentity
    ) async throws -> TransactionNamespaceLocator
}

public actor AppSupportTransactionNamespaceProvider: TransactionNamespaceProviding {
    private let locator: TransactionNamespaceLocator

    public init(
        applicationSupportDirectory: URL,
        namespaceName: String,
        fileSystem: any FileSystemOperations
    ) throws {
        let parent = try fileSystem.openDirectoryNoFollow(at: applicationSupportDirectory)
        defer { parent.close() }

        let namespaceURL = applicationSupportDirectory
            .appendingPathComponent(namespaceName, isDirectory: true)
        let namespace: DirectoryHandle
        if let existing = try fileSystem.statNoFollow(parent: parent, name: namespaceName) {
            guard existing.identity.kind == .directory else {
                throw FileSystemOperationError.notDirectory(namespaceName)
            }
            namespace = try fileSystem.openTransactionOwnedDirectoryNoFollow(
                at: namespaceURL,
                expected: existing.identity
            )
        } else {
            namespace = try fileSystem.createTransactionDirectoryExclusive(
                parent: parent,
                name: namespaceName
            )
        }
        defer { namespace.close() }

        try fileSystem.fsync(namespace)
        try fileSystem.fsync(parent)
        self.locator = TransactionNamespaceLocator(
            url: namespaceURL,
            identity: try fileSystem.identity(of: namespace)
        )
    }

    public func namespace(
        forDestinationIdentity destinationIdentity: FileNodeIdentity
    ) async throws -> TransactionNamespaceLocator {
        guard destinationIdentity.device == locator.identity.device else {
            throw TransactionJournalError.unavailableDestinationVolume(destinationIdentity.device)
        }
        return locator
    }

    public func trustedNamespace() async -> TransactionNamespaceLocator {
        locator
    }
}
