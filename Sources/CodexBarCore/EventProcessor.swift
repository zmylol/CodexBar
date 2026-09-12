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
        let lifecycleResult = try await store.applyForEventProcessing(pendingEvents.map(\.event))
        activityStore.applyBatch(
            pendingEvents,
            initialTasks: initialTasks,
            appliedLifecycleEvents: lifecycleResult.appliedEvents,
            finalTasks: store.tasks
        )
        // Durable event IDs and bounded in-memory activity delivery IDs make
        // archiving safe to retry, including after a cancelled lock wait.
        try await sourceWorker.markProcessed(pendingEvents)
        return pendingEvents.count
    }

    public func inboxHealth() async throws -> CodexInboxHealth {
        try await sourceWorker.inboxHealth()
    }
}

private actor CodexEventSourceWorker {
    private let source: any CodexEventSource

    init(source: any CodexEventSource) {
        self.source = source
    }

    func pendingEvents() async throws -> [PendingCodexEvent] {
        try await retryLockContention { try source.pendingEvents() }
    }

    func markProcessed(_ pendingEvents: [PendingCodexEvent]) async throws {
        try await retryLockContention { try source.markProcessed(pendingEvents) }
    }

    func inboxHealth() async throws -> CodexInboxHealth {
        try await retryLockContention { try source.inboxHealth() }
    }

    private func retryLockContention<Result>(_ operation: () throws -> Result) async throws -> Result {
        let delays: [Duration] = [.milliseconds(50), .milliseconds(150), .milliseconds(300)]
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try operation()
            } catch CodexInboxRetentionError.lockBusy {
                try Task.checkCancellation()
                guard attempt < delays.count else { throw CodexInboxRetentionError.lockBusy }
                try await Task.sleep(for: delays[attempt])
                attempt += 1
            }
        }
    }
}
