import Foundation

/// Serializes the archive mutations that rewrite a file in place (add / delete /
/// rename / repack / edit-save-back).
///
/// Two concurrent `7zz` rewrites of the same archive race on the temp-then-swap
/// that every mutation ends with: both read the original, both write a new file,
/// and the second swap wins — silently discarding the first change, or leaving a
/// half-written archive if they interleave. Every write path must therefore pass
/// through this gate.
///
/// The gate deliberately offers **two** admission policies, because the callers
/// have opposite failure requirements:
///
/// - ``claim(archive:_:)`` / ``tryRun(archive:_:)`` refuse when the archive is
///   already being mutated. Used for actions the user explicitly triggered (a
///   drop, a delete, a rename): the user is present, so telling them to retry is
///   honest and cheaper than queueing work they may no longer want.
/// - ``enqueue(archive:_:)`` waits its turn instead of refusing. Used for
///   Edit & Save Back, which is driven by a file-system watcher rather than a
///   button: dropping that write would discard an edit the user already made in
///   their editor and believes is saved.
///
/// Work is serialized per archive (keyed by standardized URL), so mutating two
/// different archives at once still runs in parallel — only same-file writes
/// wait for each other.
///
/// The gate is owned by `ArchiveService`, which takes the turn inside every
/// mutation method. Callers pick a policy with ``Admission`` but cannot reach
/// the writer without one, so "forgot to gate this write path" is no longer
/// expressible (it used to be a convention every call site had to remember).
@MainActor
final class ArchiveMutationGate {
    /// Which admission policy a mutation wants when the archive is already busy.
    ///
    /// Passed down through `ArchiveService`'s mutation methods so the choice
    /// stays with the caller that knows whether its write can be dropped.
    enum Admission: Sendable {
        /// Fail fast with ``ArchiveBusyError`` (user-driven actions).
        case refuseIfBusy
        /// Queue behind the running mutation (writes that must not be lost).
        case waitTurn
    }

    /// Thrown by ``claim(archive:_:)`` when another mutation holds the archive.
    ///
    /// Carries the archive so a caller handling several archives can tell which
    /// one was refused; the message is what the UI shows.
    struct ArchiveBusyError: Error, LocalizedError, Equatable {
        let archive: URL

        var errorDescription: String? {
            String(localized: "Another change to this archive is still in progress. Please wait for it to finish.")
        }
    }

    /// The in-flight mutation for one archive. The generation distinguishes
    /// successive mutations of the same archive so a finishing task never clears
    /// a slot that a newer mutation has already claimed.
    private struct Slot {
        /// Completes when the mutation has finished, whatever its outcome. The
        /// next mutation in line waits on this.
        let barrier: Task<Void, Never>
        /// Cancels the mutation's actual work (see ``cancel(archive:)``).
        let cancel: @MainActor () -> Void
        let generation: Int
    }

    private var slots: [URL: Slot] = [:]
    private var lastGeneration = 0

    /// `nonisolated` so `ArchiveService` — a plain `Sendable` struct, not
    /// main-actor isolated — can create its own gate. Only the stored properties'
    /// empty initial values are written here, never isolated state.
    nonisolated init() {}

    /// Whether a mutation is currently running for `archive`.
    func isMutating(_ archive: URL) -> Bool {
        slots[Self.key(archive)] != nil
    }

    /// Run `body` only if no other mutation is touching `archive`.
    ///
    /// - Returns: `false` if the archive is busy and `body` was **not** started,
    ///   letting the caller surface a "still in progress" message.
    @discardableResult
    func tryRun(
        archive: URL,
        _ body: @escaping @Sendable @MainActor () async -> Void
    ) -> Bool {
        let key = Self.key(archive)
        guard slots[key] == nil else { return false }
        let generation = nextGeneration()
        let work = Task { @MainActor in await body() }
        // Nothing else can be queued for this archive (tryRun refuses while the
        // slot is taken), so the work task is its own barrier.
        slots[key] = Slot(
            barrier: work,
            cancel: { work.cancel() },
            generation: generation)
        Task { @MainActor [weak self] in
            await work.value
            self?.releaseSlot(key, generation: generation)
        }
        return true
    }

    /// Run `body` after any mutation already queued for `archive`, and return its
    /// result once it has finished.
    ///
    /// Unlike ``tryRun(archive:_:)`` this never drops the work, so callers that
    /// cannot afford to lose a write (Edit & Save Back) stay correct when the
    /// user mutates the same archive from the UI at the same time. Errors thrown
    /// by `body` propagate to the caller, which is what lets the save-back flow
    /// keep reporting a failed write instead of pretending it succeeded.
    @discardableResult
    func enqueue<T: Sendable>(
        archive: URL,
        _ body: @escaping @Sendable @MainActor () async throws -> T
    ) async throws -> T {
        let key = Self.key(archive)
        let predecessor = slots[key]?.barrier
        let generation = nextGeneration()
        let work = Task { @MainActor in
            // Awaiting the predecessor's *value* (rather than checking for
            // cancellation) keeps the chain intact even if that mutation was
            // cancelled: the successor must not start until 7zz has actually
            // exited, or both processes would rewrite the same file.
            await predecessor?.value
            return try await body()
        }
        // The barrier is separate from `work` because `work` is throwing and
        // typed; the queue only needs "when is this archive free again?".
        let barrier = Task { @MainActor [weak self] in
            _ = try? await work.value
            self?.releaseSlot(key, generation: generation)
        }
        slots[key] = Slot(
            barrier: barrier,
            cancel: { work.cancel() },
            generation: generation)
        return try await work.value
    }

    /// Run `body` only if no other mutation is touching `archive`, and return its
    /// result once it has finished.
    ///
    /// The awaiting sibling of ``tryRun(archive:_:)``: the refusal arrives as a
    /// thrown ``ArchiveBusyError`` instead of a `false` return, which is what
    /// lets `ArchiveService`'s `async` mutation methods take the turn themselves
    /// rather than trusting each caller to do it.
    @discardableResult
    func claim<T: Sendable>(
        archive: URL,
        _ body: @escaping @Sendable @MainActor () async throws -> T
    ) async throws -> T {
        let key = Self.key(archive)
        guard slots[key] == nil else { throw ArchiveBusyError(archive: archive) }
        let generation = nextGeneration()
        let work = Task { @MainActor in try await body() }
        // The barrier is separate from `work` because `work` is throwing and
        // typed; queued mutations only need "when is this archive free again?".
        let barrier = Task { @MainActor [weak self] in
            _ = try? await work.value
            self?.releaseSlot(key, generation: generation)
        }
        slots[key] = Slot(
            barrier: barrier,
            cancel: { work.cancel() },
            generation: generation)
        return try await work.value
    }

    /// Cancel the in-flight mutation for `archive` (the repack sheet's Cancel).
    ///
    /// Mutations only touch the original archive in their final swap, so a
    /// cancelled mutation leaves the archive as it was.
    func cancel(archive: URL) {
        slots[Self.key(archive)]?.cancel()
    }

    /// Free the archive's slot unless a newer mutation has already claimed it.
    private func releaseSlot(_ key: URL, generation: Int) {
        guard slots[key]?.generation == generation else { return }
        slots[key] = nil
    }

    private func nextGeneration() -> Int {
        lastGeneration &+= 1
        return lastGeneration
    }

    /// Mutations are matched by standardized URL so `/tmp/a.zip` and
    /// `/private/tmp/./a.zip` are recognized as the same file.
    private static func key(_ archive: URL) -> URL {
        archive.standardizedFileURL
    }
}
