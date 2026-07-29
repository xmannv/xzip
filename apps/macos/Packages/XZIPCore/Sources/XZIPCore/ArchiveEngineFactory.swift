import Foundation
import XZIPDomain

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
        runner: (any ProcessControlling)? = nil,
        locator: BinaryLocating,
        policy: ArchiveResourcePolicy = .production
    ) -> ArchiveEngineFactory {
        let processController = runner ?? ProcessController(
            policy: policy,
            permits: LocalProcessPermitPool(
                limit: policy.scheduling.globalProcessLimit
            )
        )
        return ArchiveEngineFactory(engines: [
            SevenZipEngine(
                runner: processController,
                locator: locator,
                policy: policy
            ),
            DMGEngine(runner: processController)
        ])
    }

    public func engine(for format: ArchiveFormat) throws -> any ArchiveEngine {
        guard let engine = engines.first(where: { $0.supportedFormats.contains(format) }) else {
            throw ArchiveEngineError.unsupportedFormat(format)
        }
        return engine
    }

    public func engine(forArchive url: URL) throws -> any ArchiveEngine {
        guard let format = ArchiveFormatDetector.detect(fileAt: url) else {
            throw ArchiveEngineError.unsupportedArchive(filename: url.lastPathComponent)
        }
        return try engine(for: format)
    }
}
