public enum QuickLookArchiveListingError: Error, Sendable, Equatable {
    case unsupportedFormat
    case encrypted
    case invalidEntryPath
    case resourceLimitExceeded
    case unreadableArchive
}
