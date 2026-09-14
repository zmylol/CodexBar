import Foundation

public struct PendingCodexEvent: Equatable, Sendable {
    public let event: CodexHookEvent
    public let sourceURL: URL
    public let normalizedCWD: String?

    public init(
        event: CodexHookEvent,
        sourceURL: URL,
        normalizedCWD: String? = nil
    ) {
        self.event = event
        self.sourceURL = sourceURL
        self.normalizedCWD = normalizedCWD
    }
}

public protocol CodexEventSource: Sendable {
    func pendingEvents() throws -> [PendingCodexEvent]
    func markProcessed(_ pendingEvent: PendingCodexEvent) throws
    func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws
    func inboxHealth() throws -> CodexInboxHealth
}

public extension CodexEventSource {
    func inboxHealth() throws -> CodexInboxHealth {
        CodexInboxHealth(pendingCount: 0, discardedCount: 0)
    }

    func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws {
        for pendingEvent in pendingEvents {
            try markProcessed(pendingEvent)
        }
    }
}

public struct CodexHookEventSource: CodexEventSource, @unchecked Sendable {
    private static let maximumEventBytes = 4 * 1_024 * 1_024
    private static let maximumEventsPerPoll = 25
    private static let maximumActivityEventsPerPoll = 12
    private static let staleTemporaryFileAge: TimeInterval = 5 * 60
    private static let archiveRetentionSweepInterval: TimeInterval = 60 * 60
    private let paths: CodexBarPaths
    private let fileManager: FileManager
    private let retentionPolicy: CodexInboxRetentionPolicy
    private let inboxSnapshot = InboxSnapshot()
    private let archiveRetentionSchedule = ArchiveRetentionSchedule()

    public init(paths: CodexBarPaths = CodexBarPaths(), fileManager: FileManager = .default) {
        self.init(paths: paths, fileManager: fileManager, retentionPolicy: .standard)
    }

    package init(
        paths: CodexBarPaths,
        fileManager: FileManager = .default,
        retentionPolicy: CodexInboxRetentionPolicy
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.retentionPolicy = retentionPolicy
    }

    public func inboxHealth() throws -> CodexInboxHealth {
        let retention = CodexInboxRetention(paths: paths, fileManager: fileManager, policy: retentionPolicy)
        let discardedCount = try retention.withLock { try retention.discardedCount() }
        return CodexInboxHealth(pendingCount: inboxSnapshot.urls.count, discardedCount: discardedCount)
    }

    public func pendingEvents() throws -> [PendingCodexEvent] {
        try paths.prepareEventDirectories(fileManager: fileManager)
        let sweepDate = Date()
        if archiveRetentionSchedule.claimSweep(
            at: sweepDate,
            interval: Self.archiveRetentionSweepInterval
        ) {
            try paths.prepareProbeDirectory(fileManager: fileManager)
            try paths.enforceArchiveRetention(
                in: paths.processed,
                fileManager: fileManager,
                now: sweepDate
            )
            try paths.enforceArchiveRetention(
                in: paths.failed,
                fileManager: fileManager,
                now: sweepDate
            )
            try paths.enforceArchiveRetention(
                in: paths.probe,
                fileManager: fileManager,
                now: sweepDate
            )
        }

        // Drain one sorted lifecycle snapshot before rescanning. Fresh activity must
        // wait for a fresh Inbox snapshot so it cannot overtake an unscanned prompt.
        let cachedLifecycleEvents = inboxSnapshot.urls
        let queuedActivityEvents: [URL]
        let queuedLifecycleEvents: [URL]
        if cachedLifecycleEvents.isEmpty {
            queuedActivityEvents = try candidateURLs(in: paths.activity)
            let candidates = try candidateURLs(in: paths.inbox)
            let retention = CodexInboxRetention(paths: paths, fileManager: fileManager, policy: retentionPolicy)
            queuedLifecycleEvents = try retention.withLock { try retention.retain(candidates) }
            inboxSnapshot.replace(with: queuedLifecycleEvents, activity: queuedActivityEvents)
        } else {
            queuedActivityEvents = inboxSnapshot.activityURLs
            queuedLifecycleEvents = cachedLifecycleEvents
        }
        let lifecycleCandidates = Array(
            queuedLifecycleEvents.prefix(Self.maximumEventsPerPoll)
        )
        let activityCandidates = queuedLifecycleEvents.count > Self.maximumEventsPerPoll
            ? []
            : Array(queuedActivityEvents.prefix(Self.maximumActivityEventsPerPoll))
        let transientActivityCandidates = Set(activityCandidates)
        let candidates = (lifecycleCandidates + activityCandidates)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var pendingEvents: [PendingCodexEvent] = []
        var quarantinedURLs: Set<URL> = []
        for url in candidates {
            do {
                let resourceValues = try url.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey]
                )
                guard resourceValues.isRegularFile == true,
                      (resourceValues.fileSize ?? 0) <= Self.maximumEventBytes
                else {
                    throw CocoaError(.fileReadTooLarge)
                }
                let event = try JSONDecoder.codexBar.decode(
                    CodexHookEvent.self,
                    from: Data(contentsOf: url)
                )
                pendingEvents.append(PendingCodexEvent(
                    event: event,
                    sourceURL: url,
                    normalizedCWD: event.cwd.flatMap(PathNormalizer.normalize)
                ))
            } catch let error as CodexHookEventCodingError {
                switch error {
                case .unsupportedOrMissingSource, .inconsistentTransientPayload:
                    break
                }
                do {
                    try fileManager.removeItem(at: url)
                    inboxSnapshot.remove(url)
                } catch {
                    if isMissingFileError(error) {
                        inboxSnapshot.remove(url)
                        continue
                    }
                    throw error
                }
            } catch {
                if isMissingFileError(error) || !fileManager.fileExists(atPath: url.path) {
                    inboxSnapshot.remove(url)
                    continue
                }
                if transientActivityCandidates.contains(url) {
                    do {
                        try fileManager.removeItem(at: url)
                        inboxSnapshot.remove(url)
                    } catch {
                        if isMissingFileError(error) {
                            continue
                        }
                        throw error
                    }
                    continue
                }
                let destination = uniqueDestinationURL(
                    for: url.lastPathComponent,
                    in: paths.failed
                )
                do {
                    try fileManager.moveItem(at: url, to: destination)
                    inboxSnapshot.remove(url)
                } catch {
                    if isMissingFileError(error) {
                        inboxSnapshot.remove(url)
                        continue
                    }
                    throw error
                }
                quarantinedURLs.insert(destination)
            }
        }
        if !quarantinedURLs.isEmpty {
            try paths.enforceArchiveRetention(
                in: paths.failed,
                preserving: quarantinedURLs,
                fileManager: fileManager
            )
        }
        // An evicted cache can be empty while newly published events still await a scan.
        if pendingEvents.isEmpty, !inboxSnapshot.urls.isEmpty || !cachedLifecycleEvents.isEmpty {
            return try self.pendingEvents()
        }
        return pendingEvents
    }

    private func candidateURLs(in directory: URL) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        )
        let staleBefore = Date().addingTimeInterval(-Self.staleTemporaryFileAge)
        for url in urls where isManagedTemporaryFile(url) {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt <= staleBefore
            else {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
        return urls
            .filter {
                !$0.lastPathComponent.hasPrefix(".")
                    && $0.pathExtension.lowercased() == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isManagedTemporaryFile(_ url: URL) -> Bool {
        let filename = url.lastPathComponent
        guard filename.hasPrefix("."), filename.hasSuffix(".tmp") else {
            return false
        }
        var stem = filename.dropFirst().dropLast(4)
        if stem.hasSuffix(".plan") {
            stem = stem.dropLast(5)
        }
        guard let separator = stem.lastIndex(of: "_") else {
            return false
        }
        let timestamp = stem[..<separator]
        let identifier = stem[stem.index(after: separator)...]
        return (timestamp.count == 24 || timestamp.count == 27)
            && timestamp.hasSuffix("Z")
            && UUID(uuidString: String(identifier)) != nil
    }

    public func markProcessed(_ pendingEvent: PendingCodexEvent) throws {
        try markProcessed([pendingEvent])
    }

    public func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws {
        guard !pendingEvents.isEmpty else {
            return
        }
        try paths.prepareEventDirectories(fileManager: fileManager)
        let retention = CodexInboxRetention(paths: paths, fileManager: fileManager, policy: retentionPolicy)
        try retention.withLock { try archiveProcessed(pendingEvents) }
    }

    private func archiveProcessed(_ pendingEvents: [PendingCodexEvent]) throws {
        var destinations: Set<URL> = []
        for pendingEvent in pendingEvents {
            if pendingEvent.event.name == .preToolUse || pendingEvent.event.name == .postToolUse {
                do {
                    try fileManager.removeItem(at: pendingEvent.sourceURL)
                } catch {
                    if !isMissingFileError(error) {
                        throw error
                    }
                }
                inboxSnapshot.remove(pendingEvent.sourceURL)
                continue
            }
            let destination = uniqueDestinationURL(
                for: pendingEvent.sourceURL.lastPathComponent,
                in: paths.processed
            )
            do {
                if pendingEvent.event.toolExecution != nil {
                    try archiveWithoutExecutionMetadata(pendingEvent, to: destination)
                } else {
                    try fileManager.moveItem(at: pendingEvent.sourceURL, to: destination)
                }
            } catch {
                if isMissingFileError(error) {
                    inboxSnapshot.remove(pendingEvent.sourceURL)
                    continue
                }
                throw error
            }
            inboxSnapshot.remove(pendingEvent.sourceURL)
            destinations.insert(destination)
        }
        guard !destinations.isEmpty else {
            return
        }
        try paths.enforceArchiveRetention(
            in: paths.processed,
            preserving: destinations,
            fileManager: fileManager
        )
    }

    private func archiveWithoutExecutionMetadata(
        _ pendingEvent: PendingCodexEvent,
        to destination: URL
    ) throws {
        let event = pendingEvent.event
        let archiveEvent = CodexHookEvent(
            id: event.id,
            sessionID: event.sessionID,
            turnID: event.turnID,
            cwd: event.cwd,
            name: event.name,
            promptSummary: event.promptSummary,
            toolName: event.toolName,
            timestamp: event.timestamp,
            lastAssistantMessagePresent: event.lastAssistantMessagePresent,
            source: event.source
        )
        let data = try JSONEncoder.codexBar.encode(archiveEvent)
        let temporaryURL = paths.processed.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: temporaryURL])
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        // Keep the original correlation data available until its redacted archive is written.
        try fileManager.removeItem(at: pendingEvent.sourceURL)
    }

    private func uniqueDestinationURL(for filename: String, in directory: URL) -> URL {
        let preferred = directory.appendingPathComponent(filename)
        guard fileManager.fileExists(atPath: preferred.path) else {
            return preferred
        }

        let source = URL(fileURLWithPath: filename)
        let stem = source.deletingPathExtension().lastPathComponent
        let suffix = source.pathExtension
        while true {
            let candidateName = "\(stem)_\(UUID().uuidString.lowercased()).\(suffix)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
    }

    private func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == 2)
    }
}

private final class InboxSnapshot {
    private let lock = NSLock()
    private var storedURLs: [URL] = []
    private var storedActivityURLs: [URL] = []

    var urls: [URL] { lock.withLock { storedURLs } }
    var activityURLs: [URL] { lock.withLock { storedActivityURLs } }

    func replace(with urls: [URL], activity: [URL]) {
        lock.withLock {
            storedURLs = urls
            storedActivityURLs = activity
        }
    }

    func remove(_ url: URL) {
        lock.withLock {
            storedURLs.removeAll { $0 == url }
            storedActivityURLs.removeAll { $0 == url }
        }
    }
}

private final class ArchiveRetentionSchedule {
    private let lock = NSLock()
    private var nextSweepDate = Date.distantPast

    func claimSweep(at date: Date, interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard date >= nextSweepDate else {
            return false
        }
        nextSweepDate = date.addingTimeInterval(interval)
        return true
    }
}
