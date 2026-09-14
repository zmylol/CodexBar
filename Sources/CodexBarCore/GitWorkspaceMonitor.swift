import Darwin
import Foundation

/// Reads visible workspaces off the main actor and follows HEAD and branch-history changes.
@MainActor
public final class GitWorkspaceMonitor {
    private let worker = GitWorkspaceIdentityWorker()
    private var cwds: Set<String> = []
    private var labels: [String: GitWorkspaceLabel] = [:]
    private var onChange: (@MainActor @Sendable ([String: GitWorkspaceLabel]) -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var refreshID = UUID()
    private var eventTask: Task<Void, Never>?
    private var watches: [String: GitMetadataWatch] = [:]

    public init() {}

    public func start(
        cwds: Set<String>,
        onChange: @escaping @MainActor @Sendable ([String: GitWorkspaceLabel]) -> Void
    ) {
        stop()
        self.cwds = cwds
        self.onChange = onChange
        refresh()
    }

    public func stop() {
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        eventTask?.cancel()
        eventTask = nil
        watches.removeAll()
        cwds.removeAll()
        labels.removeAll()
        onChange = nil
    }

    public func setCWDs(_ cwds: Set<String>) {
        guard self.cwds != cwds else { return }
        self.cwds = cwds
        refresh()
    }

    public func refresh() {
        guard onChange != nil else { return }
        refreshTask?.cancel()
        let id = UUID()
        refreshID = id
        let directories = cwds
        refreshTask = Task { [weak self, worker] in
            let identities = await worker.read(directories)
            guard let self, !Task.isCancelled, refreshID == id else { return }
            updateWatches(identities.values.flatMap { [$0.headPath] + $0.metadataWatchPaths })
            let updated = GitWorkspaceIdentityReader.labels(identities: identities)
            if updated != labels {
                labels = updated
                onChange?(updated)
            }
            refreshTask = nil
        }
    }

    private func metadataChanged() {
        guard onChange != nil, eventTask == nil else { return }
        eventTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self else { return }
            eventTask = nil
            refresh()
        }
    }

    private func updateWatches(_ metadataPaths: [String]) {
        var paths = Set<String>()
        for path in metadataPaths {
            if FileManager.default.fileExists(atPath: path) { paths.insert(path) }
            // Watch the nearest existing parent too: Git creates and atomically replaces refs/logs.
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            for _ in 0..<128 {
                if FileManager.default.fileExists(atPath: parent.path) {
                    paths.insert(parent.path)
                    break
                }
                let next = parent.deletingLastPathComponent()
                guard next.path != parent.path else { break }
                parent = next
            }
        }
        for path in watches.keys where !paths.contains(path) { watches.removeValue(forKey: path) }
        for path in paths {
            let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { watches.removeValue(forKey: path); continue }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { close(descriptor); continue }
            if let watch = watches[path], watch.device == status.st_dev, watch.inode == status.st_ino {
                close(descriptor)
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .revoke], queue: .main
            )
            let watch = GitMetadataWatch(source: source, device: status.st_dev, inode: status.st_ino)
            let id = watch.id
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, watches[path]?.id == id else { return }
                    metadataChanged()
                }
            }
            source.setCancelHandler { close(descriptor) }
            watches[path] = watch
            source.activate()
        }
    }
}

private actor GitWorkspaceIdentityWorker {
    func read(_ cwds: Set<String>) -> [String: GitWorkspaceIdentity] {
        var identities: [String: GitWorkspaceIdentity] = [:]
        for cwd in cwds {
            guard !Task.isCancelled else { return [:] }
            identities[cwd] = GitWorkspaceIdentityReader.read(cwd: cwd)
        }
        return identities
    }
}

private final class GitMetadataWatch: @unchecked Sendable {
    let id = UUID()
    let source: any DispatchSourceFileSystemObject
    let device: dev_t
    let inode: ino_t

    init(source: any DispatchSourceFileSystemObject, device: dev_t, inode: ino_t) {
        self.source = source
        self.device = device
        self.inode = inode
    }

    deinit { source.cancel() }
}
