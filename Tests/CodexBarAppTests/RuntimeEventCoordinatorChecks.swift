import CodexBarCore
import Foundation

@main
@MainActor
struct RuntimeEventCoordinatorChecks {
    static func main() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("CodexBarCoreTests/Fixtures/runtime-v11-synthetic.json")
        let frames = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [[String: Any]]
        let snapshot = try JSONSerialization.data(withJSONObject: frames[0])
        let patch = try JSONSerialization.data(withJSONObject: frames[1])
        try await preservesOrdering(snapshot: snapshot, patch: patch)
        try await preservesHookCompletion(snapshot: snapshot, patch: patch)
        try await cancelsOldWork(snapshot: snapshot, patch: patch)
        try await boundsBacklog(snapshot: snapshot)
        print("PASS runtime event ordering, Hook completion, reconcile coalescing, cancellation, restart, unavailable reset and queue budgets")
    }

    static func preservesHookCompletion(snapshot: Data, patch: Data) async throws {
        let store = TaskStore()
        func event(_ name: CodexHookEventName, timestamp: Date) -> CodexHookEvent {
            CodexHookEvent(
                id: "fixture-\(name.rawValue)", sessionID: "fixture-session", turnID: "fixture-turn",
                cwd: "/tmp/fixture-project", name: name, promptSummary: "Fixture task", toolName: nil,
                timestamp: timestamp, lastAssistantMessagePresent: name == .stop, source: .visualStudioCode
            )
        }
        _ = try await store.apply(event(.userPromptSubmit, timestamp: Date().addingTimeInterval(-30)))
        let coordinator = RuntimeEventCoordinator()
        var deliveries = 0
        coordinator.onUpdates = { updates, _ in
            for update in updates {
                do {
                    _ = try await store.applyRuntimeStatus(
                        sessionID: update.sessionID, turnID: update.turnID!, cwd: update.cwd!, status: update.status
                    )
                } catch { preconditionFailure("Runtime persistence failed: \(error)") }
            }
            deliveries += 1
        }
        coordinator.start()
        defer { coordinator.stop() }
        coordinator.enqueue(.frame(snapshot, nil))
        coordinator.enqueue(.frame(patch, nil))
        try await eventually { deliveries == 2 }
        precondition(store.tasks.first?.status == .running)
        _ = try await store.apply(event(.stop, timestamp: Date()))
        precondition(store.tasks.first?.status == .ready, "Hook completion was not accepted")
        _ = try await store.markRead(taskID: "fixture-session:fixture-turn")
        coordinator.enqueue(.reconcile)
        try await eventually { deliveries == 3 }
        precondition(store.tasks.first?.status == .ready, "Cached runtime revived a completed Hook task")
        precondition(store.tasks.first?.isUnread == false, "Cached runtime changed the completion read state")
    }

    static func preservesOrdering(snapshot: Data, patch: Data) async throws {
        let coordinator = RuntimeEventCoordinator()
        let gate = EventGate()
        var statuses: [CodexTaskStatus] = []
        var sources: [RuntimeStatusUpdateSource] = []
        var frames: [String?] = []
        coordinator.onUpdates = { updates, source in
            statuses += updates.map(\.status)
            sources.append(source)
        }
        coordinator.onFrame = { _, session, _ in
            frames.append(session)
            if frames.count == 1 { await gate.wait() }
        }
        coordinator.start()
        coordinator.enqueue(.frame(snapshot, nil))
        try await eventually { gate.isWaiting }
        precondition(statuses == [.needsAttention], "Status must publish before slower body consumers finish")
        coordinator.enqueue(.frame(patch, nil))
        coordinator.enqueue(.reconcile)
        coordinator.enqueue(.reconcile)
        gate.resume()
        try await eventually { statuses.count == 3 }
        precondition(statuses == [.needsAttention, .running, .running], "Patches or reconciliation overtook the snapshot")
        precondition(sources == [.liveFrame, .liveFrame, .reconcile], "Cached reconciliation must not trigger new-turn recovery")
        precondition(frames == ["fixture-session", "fixture-session"])
        var reset = false
        coordinator.onUnavailable = { reasons in reset = reasons["fixture-session"] == .connectionUnavailable }
        coordinator.enqueue(.unavailable(["fixture-session": .connectionUnavailable]))
        coordinator.enqueue(.reconcile)
        try await eventually { reset }
        try await Task.sleep(for: .milliseconds(20))
        precondition(statuses.count == 3, "Disconnected projection was reapplied")
        coordinator.stop()
    }

    static func cancelsOldWork(snapshot: Data, patch: Data) async throws {
        let coordinator = RuntimeEventCoordinator()
        let gate = EventGate()
        var statuses: [CodexTaskStatus] = []
        coordinator.onUpdates = { updates, _ in statuses += updates.map(\.status) }
        coordinator.onFrame = { _, _, _ in await gate.wait() }
        coordinator.start()
        coordinator.enqueue(.frame(snapshot, nil))
        try await eventually { gate.isWaiting }
        coordinator.enqueue(.frame(patch, nil))
        coordinator.stop()
        coordinator.enqueue(.frame(patch, nil))
        coordinator.start()
        coordinator.onFrame = nil
        coordinator.enqueue(.reconcile)
        gate.resume()
        try await Task.sleep(for: .milliseconds(20))
        precondition(statuses == [.needsAttention], "Stopped work or old state escaped into the restarted coordinator")
        coordinator.enqueue(.frame(snapshot, nil))
        try await eventually { statuses.count == 2 }
        coordinator.stop()
    }

    static func boundsBacklog(snapshot: Data) async throws {
        let byteBounded = RuntimeEventCoordinator(maximumPendingBytes: snapshot.count - 1)
        var overflows = 0
        byteBounded.onOverflow = { overflows += 1 }
        byteBounded.onFrame = { _, _, _ in preconditionFailure("Oversized frame was consumed") }
        byteBounded.start()
        byteBounded.enqueue(.frame(snapshot, nil))
        precondition(overflows == 1)
        byteBounded.stop()

        let coordinator = RuntimeEventCoordinator(maximumPendingEvents: 2)
        let gate = EventGate()
        coordinator.onFrame = { _, _, _ in await gate.wait() }
        coordinator.onOverflow = { overflows += 1 }
        coordinator.start()
        coordinator.enqueue(.frame(snapshot, nil))
        try await eventually { gate.isWaiting }
        for _ in 0..<3 { coordinator.enqueue(.unavailable([:])) }
        precondition(overflows == 2, "Non-frame events bypassed the queue budget")
        coordinator.onFrame = nil
        gate.resume()
        var statuses: [CodexTaskStatus] = []
        coordinator.onUpdates = { updates, _ in statuses += updates.map(\.status) }
        coordinator.enqueue(.reconcile)
        try await Task.sleep(for: .milliseconds(20))
        precondition(statuses.isEmpty, "Overflow retained stale projections")
        coordinator.enqueue(.frame(snapshot, nil))
        try await eventually { !statuses.isEmpty }
        coordinator.stop()
    }

    static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Runtime event check timed out")
    }
}

@MainActor
private final class EventGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
