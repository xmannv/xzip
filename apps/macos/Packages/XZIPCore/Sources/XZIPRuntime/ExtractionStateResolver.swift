import Foundation
import XZIPCore
import XZIPDomain

struct ExtractionValidatedState: Equatable, Sendable {
    let archiveRevision: ArchiveRevision
    let destinationIdentity: ExtractionDestinationIdentity
    let destinationRootNodeIdentity: FileNodeIdentity
}

struct ExtractionStateResolver: Sendable {
    let archiveIdentityResolver: any ArchiveIdentityResolving
    let fileSystem: any FileSystemOperations

    func resolve(
        archive: URL,
        destination: URL
    ) throws -> ExtractionValidatedState {
        let resolvedArchive = try archiveIdentityResolver.resolve(archive)
        let parentURL = destination.deletingLastPathComponent()
        let component = destination.lastPathComponent
        guard !component.isEmpty else {
            throw FileSystemOperationError.invalidComponent(component)
        }

        let parent = try fileSystem.openDirectoryNoFollow(at: parentURL)
        defer { parent.close() }
        let parentNodeIdentity = try fileSystem.identity(of: parent)
        let rootNode = try fileSystem.statNoFollow(
            parent: parent,
            name: component
        )
        guard let rootNode else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
        guard rootNode.identity.kind == .directory else {
            throw FileSystemOperationError.notDirectory(component)
        }
        let root = try fileSystem.openDirectoryNoFollow(
            parent: parent,
            name: component,
            expected: rootNode.identity
        )
        defer { root.close() }
        let verifiedRootNodeIdentity = try fileSystem.identity(of: root)

        return ExtractionValidatedState(
            archiveRevision: resolvedArchive.revision,
            destinationIdentity: ExtractionDestinationIdentity(
                parent: domainIdentity(parentNodeIdentity),
                root: domainIdentity(verifiedRootNodeIdentity)
            ),
            destinationRootNodeIdentity: verifiedRootNodeIdentity
        )
    }

    private func domainIdentity(
        _ identity: FileNodeIdentity
    ) -> FileSystemIdentity {
        .stable(
            volumeIdentifier: identity.device,
            fileIdentifier: identity.inode,
            generation: identity.generation
        )
    }
}
