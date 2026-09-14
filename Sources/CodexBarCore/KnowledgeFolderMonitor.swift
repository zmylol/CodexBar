import CoreServices
import Darwin
import Foundation

package protocol KnowledgeFolderObservation: Sendable {
    func stop()
}

package typealias KnowledgeFolderObserver = @Sendable (
    URL, DispatchQueue, @escaping @MainActor @Sendable () -> Void
) throws -> any KnowledgeFolderObservation

/// Recursive filesystem notifications for an explicitly selected vault, without a polling timer.
@MainActor
public final class KnowledgeFolderMonitor {
    private var worker: KnowledgeFolderMonitorWorker?
    private let observe: KnowledgeFolderObserver
    private var generation: UUID?
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var pendingNotification: Task<Void, Never>?

    public init() {
        observe = { root, queue, changed in
            try KnowledgeFolderEventStream(root: root, queue: queue,
                                          context: KnowledgeFolderEventContext(changed: changed))
        }
    }

    package init(observe: @escaping KnowledgeFolderObserver) {
        self.observe = observe
    }

    /// Start before capturing the initial baseline so edits made during capture trigger another pass.
    public func start(root: URL, onChange: @escaping @MainActor @Sendable () -> Void) async throws {
        stop()
        try Task.checkCancellation()
        let generation = UUID()
        let worker = KnowledgeFolderMonitorWorker(observe: observe)
        self.worker = worker
        self.generation = generation
        self.onChange = onChange
        let changed: @MainActor @Sendable () -> Void = { [weak self] in
            self?.changed(generation: generation)
        }
        do {
            try await withTaskCancellationHandler {
                try await worker.start(root: root, changed: changed)
            } onCancel: { [weak self] in
                worker.stop()
                Task { @MainActor [weak self] in
                    guard self?.generation == generation else { return }
                    self?.stop()
                }
            }
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
        } catch {
            worker.stop()
            if self.generation == generation { stop() }
            throw error
        }
    }

    public func stop() {
        generation = nil
        pendingNotification?.cancel()
        pendingNotification = nil
        onChange = nil
        worker?.stop()
        worker = nil
    }

    deinit { pendingNotification?.cancel() }

    private func changed(generation: UUID) {
        guard self.generation == generation, pendingNotification == nil else { return }
        pendingNotification = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, self.generation == generation else { return }
            self.pendingNotification = nil
            self.onChange?()
        }
    }
}

/// Each selection owns its queue so a blocked old filesystem cannot delay a new selection.
private final class KnowledgeFolderMonitorWorker: Sendable {
    private let queue = DispatchQueue(label: "com.codexbar.knowledge-folder", qos: .utility)
    private let state: State

    init(observe: @escaping KnowledgeFolderObserver) { state = State(observe: observe) }

    func start(root: URL, changed: @escaping @MainActor @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [state, queue] in
                do {
                    guard !state.stopped else { throw CancellationError() }
                    var status = stat()
                    guard root.isFileURL, lstat(root.path, &status) == 0,
                          status.st_mode & S_IFMT == S_IFDIR else {
                        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
                    }
                    state.observation = try state.observe(root, queue, changed)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() { queue.async { [state] in state.stop() } }

    deinit { queue.async { [state] in state.stop() } }

    /// Accessed only by the worker's queue, including cleanup after the worker is released.
    private final class State: @unchecked Sendable {
        let observe: KnowledgeFolderObserver
        var observation: (any KnowledgeFolderObservation)?
        var stopped = false

        init(observe: @escaping KnowledgeFolderObserver) { self.observe = observe }

        func stop() {
            stopped = true
            observation?.stop()
            observation = nil
        }
    }
}

private final class KnowledgeFolderEventContext: Sendable {
    let changed: @MainActor @Sendable () -> Void

    init(changed: @escaping @MainActor @Sendable () -> Void) { self.changed = changed }
}

/// Owns the C stream outside actor isolation; invalidation precedes releasing its callback context.
private final class KnowledgeFolderEventStream: KnowledgeFolderObservation, @unchecked Sendable {
    private var stream: FSEventStreamRef?

    init(root: URL, queue: DispatchQueue, context: KnowledgeFolderEventContext) throws {
        var streamContext = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<KnowledgeFolderEventContext>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<KnowledgeFolderEventContext>.fromOpaque(info).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                                            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, _, _, _ in
            guard let info else { return }
            let context = Unmanaged<KnowledgeFolderEventContext>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in context.changed() }
        }, &streamContext, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path])
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path])
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
