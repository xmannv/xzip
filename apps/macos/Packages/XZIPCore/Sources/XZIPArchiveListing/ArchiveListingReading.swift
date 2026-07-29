import Foundation
import XZIPCore

public protocol ArchiveListingReading: Sendable {
    func list(archive: URL, limit: Int) async throws -> ArchiveListingResult
}
