import Foundation

@MainActor
public final class EventProcessor {
    private let sourceWorker: CodexEventSourceWorker
    private let store: TaskStore
    private let activityStore: LiveTaskActivityStore

    public init(
        source: any CodexEventSource,
        store: TaskStore,
        activityStore: LiveTaskActivityStore = LiveTaskActivityStore()
    ) {
        self.sourceWorker = CodexEventSourceWorker(source: source)
        self.store = store
        self.activityStore = activityStore
    }

    @discardableResult
    public func processPending() async throws -> Int {
        let pendingEvents = try await sourceWorker.pendingEvents()
        guard !Task.isCancelled else {
            return 0
        }
        let initialTasks = store.tasks
        let lifecycleEvents = pendingEvents.filter { $0.event.name != .preToolUse }
        let lifecycleResult: TaskStoreEventBatchResult
        if !lifecycleEvents.isEmpty {
            lifecycleResult = try await store.applyForEventProcessing(
                lifecycleEvents.map(\.event)
            )
        } else {
            lifecycleResult = .empty
        }
        activityStore.applyBatch(
            pendingEvents,
            initialTasks: initialTasks,
            appliedLifecycleEvents: lifecycleResult.appliedEvents,
            finalTasks: store.tasks
        )
        // Once the state is durable, archive the whole source batch even if the
        // caller is cancelled. Durable event IDs and the bounded in-memory
        // activity delivery IDs make a failed archive or deletion safe to retry.
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
