import Foundation

/// Selects the appropriate `ArchiveEngine` for a given format.
///
/// Design: the Factory pattern. Today a single `SevenZipEngine` covers all
/// supported formats, but routing through a factory means we can add a
/// `LibarchiveEngine` (or a native ZIP engine) later and register it for
/// specific formats without touching call sites.
public protocol ArchiveEngineProviding: Sendable {
    func engine(for format: ArchiveFormat) throws -> any ArchiveEngine
    func engine(forArchive url: URL) throws -> any ArchiveEngine
}

public struct ArchiveEngineFactory: ArchiveEngineProviding {
    private let engines: [any ArchiveEngine]

    /// Injects the concrete engines to route between (Dependency Injection).
    public init(engines: [any ArchiveEngine]) {
        self.engines = engines
    }

    /// Convenience factory wiring the default 7-Zip engine.
    public static func makeDefault(
        runner: ProcessRunning = FoundationProcessRunner(),
        locator: BinaryLocating
    ) -> ArchiveEngineFactory {
        ArchiveEngineFactory(engines: [
            SevenZipEngine(runner: runner, locator: locator),
            DMGEngine(runner: runner)
        ])
    }

    public func engine(for format: ArchiveFormat) throws -> any ArchiveEngine {
        guard let engine = engines.first(where: { $0.supportedFormats.contains(format) }) else {
            throw ArchiveEngineError.unsupportedFormat(format)
        }
        return engine
    }

    public func engine(forArchive url: URL) throws -> any ArchiveEngine {
        // Prefer content-based detection (magic bytes); it also falls back to
        // extension inference internally for unknown headers.
        guard let format = ArchiveFormatDetector.detect(fileAt: url) else {
            // Last resort: the first engine can still attempt to sniff contents.
            if let first = engines.first { return first }
            throw ArchiveEngineError.engineFailure("No engine available.")
        }
        return try engine(for: format)
    }
}
