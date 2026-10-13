import CoreServices
import Darwin
import Foundation

/// Notices newly published local session files without reading conversation contents or polling.
@MainActor
public final class CodexSessionCreationMonitor {
    private let codexHome: URL
    private var observation: SessionCreationObservation?
    private var generation: UUID?
    private var pendingNotification: Task<Void, Never>?
    private var pendingCandidates: Set<CodexSessionCandidate> = []
    private var acknowledgedSessions: Set<String> = []
    private var acknowledgmentOrder: [String] = []
    private var needsRecovery = false
    private var onChange: (@MainActor @Sendable (Set<CodexSessionCandidate>) -> Void)?

    public init(codexHome: URL? = nil) {
        self.codexHome = codexHome ?? URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["CODEX_HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
    }

    /// Start before initial task recovery so a session created during recovery gets another pass.
    /// An empty set signals lost filesystem events and requests one bounded metadata recovery.
    public func start(onChange: @escaping @MainActor @Sendable (Set<CodexSessionCandidate>) -> Void) async throws {
        stop()
        try Task.checkCancellation()
        let generation = UUID()
        self.generation = generation
        self.onChange = onChange
        let home = codexHome
        do {
            let observation = try await Task.detached(priority: .utility) { [weak self] in
                try SessionCreationObservation(home: home) { [weak self] candidates in
                    self?.changed(candidates, generation: generation)
                }
            }.value
            guard self.generation == generation, !Task.isCancelled else {
                observation.stop()
                throw CancellationError()
            }
            self.observation = observation
        } catch {
            if self.generation == generation { stop() }
            throw error
        }
    }

    public func stop() {
        generation = nil
        pendingNotification?.cancel()
        pendingNotification = nil
        pendingCandidates.removeAll()
        acknowledgedSessions.removeAll()
        acknowledgmentOrder.removeAll()
        needsRecovery = false
        onChange = nil
        observation?.stop()
        observation = nil
    }

    deinit { pendingNotification?.cancel() }

    /// Stops watching appends once metadata has been recovered or the session is irrelevant.
    public func acknowledge(sessionIDs: Set<String>) {
        for session in sessionIDs where acknowledgedSessions.insert(session).inserted {
            acknowledgmentOrder.append(session)
            if acknowledgmentOrder.count > 8_192 { acknowledgedSessions.remove(acknowledgmentOrder.removeFirst()) }
        }
        pendingCandidates = pendingCandidates.filter { !sessionIDs.contains($0.sessionID) }
        observation?.acknowledge(sessionIDs: sessionIDs)
    }

    private func changed(_ candidates: Set<CodexSessionCandidate>, generation: UUID) {
        guard self.generation == generation else { return }
        if candidates.isEmpty { needsRecovery = true }
        for candidate in candidates where pendingCandidates.count < 512 && !acknowledgedSessions.contains(candidate.sessionID) {
            pendingCandidates.insert(candidate)
        }
        guard pendingNotification == nil else { return }
        pendingNotification = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, self.generation == generation else { return }
            pendingNotification = nil
            let candidates = pendingCandidates
            let recover = needsRecovery
            pendingCandidates.removeAll()
            needsRecovery = false
            if recover { onChange?([]) }
            if !candidates.isEmpty { onChange?(candidates) }
        }
    }
}

/// FSEvents can repeat ItemCreated on later appends; deduplicate a bounded set of recent identities.
package struct CodexSessionCreationFilter {
    fileprivate struct Identity: Hashable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
    }

    private let prefix: String
    private let alternatePrefix: String
    private let startedAt: Date
    private var observed: Set<Identity> = []
    private var observationOrder: [Identity] = []

    package init(sessions: URL, startedAt: Date) {
        prefix = canonicalSessionPath(sessions).path + "/"
        alternatePrefix = sessions.standardizedFileURL.path + "/"
        self.startedAt = startedAt
    }

    package mutating func accepts(path: String, flags: UInt32) -> Bool {
        let publication = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed
                                 | kFSEventStreamEventFlagItemModified)
        guard flags & publication != 0, flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0,
              let identity = identity(path: path) else { return false }
        let birth = Date(timeIntervalSince1970: Double(identity.birthSeconds)
                         + Double(identity.birthNanoseconds) / 1_000_000_000)
        guard flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 || birth >= startedAt,
              observed.insert(identity).inserted else { return false }
        observationOrder.append(identity)
        // A very old identity can be rediscovered after eviction; AppModel still validates its session.
        if observationOrder.count > 8_192 { observed.remove(observationOrder.removeFirst()) }
        return true
    }

    fileprivate func identity(path: String) -> Identity? {
        let raw = URL(fileURLWithPath: path)
        // The watched ancestor may be the user's home; unrelated events must not perform filesystem I/O.
        guard raw.lastPathComponent.hasPrefix("rollout-"), raw.pathExtension == "jsonl",
              path.hasPrefix(prefix) || path.hasPrefix(alternatePrefix) else { return nil }
        let url = canonicalSessionPath(raw.deletingLastPathComponent()).appendingPathComponent(raw.lastPathComponent)
        guard url.path.hasPrefix(prefix), url.lastPathComponent.hasPrefix("rollout-"),
              url.pathExtension == "jsonl" else { return nil }
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        return Identity(device: status.st_dev, inode: status.st_ino,
                        birthSeconds: status.st_birthtimespec.tv_sec,
                        birthNanoseconds: status.st_birthtimespec.tv_nsec)
    }

    package func needsRecovery(path: String, flags: UInt32) -> Bool {
        let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                         | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        guard flags & lost != 0 else { return false }
        let path = canonicalSessionPath(URL(fileURLWithPath: path)).path + "/"
        return path.hasPrefix(prefix) || prefix.hasPrefix(path)
    }
}

/// Only newly observed files stay pending; their first turn may be written well after session_meta.
package struct CodexSessionCreationTracker {
    fileprivate var filter: CodexSessionCreationFilter
    private var pending: [CodexSessionCreationFilter.Identity: CodexSessionCandidate?] = [:]
    private var acknowledgedSessions: Set<String> = []
    private var acknowledgmentOrder: [String] = []
    private let reader = CodexSessionCandidateReader()

    package init(sessions: URL, startedAt: Date) {
        filter = CodexSessionCreationFilter(sessions: sessions, startedAt: startedAt)
    }

    package mutating func receive(path: String, flags: UInt32) -> CodexSessionCandidate? {
        guard let identity = filter.identity(path: path) else { return nil }
        if pending[identity] == nil {
            guard pending.count < 512, filter.accepts(path: path, flags: flags) else { return nil }
            pending[identity] = .some(nil)
        }
        if let candidate = pending[identity] ?? nil { return candidate }
        let raw = URL(fileURLWithPath: path)
        let file = canonicalSessionPath(raw.deletingLastPathComponent()).appendingPathComponent(raw.lastPathComponent)
        switch reader.read(at: file) {
        case .pending: return nil
        case .ignored:
            pending.removeValue(forKey: identity)
            return nil
        case .candidate(let candidate):
            guard !acknowledgedSessions.contains(candidate.sessionID) else {
                pending.removeValue(forKey: identity)
                return nil
            }
            pending[identity] = candidate
            return candidate
        }
    }

    package mutating func acknowledge(sessionIDs: Set<String>) {
        for session in sessionIDs where acknowledgedSessions.insert(session).inserted {
            acknowledgmentOrder.append(session)
            if acknowledgmentOrder.count > 8_192 { acknowledgedSessions.remove(acknowledgmentOrder.removeFirst()) }
        }
        pending = pending.filter { _, candidate in candidate.map { !sessionIDs.contains($0.sessionID) } ?? true }
    }
}

/// Resolve the existing ancestor first: Foundation cannot canonicalize an entirely missing suffix.
private func canonicalSessionPath(_ url: URL) -> URL {
    var root = url.standardizedFileURL
    var suffix: [String] = []
    while !FileManager.default.fileExists(atPath: root.path) {
        let parent = root.deletingLastPathComponent()
        guard parent != root else { break }
        suffix.append(root.lastPathComponent)
        root = parent
    }
    if let resolved = realpath(root.path, nil) {
        root = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
    }
    return suffix.reversed().reduce(root) { $0.appendingPathComponent($1) }
}

/// Stream creation and disposal stay off the UI actor; callback state belongs to the serial queue.
private final class SessionCreationObservation: @unchecked Sendable {
    private let queue: DispatchQueue
    private let state: State

    init(home: URL, changed: @escaping @MainActor @Sendable (Set<CodexSessionCandidate>) -> Void) throws {
        guard home.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let home = canonicalSessionPath(home)
        let sessions = home.appendingPathComponent("sessions")
        // Watching an existing ancestor also catches a missing home, new dates, and root recreation.
        var root = home.deletingLastPathComponent()
        var status = stat()
        while lstat(root.path, &status) != 0 || status.st_mode & S_IFMT != S_IFDIR {
            let parent = root.deletingLastPathComponent()
            guard parent != root else { throw CocoaError(.fileReadNoSuchFile) }
            root = parent
        }
        let queue = DispatchQueue(label: "com.codexbar.session-creation", qos: .utility)
        let context = Context(tracker: CodexSessionCreationTracker(sessions: sessions, startedAt: Date()), changed: changed)
        var streamContext = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Context>.fromOpaque(info).retain()
                return info
            }, release: { info in
                guard let info else { return }
                Unmanaged<Context>.fromOpaque(info).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                                            | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self)
            var candidates: Set<CodexSessionCandidate> = []
            var needsRecovery = false
            for index in 0..<min(count, paths.count) {
                guard let path = paths[index] as? String else { continue }
                if context.tracker.filter.needsRecovery(path: path, flags: flags[index]) { needsRecovery = true }
                if let candidate = context.tracker.receive(path: path, flags: flags[index]) { candidates.insert(candidate) }
            }
            let recovery = needsRecovery
            let discovered = candidates
            if recovery || !discovered.isEmpty {
                Task { @MainActor in
                    if recovery { context.changed([]) }
                    if !discovered.isEmpty { context.changed(discovered) }
                }
            }
        }, &streamContext, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else {
            throw CocoaError(.fileReadUnknown)
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw CocoaError(.fileReadUnknown)
        }
        self.queue = queue
        state = State(stream: stream, context: context)
    }

    func stop() { queue.async { [state] in state.stop() } }

    func acknowledge(sessionIDs: Set<String>) {
        queue.async { [state] in state.context.tracker.acknowledge(sessionIDs: sessionIDs) }
    }

    deinit { queue.async { [state] in state.stop() } }

    private final class Context: @unchecked Sendable {
        var tracker: CodexSessionCreationTracker
        let changed: @MainActor @Sendable (Set<CodexSessionCandidate>) -> Void
        init(tracker: CodexSessionCreationTracker, changed: @escaping @MainActor @Sendable (Set<CodexSessionCandidate>) -> Void) {
            self.tracker = tracker
            self.changed = changed
        }
    }

    private final class State: @unchecked Sendable {
        private var stream: FSEventStreamRef?
        let context: Context
        init(stream: FSEventStreamRef, context: Context) { self.stream = stream; self.context = context }
        func stop() {
            guard let stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
