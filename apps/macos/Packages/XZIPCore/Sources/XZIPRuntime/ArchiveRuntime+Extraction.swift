import Foundation
import XZIPCore
import XZIPDomain

public struct ExtractionPreflightRequest: Sendable {
    public let operationID: OperationID
    public let sessionID: ArchiveSessionID
    public let archive: ArchiveLocator
    public let destination: URL
    public let selectedEntries: [String]
    public let conflictPolicy: OperationConflictPolicy
    public let preserveTimestamps: Bool
    public let resourcePolicy: ArchiveResourcePolicy
    public let ui: OperationUIMetadata

    public init(
        operationID: OperationID,
        sessionID: ArchiveSessionID,
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        conflictPolicy: OperationConflictPolicy,
        preserveTimestamps: Bool,
        resourcePolicy: ArchiveResourcePolicy,
        ui: OperationUIMetadata = .init(title: "Extract")
    ) {
        self.operationID = operationID
        self.sessionID = sessionID
        self.archive = archive
        self.destination = destination
        self.selectedEntries = selectedEntries
        self.conflictPolicy = conflictPolicy
        self.preserveTimestamps = preserveTimestamps
        self.resourcePolicy = resourcePolicy
        self.ui = ui
    }
}

public struct ExtractionConflictSummary: Equatable, Sendable {
    public let relativePath: String
    public let existingByteCount: UInt64?
    public let existingModificationDate: Date?
    public let replacesDirectorySubtree: Bool

    public init(
        relativePath: String,
        existingByteCount: UInt64?,
        existingModificationDate: Date?,
        replacesDirectorySubtree: Bool
    ) {
        self.relativePath = relativePath
        self.existingByteCount = existingByteCount
        self.existingModificationDate = existingModificationDate
        self.replacesDirectorySubtree = replacesDirectorySubtree
    }
}

public struct ExtractionPreflight: Equatable, Sendable {
    public let archive: ArchiveLocator
    public let archiveRevision: ArchiveRevision
    public let destination: URL
    public let destinationIdentity: ExtractionDestinationIdentity
    public let selectedEntries: [String]
    public let conflictPolicy: OperationConflictPolicy
    public let preserveTimestamps: Bool
    public let resourcePolicy: ArchiveResourcePolicy
    public let planDigest: ExtractionPlanDigest
    public let publicationBinding: [ExtractionPublicationBindingEntry]
    public let conflicts: [ExtractionConflictSummary]
    public let destructiveReplacementPaths: [String]

    public init(
        archive: ArchiveLocator,
        archiveRevision: ArchiveRevision,
        destination: URL,
        destinationIdentity: ExtractionDestinationIdentity,
        selectedEntries: [String],
        conflictPolicy: OperationConflictPolicy,
        preserveTimestamps: Bool,
        resourcePolicy: ArchiveResourcePolicy,
        planDigest: ExtractionPlanDigest,
        publicationBinding: [ExtractionPublicationBindingEntry],
        conflicts: [ExtractionConflictSummary],
        destructiveReplacementPaths: [String]
    ) {
        self.archive = archive
        self.archiveRevision = archiveRevision
        self.destination = destination
        self.destinationIdentity = destinationIdentity
        self.selectedEntries = selectedEntries
        self.conflictPolicy = conflictPolicy
        self.preserveTimestamps = preserveTimestamps
        self.resourcePolicy = resourcePolicy
        self.planDigest = planDigest
        self.publicationBinding = publicationBinding
        self.conflicts = conflicts
        self.destructiveReplacementPaths = destructiveReplacementPaths
    }

    public var requiresDestructiveReplacementApproval: Bool {
        conflictPolicy == .replace && !destructiveReplacementPaths.isEmpty
    }

    public func makeDestructiveReplacementApproval()
        -> DestructiveReplacementApproval
    {
        DestructiveReplacementApproval(
            archiveRevision: archiveRevision,
            destinationIdentity: destinationIdentity,
            conflictPolicy: conflictPolicy,
            planDigest: planDigest,
            publicationBinding: publicationBinding
        )
    }
}

public protocol ArchiveExtractionPreflighting: Sendable {
    func preflightExtraction(
        _ request: ExtractionPreflightRequest
    ) async throws -> ExtractionPreflight
}

public struct ExtractionRequest: Sendable {
    public let operationID: OperationID
    public let sessionID: ArchiveSessionID
    public let archive: ArchiveLocator
    public let destination: URL
    public let selectedEntries: [String]
    public let conflictPolicy: OperationConflictPolicy
    public let preserveTimestamps: Bool
    public let resourcePolicy: ArchiveResourcePolicy
    public let ui: OperationUIMetadata
    public let expectedArchiveRevision: ArchiveRevision?
    public let expectedDestinationIdentity: ExtractionDestinationIdentity?
    public let planDigest: ExtractionPlanDigest?
    public let publicationBinding: [ExtractionPublicationBindingEntry]?
    public let replacementApproval: DestructiveReplacementApproval?

    public init(
        operationID: OperationID,
        sessionID: ArchiveSessionID,
        archive: ArchiveLocator,
        destination: URL,
        selectedEntries: [String],
        conflictPolicy: OperationConflictPolicy,
        preserveTimestamps: Bool,
        resourcePolicy: ArchiveResourcePolicy,
        ui: OperationUIMetadata = .init(title: "Extract"),
        expectedArchiveRevision: ArchiveRevision? = nil,
        expectedDestinationIdentity: ExtractionDestinationIdentity? = nil,
        planDigest: ExtractionPlanDigest? = nil,
        publicationBinding: [ExtractionPublicationBindingEntry]? = nil,
        replacementApproval: DestructiveReplacementApproval? = nil
    ) {
        self.operationID = operationID
        self.sessionID = sessionID
        self.archive = archive
        self.destination = destination
        self.selectedEntries = selectedEntries
        self.conflictPolicy = conflictPolicy
        self.preserveTimestamps = preserveTimestamps
        self.resourcePolicy = resourcePolicy
        self.ui = ui
        self.expectedArchiveRevision = expectedArchiveRevision
        self.expectedDestinationIdentity = expectedDestinationIdentity
        self.planDigest = planDigest
        self.publicationBinding = publicationBinding
        self.replacementApproval = replacementApproval
    }
}

public extension ArchiveRuntimeClient {
    func extract(_ request: ExtractionRequest) async throws {
        let descriptor = OperationDescriptor(
            operationID: request.operationID,
            archiveID: request.archive.archiveID,
            sessionID: request.sessionID,
            payload: .extract(.init(
                archive: .init(
                    identity: request.archive.archiveID.identity,
                    url: request.archive.url
                ),
                destination: .init(identity: nil, url: request.destination),
                selectedEntryPaths: request.selectedEntries,
                conflictPolicy: request.conflictPolicy,
                preserveTimestamps: request.preserveTimestamps,
                expectedArchiveRevision: request.expectedArchiveRevision,
                expectedDestinationIdentity: request.expectedDestinationIdentity,
                planDigest: request.planDigest,
                publicationBinding: request.publicationBinding,
                replacementApproval: request.replacementApproval
            )),
            resourcePolicy: request.resourcePolicy,
            ui: request.ui
        )
        try await executeOperation(descriptor)
    }
}

protocol EphemeralExtractionCredentialResolving: Sendable {
    func resolveExtractionCredential(
        sessionID: ArchiveSessionID,
        operationID: OperationID,
        archiveID: ArchiveID
    ) async throws -> String?
}

struct ArchiveExtractionExecution: Sendable {
    let result: ExtractionResult
    let postTerminalFinalizer: @Sendable () async throws -> Void
}

enum ArchiveExtractionPreparation: Sendable {
    case fresh
    case committed(ArchiveExtractionExecution)
}

protocol ArchiveExtractionHandling: Sendable {
    func preflight(
        request: ExtractionPreflightRequest
    ) async throws -> ExtractionPreflight

    func prepare(
        descriptor: OperationDescriptor
    ) async throws -> ArchiveExtractionPreparation

    func executeFresh(
        payload: ExtractionOperationPayload,
        descriptor: OperationDescriptor,
        progress: @Sendable (ArchiveProgress) async -> Void
    ) async throws -> ArchiveExtractionExecution
}

enum ArchiveExtractionHandlerError: Error, Equatable, Sendable {
    case sessionRequired
    case archiveIDRequired
    case unreconciledOperation(OperationID)
}

struct TransactionalArchiveExtractionHandler: ArchiveExtractionHandling, Sendable {
    private let transaction: ExtractionTransaction
    private let durableResolver: any DurableExtractionResolving
    private let committedFinalizer: any CommittedExtractionFinalizing
    private let credentialResolver: (any EphemeralExtractionCredentialResolving)?

    init(
        transaction: ExtractionTransaction,
        durableResolver: any DurableExtractionResolving,
        committedFinalizer: any CommittedExtractionFinalizing,
        credentialResolver: (any EphemeralExtractionCredentialResolving)?
    ) {
        self.transaction = transaction
        self.durableResolver = durableResolver
        self.committedFinalizer = committedFinalizer
        self.credentialResolver = credentialResolver
    }

    func preflight(
        request: ExtractionPreflightRequest
    ) async throws -> ExtractionPreflight {
        var password = try await credentialResolver?.resolveExtractionCredential(
            sessionID: request.sessionID,
            operationID: request.operationID,
            archiveID: request.archive.archiveID
        )
        defer { password = nil }
        return try await transaction.preflight(request, password: password)
    }

    func prepare(
        descriptor: OperationDescriptor
    ) async throws -> ArchiveExtractionPreparation {
        switch try await durableResolver.resolveExtraction(for: descriptor.operationID) {
        case .absent:
            return .fresh
        case .unfinished, .rolledBack:
            throw ArchiveExtractionHandlerError.unreconciledOperation(descriptor.operationID)
        case let .committed(result):
            let operationID = descriptor.operationID
            let finalizer = committedFinalizer
            return .committed(ArchiveExtractionExecution(
                result: result,
                postTerminalFinalizer: {
                    try await finalizer.finalizeCommittedExtraction(operationID: operationID)
                }
            ))
        }
    }

    func executeFresh(
        payload: ExtractionOperationPayload,
        descriptor: OperationDescriptor,
        progress: @Sendable (ArchiveProgress) async -> Void
    ) async throws -> ArchiveExtractionExecution {
        guard let sessionID = descriptor.sessionID else {
            throw ArchiveExtractionHandlerError.sessionRequired
        }
        guard let archiveID = descriptor.archiveID else {
            throw ArchiveExtractionHandlerError.archiveIDRequired
        }

        var password = try await credentialResolver?.resolveExtractionCredential(
            sessionID: sessionID,
            operationID: descriptor.operationID,
            archiveID: archiveID
        )
        defer { password = nil }

        let request = ExtractionRequest(
            operationID: descriptor.operationID,
            sessionID: sessionID,
            archive: ArchiveLocator(archiveID: archiveID, url: payload.archive.url),
            destination: payload.destination.url,
            selectedEntries: payload.selectedEntryPaths,
            conflictPolicy: payload.conflictPolicy,
            preserveTimestamps: payload.preserveTimestamps,
            resourcePolicy: descriptor.resourcePolicy,
            ui: descriptor.ui,
            expectedArchiveRevision: payload.expectedArchiveRevision,
            expectedDestinationIdentity: payload.expectedDestinationIdentity,
            planDigest: payload.planDigest,
            publicationBinding: payload.publicationBinding,
            replacementApproval: payload.replacementApproval
        )
        let result = try await transaction.execute(
            request,
            password: password,
            progress: progress
        )
        let operationID = descriptor.operationID
        let finalizer = committedFinalizer
        return ArchiveExtractionExecution(
            result: result,
            postTerminalFinalizer: {
                try await finalizer.finalizeCommittedExtraction(operationID: operationID)
            }
        )
    }
}
