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
        try await cancelsOldWork(snapshot: snapshot, patch: patch)
        try await boundsBacklog(snapshot: snapshot)
        print("PASS runtime event ordering, reconcile coalescing, cancellation, restart, unavailable reset and queue budgets")
    }

    static func preservesOrdering(snapshot: Data, patch: Data) async throws {
        let coordinator = RuntimeEventCoordinator()
        let gate = EventGate()
        var statuses: [CodexTaskStatus] = []
        var frames: [String?] = []
        coordinator.onUpdates = { statuses += $0.map(\.status) }
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
        coordinator.onUpdates = { statuses += $0.map(\.status) }
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
        coordinator.onUpdates = { statuses += $0.map(\.status) }
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
