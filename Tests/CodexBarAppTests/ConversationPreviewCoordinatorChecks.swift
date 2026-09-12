import CodexBarCore
import Foundation

@main
@MainActor
struct ConversationPreviewCoordinatorCheck {
    static func main() async throws {
        try await rejectsFramesFromPreviousSelection()
        try await rejectsFramesFromInvalidatedWorker()
        try await ignoresHistoryAfterDismissal()
        try await retainsBodyOnDisconnect()
        try await preservesProtocolFailureUntilSupportedSnapshot()
        print("PASS preview selection/worker isolation, late history, retained body, incompatible protocol, timeout and recovery")
    }

    private static func rejectsFramesFromPreviousSelection() async throws {
        let store = ConversationPreviewStore()
        let monitor = PreviewMonitorFixture()
        let worker = SuspendedPreviewWorker()
        let coordinator = ConversationPreviewCoordinator(store: store, monitor: monitor, makeWorker: { _, _ in worker })
        coordinator.begin(sessionID: "a", cwd: "/tmp/a")
        let token = coordinator.generation
        let pending = Task { await coordinator.consume(Data(), sessionID: "a", generation: token) }
        try await waitUntil { await worker.isWaiting }
        coordinator.begin(sessionID: "b", cwd: "/tmp/b")
        await worker.resume(with: result(session: "a"))
        await pending.value
        precondition(store.preview == nil && store.state == .loading, "Old selection published into the new preview")
        coordinator.end()
    }

    private static func rejectsFramesFromInvalidatedWorker() async throws {
        let store = ConversationPreviewStore()
        let monitor = PreviewMonitorFixture()
        let worker = SuspendedPreviewWorker()
        var firstWorker = true
        let coordinator = ConversationPreviewCoordinator(store: store, monitor: monitor, makeWorker: { session, cwd in
            if firstWorker { firstWorker = false; return worker }
            return ConversationPreviewWorker(sessionID: session, cwd: cwd)
        })
        coordinator.begin(sessionID: "a", cwd: "/tmp/a")
        let token = coordinator.generation
        let pending = Task { await coordinator.consume(Data(), sessionID: "a", generation: token) }
        try await waitUntil { await worker.isWaiting }
        coordinator.invalidate(reason: .connectionUnavailable)
        await worker.resume(with: result(session: "a"))
        await pending.value
        precondition(store.preview == nil && store.state == .unavailable, "Invalidated worker restored obsolete content")
        coordinator.end()
    }

    private static func ignoresHistoryAfterDismissal() async throws {
        let store = ConversationPreviewStore()
        let monitor = PreviewMonitorFixture()
        let coordinator = ConversationPreviewCoordinator(store: store, monitor: monitor)
        coordinator.begin(sessionID: "a", cwd: "/tmp/a")
        coordinator.loadHistory()
        precondition(store.isLoadingHistory)
        let requests = monitor.snapshotRequests.count
        coordinator.end()
        monitor.historyCompletion?(42)
        precondition(store.preview == nil && store.state == .idle && !store.isLoadingHistory)
        precondition(monitor.snapshotRequests.count == requests, "Dismissed history callback requested another snapshot")
    }

    private static func retainsBodyOnDisconnect() async throws {
        let store = ConversationPreviewStore()
        let monitor = PreviewMonitorFixture()
        let coordinator = ConversationPreviewCoordinator(store: store, monitor: monitor)
        coordinator.begin(sessionID: "a", cwd: "/tmp/a")
        await coordinator.consume(try snapshot(session: "a"), sessionID: "a", generation: coordinator.generation)
        precondition(store.state == .ready && store.preview?.items.first?.text == "fixture body")
        coordinator.invalidate(reason: .connectionUnavailable)
        precondition(store.preview?.items.first?.text == "fixture body", "Disconnect discarded readable body")
        precondition(store.state == .unavailable && store.message?.contains("上次读取") == true)
        coordinator.end()
        precondition(store.preview == nil && store.latestRevision == nil, "Dismissal retained conversation data")
    }

    private static func preservesProtocolFailureUntilSupportedSnapshot() async throws {
        let store = ConversationPreviewStore()
        let monitor = PreviewMonitorFixture()
        monitor.reasons["a"] = .unsupportedProtocol(expected: 11, received: 12)
        let coordinator = ConversationPreviewCoordinator(store: store, monitor: monitor, snapshotTimeout: .milliseconds(20))
        coordinator.begin(sessionID: "a", cwd: "/tmp/a")
        precondition(store.state == .unavailable && store.message?.contains("不兼容") == true,
                     "Opening a previously incompatible session started an unexplained spinner")
        precondition(monitor.snapshotRequests.isEmpty, "Opening a known incompatible session retried automatically")
        let message = store.message
        coordinator.refresh()
        precondition(monitor.snapshotRequests.last?.retryIncompatible == true, "Explicit refresh cannot renegotiate")
        try await Task.sleep(for: .milliseconds(60))
        precondition(store.message == message, "Snapshot timeout hid a known protocol mismatch")
        coordinator.invalidate(reason: .connectionUnavailable)
        precondition(store.message == message, "Ordinary disconnect hid a known protocol mismatch")
        monitor.reasons.removeValue(forKey: "a")
        await coordinator.consume(try snapshot(session: "a"), sessionID: "a", generation: coordinator.generation)
        precondition(store.state == .ready && store.message == nil, "Supported snapshot failed to restore preview")
        coordinator.end()
    }

    private static func result(session: String) -> CodexConversationPreviewResult {
        CodexConversationPreviewResult(preview: CodexConversationPreview(sessionID: session, cwd: "/tmp/\(session)", items: [],
            historyComplete: true, revision: 1))
    }

    /// Synthetic v11 data; this check does not connect to an installed extension.
    private static func snapshot(session: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "broadcast", "method": "thread-stream-state-changed", "version": 11, "sourceClientId": "fixture-owner",
            "params": ["hostId": "local", "conversationId": session, "change": ["type": "snapshot", "revision": 1,
                "conversationState": ["id": session, "sessionId": session, "cwd": "/tmp/\(session)", "source": "vscode",
                    "resumeState": "resumed", "turnsPagination": ["hasLoadedOldest": true],
                    "turns": [["turnId": "fixture-turn", "items": [["id": "fixture-item", "type": "agentMessage", "text": "fixture body"]]]]]]
        ])
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let satisfied = await condition()
        precondition(satisfied, "Preview worker did not reach the bounded test barrier")
    }
}

@MainActor
private final class PreviewMonitorFixture: ConversationPreviewMonitoring {
    var reasons: [String: CodexRuntimeUnavailableReason] = [:]
    var snapshotRequests: [(sessionID: String, retryIncompatible: Bool)] = []
    var historyCompletion: (@MainActor @Sendable (Int?) -> Void)?

    func unavailableReason(for sessionID: String) -> CodexRuntimeUnavailableReason? { reasons[sessionID] }

    func requestSnapshot(sessionID: String, retryIncompatible: Bool) {
        snapshotRequests.append((sessionID, retryIncompatible))
    }

    func requestCompleteHistory(sessionID: String, completion: @escaping @MainActor @Sendable (Int?) -> Void) {
        historyCompletion = completion
    }
}

private actor SuspendedPreviewWorker: ConversationPreviewConsuming {
    private var continuation: CheckedContinuation<CodexConversationPreviewResult, Never>?
    var isWaiting: Bool { continuation != nil }

    func consume(_ data: Data) async -> CodexConversationPreviewResult {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(with result: CodexConversationPreviewResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
