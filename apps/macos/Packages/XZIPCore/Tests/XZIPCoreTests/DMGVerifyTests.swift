import Foundation
import XCTest
@testable import XZIPCore

/// Tests for `DMGEngine.test` and its failure classification (E6).
///
/// `test` used to `return result.isSuccess`, collapsing every cause of failure
/// into a single `false`. `SevenZipEngine.test` throws a classified error for the
/// same protocol requirement, and the UI turns `false` into "Archive failed the
/// integrity test" — so verifying an encrypted image with the wrong password told
/// the user their file was damaged, offering no way to retry.
///
/// The companion 7-Zip assertions live in `PureLogicTests.testErrorMapping`.
final class DMGVerifyTests: XCTestCase {

    // MARK: - test() surfaces the reason

    func testWrongPasswordIsReportedAsWrongPasswordNotFailedIntegrity() async throws {
        let engine = DMGEngine(
            runner: FakeHDIUtilVerifyRunner(
                stderr: "hdiutil: verify: Authentication error"
            )
        )
        do {
            _ = try await engine.test(
                archive: URL(fileURLWithPath: "/tmp/secret.dmg"),
                password: "wrong"
            )
            XCTFail("Expected a thrown error rather than false")
        } catch let error as ArchiveEngineError {
            XCTAssertEqual(error, .wrongPassword)
        }
    }

    func testMissingPasswordIsReportedAsPasswordRequired() async throws {
        let engine = DMGEngine(
            runner: FakeHDIUtilVerifyRunner(
                stderr: "hdiutil: verify: Authentication error"
            )
        )
        do {
            _ = try await engine.test(
                archive: URL(fileURLWithPath: "/tmp/secret.dmg"),
                password: nil
            )
            XCTFail("Expected a thrown error rather than false")
        } catch let error as ArchiveEngineError {
            XCTAssertEqual(error, .passwordRequired)
        }
    }

    func testSuccessfulVerificationStillReturnsTrue() async throws {
        let engine = DMGEngine(runner: FakeHDIUtilVerifyRunner(stderr: nil))
        let verified = try await engine.test(
            archive: URL(fileURLWithPath: "/tmp/ok.dmg"),
            password: nil
        )
        XCTAssertTrue(verified)
    }

    // MARK: - Classification

    func testUnambiguousEncryptionSignalsMapToPasswordErrors() {
        for stderr in [
            "hdiutil: attach: Authentication error",
            "Invalid passphrase supplied",
            "hdiutil: bad password"
        ] {
            XCTAssertEqual(
                DMGEngine.mapHDIUtilFailure(stderr, hadPassword: true),
                .wrongPassword,
                "\(stderr) with a supplied password"
            )
            XCTAssertEqual(
                DMGEngine.mapHDIUtilFailure(stderr, hadPassword: false),
                .passwordRequired,
                "\(stderr) with no password supplied"
            )
        }
    }

    func testCorruptImageIsResolvedByWhetherAPasswordWasSupplied() {
        // hdiutil says "corrupt image" both for a bad passphrase and for genuine
        // damage. It used to be treated as an encryption signal unconditionally,
        // so a corrupt *unencrypted* image asked the user for a password that was
        // never the problem.
        let stderr = "hdiutil: verify: corrupt image"

        XCTAssertEqual(
            DMGEngine.mapHDIUtilFailure(stderr, hadPassword: true),
            .wrongPassword,
            "a password was supplied, so a bad passphrase is the retryable explanation"
        )
        XCTAssertEqual(
            DMGEngine.mapHDIUtilFailure(stderr, hadPassword: false),
            .corruptedArchive(stderr),
            "no password was supplied, so nothing suggests encryption"
        )
    }

    func testUnrelatedFailuresArePassedThroughVerbatim() {
        // Not every failure is about passwords; misclassifying these as password
        // problems would send the user into a prompt loop over a missing file.
        let stderr = "hdiutil: verify: no such file or directory"
        XCTAssertEqual(
            DMGEngine.mapHDIUtilFailure(stderr, hadPassword: false),
            .engineFailure(stderr)
        )
        XCTAssertEqual(
            DMGEngine.mapHDIUtilFailure(stderr, hadPassword: true),
            .engineFailure(stderr)
        )
    }
}

/// Stands in for `hdiutil verify`; a non-nil `stderr` makes it fail.
private final class FakeHDIUtilVerifyRunner:
    ProcessRunning,
    ProcessControlling,
    @unchecked Sendable
{
    private let stderr: String?

    init(stderr: String?) {
        self.stderr = stderr
    }

    func run(_ request: ProcessRequest) -> ProcessOutputStream {
        ProcessOutputStream(adapting: AsyncThrowingStream { continuation in
            do {
                continuation.yield(.terminated(try execute(arguments: request.arguments)))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        })
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> ProcessResult {
        try execute(arguments: arguments)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) async throws -> ProcessResult {
        try execute(arguments: arguments)
    }

    func runStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputLine, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeVerifyError.unexpectedInvocation) }
    }

    func runRawStreaming(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: String?
    ) -> AsyncThrowingStream<ProcessOutputChunk, Error> {
        AsyncThrowingStream { $0.finish(throwing: FakeVerifyError.unexpectedInvocation) }
    }

    private func execute(arguments: [String]) throws -> ProcessResult {
        guard arguments.first == "verify" else {
            throw FakeVerifyError.unexpectedInvocation
        }
        guard let stderr else {
            return ProcessResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        return ProcessResult(exitCode: 1, standardOutput: "", standardError: stderr)
    }
}

private enum FakeVerifyError: Error {
    case unexpectedInvocation
}
