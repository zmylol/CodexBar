import Darwin
import Foundation

/// Observes atomic event publication in Inbox and Activity without an idle timer.
@MainActor
public final class CodexInboxMonitor {
    private enum Directory: CaseIterable {
        case parent, root, inbox, activity

        var containsEvents: Bool { self == .inbox || self == .activity }
    }

    private let paths: CodexBarPaths
    private var watches: [Directory: DirectoryWatch] = [:]
    private var generation: UUID?
    private var onChange: (@MainActor @Sendable () -> Void)?
    private var pendingNotification: Task<Void, Never>?

    public init(paths: CodexBarPaths) {
        self.paths = paths
    }

    /// Start before the initial Inbox processing pass to avoid a startup race.
    public func start(onChange: @escaping @MainActor @Sendable () -> Void) throws {
        stop()
        try paths.prepareEventDirectories()
        generation = UUID()
        self.onChange = onChange
        _ = refreshWatches()
        guard watches.count == Directory.allCases.count else {
            stop()
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: paths.rootDirectory.path])
        }
    }

    public func stop() {
        generation = nil
        pendingNotification?.cancel()
        pendingNotification = nil
        onChange = nil
        watches.removeAll()
    }

    deinit {
        pendingNotification?.cancel()
    }

    private func directoryChanged(_ directory: Directory, watchID: UUID, generation: UUID) {
        guard self.generation == generation, watches[directory]?.id == watchID else { return }
        let replacedDirectory = refreshWatches()
        guard directory.containsEvents || replacedDirectory else { return }
        // Coalesce a publication burst once, without delaying a continuous stream forever.
        guard pendingNotification == nil else { return }
        pendingNotification = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard let self, self.generation == generation else { return }
            self.pendingNotification = nil
            self.onChange?()
        }
    }

    /// Ancestor events let us reattach after an event directory or the root is replaced.
    private func refreshWatches() -> Bool {
        let parent = paths.rootDirectory.deletingLastPathComponent()
        var replacedDirectory = install(
            .parent,
            descriptor: open(parent.path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY)
        )
        let rootDescriptor = openChild(paths.rootDirectory.lastPathComponent, of: .parent)
        replacedDirectory = install(.root, descriptor: rootDescriptor) || replacedDirectory
        for (directory, name) in [(Directory.inbox, "Inbox"), (.activity, "Activity")] {
            replacedDirectory = install(directory, descriptor: openChild(name, of: .root)) || replacedDirectory
        }
        return replacedDirectory
    }

    private func openChild(_ name: String, of parent: Directory) -> Int32 {
        guard let parentWatch = watches[parent] else { return -1 }
        // Open relative to the validated parent, so a replaced root cannot redirect us.
        return openat(parentWatch.descriptor, name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY)
    }

    private func install(_ directory: Directory, descriptor: Int32) -> Bool {
        guard descriptor >= 0 else {
            return watches.removeValue(forKey: directory) != nil
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            close(descriptor)
            return watches.removeValue(forKey: directory) != nil
        }
        if let existing = watches[directory],
           existing.device == status.st_dev, existing.inode == status.st_ino {
            close(descriptor)
            return false
        }
        guard let generation else {
            close(descriptor)
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        let watch = DirectoryWatch(source: source, descriptor: descriptor, status: status)
        let watchID = watch.id
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.directoryChanged(directory, watchID: watchID, generation: generation)
            }
        }
        source.setCancelHandler { close(descriptor) }
        watches[directory] = watch
        source.activate()
        return true
    }
}

/// The descriptor stays open until Dispatch has finished using the cancelled source.
private final class DirectoryWatch: @unchecked Sendable {
    let id = UUID()
    let source: any DispatchSourceFileSystemObject
    let descriptor: Int32
    let device: dev_t
    let inode: ino_t

    init(source: any DispatchSourceFileSystemObject, descriptor: Int32, status: stat) {
        self.source = source
        self.descriptor = descriptor
        self.device = status.st_dev
        self.inode = status.st_ino
    }

    deinit {
        source.cancel()
    }
}
