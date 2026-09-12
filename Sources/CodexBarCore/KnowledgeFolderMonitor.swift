import CoreServices
import Darwin
import Foundation

/// Recursive filesystem notifications for an explicitly selected vault, without a polling timer.
@MainActor
public final class KnowledgeFolderMonitor {
    private var stream: KnowledgeFolderEventStream?
    private var generation: UUID?
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var pendingNotification: Task<Void, Never>?

    public init() {}

    /// Start before capturing the initial baseline so edits made during capture trigger another pass.
    public func start(root: URL, onChange: @escaping @MainActor @Sendable () -> Void) throws {
        stop()
        var status = stat()
        guard root.isFileURL, lstat(root.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        let generation = UUID()
        self.generation = generation
        self.onChange = onChange
        let context = KnowledgeFolderEventContext { [weak self] in
            self?.changed(generation: generation)
        }
        do { stream = try KnowledgeFolderEventStream(root: root, context: context) }
        catch { stop(); throw error }
    }

    public func stop() {
        generation = nil
        pendingNotification?.cancel()
        pendingNotification = nil
        onChange = nil
        stream = nil
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

private final class KnowledgeFolderEventContext: Sendable {
    let changed: @MainActor @Sendable () -> Void

    init(changed: @escaping @MainActor @Sendable () -> Void) { self.changed = changed }
}

/// Owns the C stream outside actor isolation; invalidation precedes releasing its callback context.
private final class KnowledgeFolderEventStream: @unchecked Sendable {
    private let stream: FSEventStreamRef

    init(root: URL, context: KnowledgeFolderEventContext) throws {
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
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: root.path])
        }
        self.stream = stream
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
