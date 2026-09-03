import Foundation

public struct PendingCodexEvent: Equatable, Sendable {
    public let event: CodexHookEvent
    public let sourceURL: URL

    public init(event: CodexHookEvent, sourceURL: URL) {
        self.event = event
        self.sourceURL = sourceURL
    }
}

public protocol CodexEventSource: Sendable {
    func pendingEvents() throws -> [PendingCodexEvent]
    func markProcessed(_ pendingEvent: PendingCodexEvent) throws
    func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws
}

public extension CodexEventSource {
    func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws {
        for pendingEvent in pendingEvents {
            try markProcessed(pendingEvent)
        }
    }
}

public struct CodexHookEventSource: CodexEventSource, @unchecked Sendable {
    private static let maximumEventBytes = 4 * 1_024 * 1_024
    private static let maximumEventsPerPoll = 25
    private static let archiveRetentionSweepInterval: TimeInterval = 60 * 60
    private let paths: CodexBarPaths
    private let fileManager: FileManager
    private let archiveRetentionSchedule = ArchiveRetentionSchedule()

    public init(paths: CodexBarPaths = CodexBarPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
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

        let urls = try fileManager.contentsOfDirectory(
            at: paths.inbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let candidates = urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(Self.maximumEventsPerPoll)

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
                pendingEvents.append(PendingCodexEvent(event: event, sourceURL: url))
            } catch {
                let destination = uniqueDestinationURL(
                    for: url.lastPathComponent,
                    in: paths.failed
                )
                try fileManager.moveItem(
                    at: url,
                    to: destination
                )
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
        return pendingEvents
    }

    public func markProcessed(_ pendingEvent: PendingCodexEvent) throws {
        try markProcessed([pendingEvent])
    }

    public func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws {
        guard !pendingEvents.isEmpty else {
            return
        }
        try paths.prepareEventDirectories(fileManager: fileManager)
        var destinations: Set<URL> = []
        for pendingEvent in pendingEvents {
            let destination = uniqueDestinationURL(
                for: pendingEvent.sourceURL.lastPathComponent,
                in: paths.processed
            )
            try fileManager.moveItem(at: pendingEvent.sourceURL, to: destination)
            destinations.insert(destination)
        }
        try paths.enforceArchiveRetention(
            in: paths.processed,
            preserving: destinations,
            fileManager: fileManager
        )
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
