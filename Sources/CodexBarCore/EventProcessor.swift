import Foundation

@MainActor
public final class EventProcessor {
    private let sourceWorker: CodexEventSourceWorker
    private let store: TaskStore

    public init(source: any CodexEventSource, store: TaskStore) {
        self.sourceWorker = CodexEventSourceWorker(source: source)
        self.store = store
    }

    @discardableResult
    public func processPending() async throws -> Int {
        let pendingEvents = try await sourceWorker.pendingEvents()
        guard !Task.isCancelled else {
            return 0
        }
        _ = try await store.apply(pendingEvents.map(\.event))
        // Once the state is durable, archive the whole source batch even if the
        // caller is cancelled. A failed archive remains safe to retry because
        // event IDs are persisted for deduplication.
        try await sourceWorker.markProcessed(pendingEvents)
        return pendingEvents.count
    }
}

private actor CodexEventSourceWorker {
    private let source: any CodexEventSource

    init(source: any CodexEventSource) {
        self.source = source
    }

    func pendingEvents() throws -> [PendingCodexEvent] {
        try source.pendingEvents()
    }

    func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws {
        try source.markProcessed(pendingEvents)
    }
}
