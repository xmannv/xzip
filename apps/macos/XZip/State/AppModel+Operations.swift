import Foundation
import Observation
import SwiftUI
import AppKit
import XZIPCore

extension AppModel {
    // MARK: - Operation plumbing

    /// Enqueue an operation, consume its progress stream, and keep the matching
    /// `ArchiveOperation` in `operations` updated for the Activity UI.
    ///
    /// - Parameters:
    ///   - outputURL: result location, enabling "Reveal" + notification actions.
    ///   - onComplete: main-actor hook fired on success (e.g. show Share card).
    ///   - makeStream: builds the progress stream to consume.
    func run(
        _ operation: ArchiveOperation,
        outputURL: URL? = nil,
        onComplete: (@MainActor (URL?) async -> Void)? = nil,
        onPasswordFailure: (@MainActor () -> Void)? = nil,
        _ makeStream: @escaping @Sendable () throws -> AsyncThrowingStream<Double, Error>
    ) {
        var op = operation
        op.outputURL = outputURL
        operations.insert(op, at: 0)
        let id = op.id
        let title = op.title
        // Store the work needed to re-run this exact operation (Retry, 1f/3e).
        retryActions[id] = { [weak self] in
            self?.updateOperation(id) { $0.state = .running; $0.progress = 0; $0.detail = "" }
            self?.startTask(id: id, title: title, kind: op.kind,
                            outputURL: outputURL, onComplete: onComplete,
                            onPasswordFailure: onPasswordFailure, makeStream: makeStream)
        }
        startTask(id: id, title: title, kind: op.kind,
                  outputURL: outputURL, onComplete: onComplete,
                  onPasswordFailure: onPasswordFailure, makeStream: makeStream)
    }

    /// Runs (or re-runs) the async work for an operation already in `operations`.
    private func startTask(
        id: ArchiveOperation.ID,
        title: String,
        kind: OperationKind,
        outputURL: URL?,
        onComplete: (@MainActor (URL?) async -> Void)?,
        onPasswordFailure: (@MainActor () -> Void)?,
        makeStream: @escaping @Sendable () throws -> AsyncThrowingStream<Double, Error>
    ) {
        // Track start time so we can estimate remaining time (ETA, mockup 3e).
        let startedAt = Date()
        // Bump the generation for this id; the teardown only clears the handle if
        // it still owns the latest generation.
        let generation = (taskGenerations[id] ?? 0) + 1
        taskGenerations[id] = generation
        runningTasks[id] = Task { [weak self] in
            do {
                let stream = try makeStream()
                // Throttle UI updates to whole-percent changes. 7zz emits a
                // progress line per file, so a many-file archive would otherwise
                // hop to the main actor and invalidate the window thousands of
                // times a second, saturating it.
                var lastShownPercent = -1
                for try await fraction in stream {
                    let percent = Int(fraction * 100)
                    guard percent != lastShownPercent else { continue }
                    lastShownPercent = percent
                    let eta = Self.estimateRemaining(fraction: fraction, since: startedAt)
                    await MainActor.run {
                        self?.updateOperation(id) {
                            $0.progress = fraction
                            $0.currentItem = eta.map { "\(percent)% · \($0)" }
                                ?? "\(percent)%"
                        }
                    }
                }
                // If the operation was cancelled or paused, the stream can still
                // finish normally (the process was terminated mid-run). Bail
                // before marking it completed so completion side effects — the
                // notification, the Share card, and "move source to Trash after
                // extract" — never fire for work the user stopped.
                try Task.checkCancellation()
                await MainActor.run {
                    self?.updateOperation(id) {
                        $0.progress = 1
                        $0.state = .completed
                        $0.currentItem = String(localized: "Completed")
                    }
                    self?.handleCompletion(title: title, kind: kind, outputURL: outputURL)
                }
                await onComplete?(outputURL)
                await MainActor.run {
                    // Success: drop the stored retry closure so it doesn't
                    // accumulate for the lifetime of the session.
                    self?.retryActions[id] = nil
                }
            } catch is CancellationError {
                // Already marked cancelled by `cancel(_:)`.
            } catch {
                await MainActor.run {
                    self?.updateOperation(id) {
                        $0.state = .failed
                        $0.detail = error.localizedDescription
                    }
                    // A password failure is recoverable: let the caller open the
                    // password prompt instead of dead-ending on the failed op.
                    switch error as? ArchiveEngineError {
                    case .wrongPassword?, .passwordRequired?:
                        onPasswordFailure?()
                    default:
                        break
                    }
                }
            }
            await MainActor.run {
                // Only clear the handle if a newer task (e.g. a retry) hasn't
                // already replaced it, otherwise the retry becomes uncancellable.
                if self?.taskGenerations[id] == generation {
                    self?.runningTasks[id] = nil
                }
            }
        }
    }

    /// Fire the system completion notification (mockup 4d).
    private func handleCompletion(title: String, kind: OperationKind, outputURL: URL?) {
        // A finished compress/extract may have written into the folder being
        // browsed — reload it so the new file appears without a manual refresh.
        if browsingFolder != nil {
            refreshFolder()
        }
        let body: String
        switch kind {
        case .compress: body = outputURL?.lastPathComponent ?? title
        case .extract: body = outputURL.map { "→ \($0.lastPathComponent)" } ?? title
        case .test: body = title
        }
        let heading = switch kind {
        case .compress: String(localized: "Compression complete")
        case .extract: String(localized: "Extraction complete")
        case .test: String(localized: "Test complete")
        }
        NotificationService.shared.notifyCompletion(title: heading, body: body, revealURL: outputURL)
    }

    /// Estimate remaining time from elapsed time and fraction done.
    private static func estimateRemaining(fraction: Double, since start: Date) -> String? {
        ArchiveBrowsing.estimateRemaining(
            fraction: fraction, elapsed: Date().timeIntervalSince(start))
    }

    /// Remove completed/cancelled operations from the queue (mockup 3e "Clear Done").
    func clearFinishedOperations() {
        let removed = operations.filter { $0.state == .completed || $0.state == .cancelled }
        operations.removeAll { $0.state == .completed || $0.state == .cancelled }
        // Drop the per-operation bookkeeping for the cleared items so it doesn't
        // grow without bound across a long session.
        for op in removed {
            runningTasks[op.id] = nil
            retryActions[op.id] = nil
            taskGenerations[op.id] = nil
        }
    }

    func updateOperation(_ id: ArchiveOperation.ID, _ mutate: (inout ArchiveOperation) -> Void) {
        guard let index = operations.firstIndex(where: { $0.id == id }) else { return }
        mutate(&operations[index])
    }
}
