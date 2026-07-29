import Darwin
import Foundation
import XZIPDomain

public enum ProcessWorkload: Hashable, Sendable {
    case metadata(volumeIDs: Set<UInt64>)
    case heavyIO(volumeIDs: Set<UInt64>)
}

public struct ProcessPermitRequest: Hashable, Sendable {
    public let workload: ProcessWorkload

    public init(workload: ProcessWorkload) {
        self.workload = workload
    }
}

public protocol ProcessPermitAcquiring: Sendable {
    func acquire(_ request: ProcessPermitRequest) async throws -> ProcessPermit
}

public final class ProcessPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var releaseOperation: (@Sendable () async -> Void)?

    public init(releaseOperation: @escaping @Sendable () async -> Void) {
        self.releaseOperation = releaseOperation
    }

    public func release() async {
        let operation = lock.withLock {
            let operation = releaseOperation
            releaseOperation = nil
            return operation
        }
        await operation?()
    }
}

public actor LocalProcessPermitPool: ProcessPermitAcquiring {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<ProcessPermit, Error>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    public init(limit: Int) {
        precondition(limit > 0, "Process permit limit must be positive")
        self.limit = limit
    }

    #if DEBUG
    var debugQueuedWaiterCount: Int { waiters.count }
    #endif

    public func acquire(_ request: ProcessPermitRequest) async throws -> ProcessPermit {
        _ = request
        try Task.checkCancellation()

        if activeCount < limit {
            activeCount += 1
            return makePermit()
        }

        let id = UUID()
        let permit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessPermit, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }

        do {
            try Task.checkCancellation()
            return permit
        } catch {
            await permit.release()
            throw error
        }
    }

    private func makePermit() -> ProcessPermit {
        ProcessPermit { [weak self] in
            await self?.releaseSlot()
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            precondition(activeCount > 0)
            activeCount -= 1
            return
        }

        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: makePermit())
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

public struct ProcessRequest: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL?
    public let environment: [String: String]?
    public let standardInput: Data?
    public let workload: ProcessWorkload

    public init(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        standardInput: Data?,
        workload: ProcessWorkload
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.standardInput = standardInput
        self.workload = workload
    }
}

public enum ProcessEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case terminated(ProcessResult)
}


private protocol ProcessOutputState: AnyObject, Sendable {
    func next() async throws -> ProcessEvent?
    func requestTermination()
    func cancel()

    #if DEBUG
    var debugCompletionCount: Int { get }
    #endif
}

private final class AdaptedProcessOutputState: ProcessOutputState, @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<ProcessEvent?, Error>

    private let lock = NSLock()
    private let onTerminationRequest: @Sendable () -> Void
    private let onCancel: @Sendable () -> Void
    private var pending: [ProcessEvent] = []
    private var waiter: Continuation?
    private var completionError: Error?
    private var isFinished = false
    private var terminationRequested = false
    private var producerTask: Task<Void, Never>?

    init(
        stream: AsyncThrowingStream<ProcessEvent, Error>,
        onTerminationRequest: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        self.onTerminationRequest = onTerminationRequest
        self.onCancel = onCancel
        self.producerTask = Task { [weak self] in
            do {
                for try await event in stream {
                    self?.yield(event)
                }
                self?.finish()
            } catch {
                self?.finish(throwing: error)
            }
        }
    }

    func next() async throws -> ProcessEvent? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !pending.isEmpty {
                    let event = pending.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: event)
                    return
                }
                if isFinished {
                    let error = completionError
                    lock.unlock()
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: nil)
                    }
                    return
                }
                precondition(waiter == nil)
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            cancel()
        }
    }

    func requestTermination() {
        lock.lock()
        guard !isFinished, !terminationRequested else {
            lock.unlock()
            return
        }
        terminationRequested = true
        lock.unlock()
        onTerminationRequest()
    }

    func cancel() {
        let continuation: Continuation?
        let task: Task<Void, Never>?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        completionError = ProcessRunnerError.cancelled
        pending.removeAll(keepingCapacity: false)
        continuation = waiter
        waiter = nil
        task = producerTask
        producerTask = nil
        lock.unlock()

        task?.cancel()
        onCancel()
        continuation?.resume(throwing: ProcessRunnerError.cancelled)
    }

    private func yield(_ event: ProcessEvent) {
        let continuation: Continuation?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        continuation = waiter
        waiter = nil
        if continuation == nil { pending.append(event) }
        lock.unlock()
        continuation?.resume(returning: event)
    }

    private func finish(throwing error: Error? = nil) {
        let continuation: Continuation?
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        completionError = error
        continuation = waiter
        waiter = nil
        producerTask = nil
        lock.unlock()

        if let continuation {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    #if DEBUG
    var debugCompletionCount: Int { 0 }
    #endif
}

public struct ProcessOutputStream: AsyncSequence, Sendable {
    public typealias Element = ProcessEvent

    private final class Storage: @unchecked Sendable {
        let state: any ProcessOutputState

        init(state: any ProcessOutputState) {
            self.state = state
        }

        deinit {
            state.cancel()
        }
    }

    private final class IteratorOwnership: @unchecked Sendable {
        private let lock = NSLock()
        private let state: any ProcessOutputState
        private var isFinished = false

        init(state: any ProcessOutputState) {
            self.state = state
        }

        func finish() {
            lock.lock()
            isFinished = true
            lock.unlock()
        }

        deinit {
            lock.lock()
            let shouldCancel = !isFinished
            isFinished = true
            lock.unlock()
            if shouldCancel { state.cancel() }
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let state: any ProcessOutputState
        private var ownership: IteratorOwnership?

        fileprivate init(state: any ProcessOutputState) {
            self.state = state
            self.ownership = IteratorOwnership(state: state)
        }

        public mutating func next() async throws -> ProcessEvent? {
            do {
                let event = try await state.next()
                if event == nil || event?.isTerminal == true {
                    ownership?.finish()
                    ownership = nil
                }
                return event
            } catch {
                ownership?.finish()
                ownership = nil
                throw error
            }
        }
    }

    private let storage: Storage

    fileprivate init(state: any ProcessOutputState) {
        self.storage = Storage(state: state)
    }

    /// Test adapter for deterministic fake event streams. Production process
    /// execution stays pull-driven through `ProcessController`.
    init(
        adapting stream: AsyncThrowingStream<ProcessEvent, Error>,
        onTerminationRequest: @escaping @Sendable () -> Void = {},
        onCancel: @escaping @Sendable () -> Void = {}
    ) {
        self.storage = Storage(state: AdaptedProcessOutputState(
            stream: stream,
            onTerminationRequest: onTerminationRequest,
            onCancel: onCancel
        ))
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(state: storage.state)
    }

    /// Requests child termination while preserving pending output and the
    /// canonical terminal event for the current consumer.
    public func requestTermination() {
        storage.state.requestTermination()
    }

    public func cancel() {
        storage.state.cancel()
    }

    func nextForLegacyAdapter() async throws -> ProcessEvent? {
        try await storage.state.next()
    }

    #if DEBUG
    public var debugCompletionCount: Int {
        storage.state.debugCompletionCount
    }
    #endif
}

public protocol ProcessControlling: Sendable {
    func run(_ request: ProcessRequest) -> ProcessOutputStream
}

struct ProcessControllerTestHooks: Sendable {
    let readHandle: (@Sendable (_ handleID: Int) -> Void)?
    let beforeRead: (@Sendable () -> Void)?
    let afterRead: (@Sendable (_ count: Int, _ errorNumber: Int32) -> Void)?
    let beforeClose: (@Sendable (_ handleID: Int) -> Void)?

    init(
        readHandle: (@Sendable (_ handleID: Int) -> Void)? = nil,
        beforeRead: (@Sendable () -> Void)? = nil,
        afterRead: (@Sendable (_ count: Int, _ errorNumber: Int32) -> Void)? = nil,
        beforeClose: (@Sendable (_ handleID: Int) -> Void)? = nil
    ) {
        self.readHandle = readHandle
        self.beforeRead = beforeRead
        self.afterRead = afterRead
        self.beforeClose = beforeClose
    }
}

public final class ProcessController: ProcessControlling, @unchecked Sendable {
    private let policy: ArchiveResourcePolicy
    private let permits: any ProcessPermitAcquiring
    private let testHooks: ProcessControllerTestHooks

    public init(
        policy: ArchiveResourcePolicy,
        permits: any ProcessPermitAcquiring
    ) {
        self.policy = policy
        self.permits = permits
        self.testHooks = ProcessControllerTestHooks()
    }

    init(
        policy: ArchiveResourcePolicy,
        permits: any ProcessPermitAcquiring,
        testHooks: ProcessControllerTestHooks
    ) {
        self.policy = policy
        self.permits = permits
        self.testHooks = testHooks
    }

    public func run(_ request: ProcessRequest) -> ProcessOutputStream {
        let state = RawProcessStreamState(
            request: request,
            policy: policy.process,
            permits: permits,
            testHooks: testHooks
        )
        state.start()
        return ProcessOutputStream(state: state)
    }
}

private extension ProcessEvent {
    var isTerminal: Bool {
        if case .terminated = self { return true }
        return false
    }
}

final class RawProcessStreamState: ProcessOutputState, @unchecked Sendable {
    private enum Channel: Sendable {
        case stdout
        case stderr
    }

    private typealias NextContinuation = CheckedContinuation<ProcessEvent?, Error>
    private typealias NextResult = Result<ProcessEvent?, Error>

    private let request: ProcessRequest
    private let policy: ArchiveResourcePolicy.Process
    private let permits: any ProcessPermitAcquiring
    private let testHooks: ProcessControllerTestHooks
    private let lock = NSLock()
    private let launchLock = NSLock()
    private let stdoutTail: BoundedDataTail
    private let stderrTail: BoundedDataTail

    private var startupTask: Task<Void, Never>?
    private var process: Process?
    private var permit: ProcessPermit?
    private var stdoutReadHandle: FileHandle?
    private var stderrReadHandle: FileHandle?
    private var stdoutWriteHandle: FileHandle?
    private var stderrWriteHandle: FileHandle?
    private var stdinReadHandle: FileHandle?
    private var stdinWriteHandle: FileHandle?

    private var stdoutEOF = false
    private var stderrEOF = false
    private var stdoutArmed = false
    private var stderrArmed = false
    private var stdoutReadInFlight = false
    private var stderrReadInFlight = false
    private var stdoutDeferredCloseHandle: FileHandle?
    private var stderrDeferredCloseHandle: FileHandle?
    private var stdoutPending: Data?
    private var stderrPending: Data?
    private var readyChannels: [Channel] = []
    private var waiter: NextContinuation?
    private var terminationStatus: Int32?
    private var completionError: Error?
    private var completionErrorDelivered = false
    private var terminalResult: ProcessResult?
    private var terminalEventEmitted = false
    private var cancellationRequested = false
    private var deliberateTerminationRequested = false
    private var deliberateTerminationSignalSent = false
    private var terminatedByDeliberateRequest = false
    private var terminationEscalationScheduled = false
    private var completionCount = 0

    init(
        request: ProcessRequest,
        policy: ArchiveResourcePolicy.Process,
        permits: any ProcessPermitAcquiring,
        testHooks: ProcessControllerTestHooks
    ) {
        self.request = request
        self.policy = policy
        self.permits = permits
        self.testHooks = testHooks
        self.stdoutTail = BoundedDataTail(limit: policy.stdoutBufferByteCap)
        self.stderrTail = BoundedDataTail(limit: policy.stderrTailByteCap)
    }

    deinit {
        cancel()
    }

    #if DEBUG
    var debugCompletionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return completionCount
    }
    #endif

    func start() {
        let task = Task { [weak self] in
            guard let self else { return }
            await self.acquirePermitAndLaunch()
        }

        lock.lock()
        startupTask = task
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func next() async throws -> ProcessEvent? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    func requestTermination() {
        launchLock.lock()

        let processToTerminate: Process?
        lock.lock()
        if cancellationRequested || completionCount > 0 || deliberateTerminationRequested {
            processToTerminate = nil
        } else if let process {
            if process.isRunning {
                deliberateTerminationRequested = true
                processToTerminate = process
            } else {
                processToTerminate = nil
            }
        } else {
            deliberateTerminationRequested = true
            processToTerminate = nil
        }
        lock.unlock()
        launchLock.unlock()

        terminateProcessIfNeeded(processToTerminate, deliberate: true)
    }

    func cancel() {
        launchLock.lock()

        let task: Task<Void, Never>?
        let processToTerminate: Process?
        let continuation: NextContinuation?
        let handles: [FileHandle]

        lock.lock()
        if cancellationRequested || completionCount > 0 {
            lock.unlock()
            launchLock.unlock()
            return
        }
        cancellationRequested = true
        task = startupTask
        startupTask = nil
        completionError = ProcessRunnerError.cancelled
        completionCount = 1
        continuation = waiter
        waiter = nil
        if continuation != nil { completionErrorDelivered = true }
        readyChannels.removeAll(keepingCapacity: false)
        stdoutPending = nil
        stderrPending = nil
        handles = detachHandlesLocked()
        processToTerminate = process
        lock.unlock()

        task?.cancel()
        close(handles)
        launchLock.unlock()

        terminateProcessIfNeeded(processToTerminate)
        continuation?.resume(throwing: ProcessRunnerError.cancelled)
        releasePermitIfProcessIsNotRunning()
    }

    private func acquirePermitAndLaunch() async {
        do {
            let acquiredPermit = try await permits.acquire(
                ProcessPermitRequest(workload: request.workload)
            )
            try launch(with: acquiredPermit)
        } catch {
            let mappedError: Error
            let wasCancelled = lock.withLock { cancellationRequested }
            if wasCancelled || error is CancellationError {
                mappedError = ProcessRunnerError.cancelled
            } else if let runnerError = error as? ProcessRunnerError {
                mappedError = runnerError
            } else {
                mappedError = error
            }
            finishFailure(mappedError)
        }
    }

    private func launch(with acquiredPermit: ProcessPermit) throws {
        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.currentDirectoryURL = request.workingDirectory
        process.environment = request.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe
        process.terminationHandler = { [self] process in
            processDidTerminate(
                process,
                status: process.terminationStatus,
                reason: process.terminationReason
            )
        }

        launchLock.lock()
        lock.lock()
        if cancellationRequested || completionCount > 0 {
            lock.unlock()
            launchLock.unlock()
            close([
                stdoutPipe.fileHandleForReading,
                stdoutPipe.fileHandleForWriting,
                stderrPipe.fileHandleForReading,
                stderrPipe.fileHandleForWriting,
                stdinPipe.fileHandleForReading,
                stdinPipe.fileHandleForWriting,
            ])
            Task { await acquiredPermit.release() }
            throw ProcessRunnerError.cancelled
        }

        self.process = process
        permit = acquiredPermit
        stdoutReadHandle = stdoutPipe.fileHandleForReading
        stderrReadHandle = stderrPipe.fileHandleForReading
        stdoutWriteHandle = stdoutPipe.fileHandleForWriting
        stderrWriteHandle = stderrPipe.fileHandleForWriting
        stdinReadHandle = stdinPipe.fileHandleForReading
        stdinWriteHandle = stdinPipe.fileHandleForWriting
        lock.unlock()

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            launchLock.unlock()
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let childHandles = takeParentChildHandlesAfterLaunch()
        close(childHandles)
        beginStandardInputWrite()
        armReadsForWaitingConsumer()
        let shouldTerminate = lock.withLock { deliberateTerminationRequested }
        launchLock.unlock()
        if shouldTerminate {
            terminateProcessIfNeeded(process, deliberate: true)
        }
    }

    private func beginStandardInputWrite() {
        lock.lock()
        guard let handle = stdinWriteHandle else {
            lock.unlock()
            return
        }
        let input = request.standardInput
        lock.unlock()

        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        guard let input else {
            try? handle.close()
            stdinDidClose(handle)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? handle.write(contentsOf: input)
            try? handle.close()
            self?.stdinDidClose(handle)
        }
    }

    private func stdinDidClose(_ handle: FileHandle) {
        lock.lock()
        if stdinWriteHandle === handle { stdinWriteHandle = nil }
        lock.unlock()
    }

    private func takeParentChildHandlesAfterLaunch() -> [FileHandle] {
        lock.lock()
        let handles = [stdoutWriteHandle, stderrWriteHandle, stdinReadHandle].compactMap { $0 }
        stdoutWriteHandle = nil
        stderrWriteHandle = nil
        stdinReadHandle = nil
        lock.unlock()
        return handles
    }

    private func armReadsForWaitingConsumer() {
        lock.lock()
        armReadsLocked()
        lock.unlock()
    }

    private func register(_ continuation: NextContinuation) {
        let immediate: NextResult?
        let handles: [FileHandle]

        lock.lock()
        precondition(waiter == nil, "Concurrent raw stream iteration is unsupported")

        if let completionError {
            if completionErrorDelivered {
                immediate = .success(nil)
            } else {
                completionErrorDelivered = true
                immediate = .failure(completionError)
            }
            handles = []
        } else if let event = popPendingLocked() {
            immediate = .success(event)
            handles = []
        } else {
            handles = prepareTerminalLocked()
            if let terminalResult, !terminalEventEmitted {
                terminalEventEmitted = true
                immediate = .success(.terminated(terminalResult))
            } else if terminalEventEmitted || completionCount > 0 {
                immediate = .success(nil)
            } else {
                waiter = continuation
                armReadsLocked()
                immediate = nil
            }
        }
        lock.unlock()

        close(handles)
        if let immediate { continuation.resume(with: immediate) }
    }

    private func armReadsLocked() {
        guard waiter != nil, completionCount == 0 else { return }

        if !stdoutEOF,
           stdoutPending == nil,
           !stdoutArmed,
           let stdoutReadHandle {
            stdoutArmed = true
            stdoutReadHandle.readabilityHandler = { [weak self] handle in
                self?.handleReadable(.stdout, from: handle)
            }
        }
        if !stderrEOF,
           stderrPending == nil,
           !stderrArmed,
           let stderrReadHandle {
            stderrArmed = true
            stderrReadHandle.readabilityHandler = { [weak self] handle in
                self?.handleReadable(.stderr, from: handle)
            }
        }
    }

    private func handleReadable(_ channel: Channel, from handle: FileHandle) {
        lock.lock()
        guard completionCount == 0, isArmedLocked(channel) else {
            lock.unlock()
            return
        }
        setArmedLocked(channel, false)
        setReadInFlightLocked(channel, true)
        handle.readabilityHandler = nil
        lock.unlock()

        testHooks.readHandle?(ObjectIdentifier(handle).hashValue)
        testHooks.beforeRead?()
        let chunkSize = max(1, policy.rawChunkByteCap)
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        let count: Int = buffer.withUnsafeMutableBytes { bytes in
            var result: Int
            repeat {
                result = Darwin.read(handle.fileDescriptor, bytes.baseAddress, chunkSize)
            } while result < 0 && errno == EINTR
            return result
        }
        let readErrorNumber = count < 0 ? errno : 0
        testHooks.afterRead?(count, readErrorNumber)

        let deferredCloseHandle: FileHandle?
        lock.lock()
        setReadInFlightLocked(channel, false)
        switch channel {
        case .stdout:
            deferredCloseHandle = stdoutDeferredCloseHandle
            stdoutDeferredCloseHandle = nil
        case .stderr:
            deferredCloseHandle = stderrDeferredCloseHandle
            stderrDeferredCloseHandle = nil
        }
        lock.unlock()
        close([deferredCloseHandle].compactMap { $0 })

        if count > 0 {
            received(Data(buffer.prefix(count)), from: channel)
        } else if count == 0 {
            reachedEOF(channel)
        } else {
            finishFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(readErrorNumber)))
        }
    }

    private func received(_ data: Data, from channel: Channel) {
        let continuation: NextContinuation?
        let event: ProcessEvent

        lock.lock()
        guard completionCount == 0 else {
            lock.unlock()
            return
        }

        switch channel {
        case .stdout:
            stdoutTail.append(data)
            event = .stdout(data)
        case .stderr:
            stderrTail.append(data)
            event = .stderr(data)
        }

        if let current = waiter {
            waiter = nil
            continuation = current
        } else {
            setPendingLocked(data, for: channel)
            readyChannels.append(channel)
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(returning: event)
    }

    private func reachedEOF(_ channel: Channel) {
        let completion: (NextContinuation, NextResult)?
        let handles: [FileHandle]

        lock.lock()
        switch channel {
        case .stdout: stdoutEOF = true
        case .stderr: stderrEOF = true
        }
        handles = prepareTerminalLocked()
        completion = takeTerminalWaiterLocked()
        lock.unlock()

        close(handles)
        if let completion { completion.0.resume(with: completion.1) }
    }

    private func processDidTerminate(
        _ process: Process,
        status: Int32,
        reason: Process.TerminationReason
    ) {
        process.terminationHandler = nil

        let completion: (NextContinuation, NextResult)?
        let handles: [FileHandle]
        let permitToRelease: ProcessPermit?

        lock.lock()
        terminationStatus = status
        terminatedByDeliberateRequest = deliberateTerminationSignalSent
            && reason == .uncaughtSignal
            && (status == SIGTERM || status == SIGKILL)
        permitToRelease = permit
        permit = nil
        handles = prepareTerminalLocked()
        completion = takeTerminalWaiterLocked()
        lock.unlock()

        close(handles)
        if let permitToRelease { Task { await permitToRelease.release() } }
        if let completion { completion.0.resume(with: completion.1) }
    }

    private func finishFailure(_ error: Error) {
        let continuation: NextContinuation?
        let handles: [FileHandle]
        let processToTerminate: Process?
        let permitToRelease: ProcessPermit?

        lock.lock()
        if completionCount > 0 {
            lock.unlock()
            return
        }
        completionError = error
        completionCount = 1
        continuation = waiter
        waiter = nil
        if continuation != nil { completionErrorDelivered = true }
        readyChannels.removeAll(keepingCapacity: false)
        stdoutPending = nil
        stderrPending = nil
        handles = detachHandlesLocked()
        processToTerminate = process
        if processToTerminate?.isRunning == true {
            permitToRelease = nil
        } else {
            permitToRelease = permit
            permit = nil
        }
        lock.unlock()

        close(handles)
        terminateProcessIfNeeded(processToTerminate)
        if let permitToRelease { Task { await permitToRelease.release() } }
        continuation?.resume(throwing: error)
    }

    private func prepareTerminalLocked() -> [FileHandle] {
        guard completionCount == 0,
              readyChannels.isEmpty,
              stdoutEOF,
              stderrEOF,
              let terminationStatus else {
            return []
        }

        terminalResult = ProcessResult(
            exitCode: terminationStatus,
            standardOutput: stdoutTail.string(),
            standardError: stderrTail.string(),
            wasTerminatedByRequest: terminatedByDeliberateRequest
        )
        completionCount = 1
        return detachHandlesLocked()
    }

    private func takeTerminalWaiterLocked() -> (NextContinuation, NextResult)? {
        guard let waiter,
              let terminalResult,
              !terminalEventEmitted else {
            return nil
        }
        self.waiter = nil
        terminalEventEmitted = true
        return (waiter, .success(.terminated(terminalResult)))
    }

    private func popPendingLocked() -> ProcessEvent? {
        while !readyChannels.isEmpty {
            switch readyChannels.removeFirst() {
            case .stdout:
                if let data = stdoutPending {
                    stdoutPending = nil
                    return .stdout(data)
                }
            case .stderr:
                if let data = stderrPending {
                    stderrPending = nil
                    return .stderr(data)
                }
            }
        }
        return nil
    }

    private func setPendingLocked(_ data: Data, for channel: Channel) {
        switch channel {
        case .stdout:
            precondition(stdoutPending == nil)
            stdoutPending = data
        case .stderr:
            precondition(stderrPending == nil)
            stderrPending = data
        }
    }

    private func isArmedLocked(_ channel: Channel) -> Bool {
        switch channel {
        case .stdout: stdoutArmed
        case .stderr: stderrArmed
        }
    }

    private func setArmedLocked(_ channel: Channel, _ armed: Bool) {
        switch channel {
        case .stdout: stdoutArmed = armed
        case .stderr: stderrArmed = armed
        }
    }

    private func setReadInFlightLocked(_ channel: Channel, _ inFlight: Bool) {
        switch channel {
        case .stdout: stdoutReadInFlight = inFlight
        case .stderr: stderrReadInFlight = inFlight
        }
    }

    private func detachHandlesLocked() -> [FileHandle] {
        stdoutArmed = false
        stderrArmed = false
        stdoutReadHandle?.readabilityHandler = nil
        stderrReadHandle?.readabilityHandler = nil

        var handles = [
            stdoutWriteHandle,
            stderrWriteHandle,
            stdinReadHandle,
            stdinWriteHandle,
        ].compactMap { $0 }
        if let stdoutReadHandle {
            if stdoutReadInFlight {
                stdoutDeferredCloseHandle = stdoutReadHandle
            } else {
                handles.append(stdoutReadHandle)
            }
        }
        if let stderrReadHandle {
            if stderrReadInFlight {
                stderrDeferredCloseHandle = stderrReadHandle
            } else {
                handles.append(stderrReadHandle)
            }
        }
        stdoutReadHandle = nil
        stderrReadHandle = nil
        stdoutWriteHandle = nil
        stderrWriteHandle = nil
        stdinReadHandle = nil
        stdinWriteHandle = nil
        return handles
    }

    private func close(_ handles: [FileHandle]) {
        for handle in handles {
            testHooks.beforeClose?(ObjectIdentifier(handle).hashValue)
            try? handle.close()
        }
    }

    private func terminateProcessIfNeeded(
        _ process: Process?,
        deliberate: Bool = false
    ) {
        guard let process else { return }

        lock.lock()
        guard !terminationEscalationScheduled, process.isRunning else {
            lock.unlock()
            return
        }
        terminationEscalationScheduled = true
        if deliberate { deliberateTerminationSignalSent = true }
        let pid = process.processIdentifier
        let gracePeriod = max(0, policy.terminationGracePeriod)
        lock.unlock()

        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) {
            if process.isRunning { _ = kill(pid, SIGKILL) }
        }
    }

    private func releasePermitIfProcessIsNotRunning() {
        let permitToRelease: ProcessPermit?
        lock.lock()
        if process?.isRunning == true {
            permitToRelease = nil
        } else {
            permitToRelease = permit
            permit = nil
        }
        lock.unlock()
        if let permitToRelease { Task { await permitToRelease.release() } }
    }
}

final class BoundedDataTail: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        guard limit > 0 else {
            data.removeAll(keepingCapacity: false)
            return
        }
        if chunk.count >= limit {
            data = Data(chunk.suffix(limit))
            return
        }

        data.append(chunk)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
    }

    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
