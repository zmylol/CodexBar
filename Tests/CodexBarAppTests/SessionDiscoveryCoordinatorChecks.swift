import CodexBarCore
import Foundation

@main
@MainActor
struct SessionDiscoveryCoordinatorChecks {
    static let cwd = "/synthetic/project"
    static let windows = [VSCodeWindowDescriptor(
        id: 1, title: "project", workspaceFolderPaths: [cwd], workspace: .folder(cwd)
    )]

    static func main() async throws {
        try await discoversNewSessionInUnchangedWindow()
        try await discoversFirstTurnAfterInitialRetries()
        try await coalescesAndBoundsRecovery()
        try await creationDuringRecoveryIsNotLost()
        try await stopAndRestartIsolatePendingWork()
        print("PASS session discovery without Hooks, indexing delay, coalescing, bounded retries and cancellation")
    }

    static func discoversNewSessionInUnchangedWindow() async throws {
        let store = TaskStore()
        let reconciler = StartupTaskReconciler(store: store)
        let old = snapshot("old-session", status: .completed, time: 100)
        let new = snapshot("new-session", status: .inProgress, time: 200)
        _ = try await reconciler.reconcile(snapshots: [old], windows: windows)
        var attempts = 0
        var subscriptions: Set<String> = []
        let coordinator = SessionDiscoveryCoordinator(delays: [.milliseconds(1), .milliseconds(5)]) {
            attempts += 1
            // A new rollout can arrive before app-server indexes its first turn.
            _ = try! await reconciler.reconcile(snapshots: attempts == 1 ? [old] : [old, new], windows: windows)
            subscriptions = Set(store.tasks.map(\.sessionID))
        }
        coordinator.start()
        defer { coordinator.stop() }
        coordinator.request()
        try await eventually { store.tasks.first?.sessionID == "new-session" }
        try check(store.tasks.count == 1 && store.tasks[0].status == .running,
                  "Same directory retained the completed session")
        try check(subscriptions == ["new-session"], "Runtime subscription did not follow discovery")
        _ = try await store.applyRuntimeStatus(sessionID: "new-session", turnID: "turn", cwd: cwd, status: .needsAttention)
        try check(store.tasks[0].status == .needsAttention, "New session could not reflect a pending question")
        _ = try await store.applyRuntimeStatus(sessionID: "new-session", turnID: "turn", cwd: cwd, status: .ready)
        try check(store.tasks[0].status == .ready, "New session could not complete")
    }

    static func coalescesAndBoundsRecovery() async throws {
        var calls = 0
        let coordinator = SessionDiscoveryCoordinator(delays: [.milliseconds(5), .milliseconds(5)]) { calls += 1 }
        coordinator.request()
        coordinator.start()
        for _ in 0..<100 { coordinator.request() }
        try await eventually { calls == 2 }
        try await Task.sleep(for: .milliseconds(35))
        try check(calls == 2, "No new creation event should mean no more recovery")
        coordinator.stop()
        coordinator.request()
        try await Task.sleep(for: .milliseconds(15))
        try check(calls == 2, "Stopped coordinator handled a new signal")
    }

    static func discoversFirstTurnAfterInitialRetries() async throws {
        let store = TaskStore()
        let reconciler = StartupTaskReconciler(store: store)
        let old = snapshot("old-session", status: .completed, time: 100)
        let new = snapshot("new-session", status: .inProgress, time: 200)
        _ = try await reconciler.reconcile(snapshots: [old], windows: windows)
        let state = DiscoveryTurnState()
        var calls = 0
        let coordinator = SessionDiscoveryCoordinator(delays: [.milliseconds(1), .milliseconds(1)]) {
            calls += 1
            _ = try! await reconciler.reconcile(snapshots: state.exists ? [new] : [old], windows: windows)
        }
        coordinator.start()
        defer { coordinator.stop() }
        coordinator.request()
        try await eventually { calls == 2 }
        try await Task.sleep(for: .milliseconds(25))
        try check(calls == 2 && store.tasks.first?.sessionID == "old-session", "Empty session was fabricated or polled")
        // An unacknowledged candidate's first-turn append starts a fresh bounded attempt.
        state.exists = true
        coordinator.request()
        try await eventually { store.tasks.first?.sessionID == "new-session" }
    }

    static func creationDuringRecoveryIsNotLost() async throws {
        let gate = DiscoveryGate()
        var calls = 0
        var active = 0
        var maximumActive = 0
        let coordinator = SessionDiscoveryCoordinator(delays: [.milliseconds(1), .milliseconds(1)]) {
            active += 1
            maximumActive = max(active, maximumActive)
            calls += 1
            if calls == 2 { await gate.wait() }
            active -= 1
        }
        coordinator.start()
        defer { coordinator.stop() }
        coordinator.request()
        try await eventually { gate.isWaiting }
        for _ in 0..<100 { coordinator.request() }
        gate.resume()
        try await eventually { calls == 4 }
        try await Task.sleep(for: .milliseconds(20))
        try check(calls == 4 && maximumActive == 1, "Creation during an in-flight lookup was lost or ran concurrently")
    }

    static func stopAndRestartIsolatePendingWork() async throws {
        let gate = DiscoveryGate()
        var calls = 0
        let coordinator = SessionDiscoveryCoordinator(delays: [.milliseconds(5), .milliseconds(5)]) {
            calls += 1
            if calls == 1 { await gate.wait() }
        }
        coordinator.start()
        coordinator.request()
        try await eventually { gate.isWaiting }
        coordinator.stop()
        coordinator.start()
        coordinator.request()
        gate.resume()
        try await eventually { calls == 3 }
        try await Task.sleep(for: .milliseconds(20))
        try check(calls == 3, "Old retry escaped into restarted monitoring")
        coordinator.request()
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(20))
        try check(calls == 3, "Pending discovery escaped stop")
    }

    static func snapshot(_ session: String, status: CodexThreadTurnStatus, time: TimeInterval) -> CodexThreadSnapshot {
        CodexThreadSnapshot(sessionID: session, turnID: "turn", cwd: cwd, title: session,
                            status: status, startedAt: Date(timeIntervalSince1970: time),
                            updatedAt: Date(timeIntervalSince1970: time + 1))
    }

    static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CheckFailure(message: "New session discovery timed out")
    }

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw CheckFailure(message: message) }
    }
}

private struct CheckFailure: Error { let message: String }

@MainActor
private final class DiscoveryTurnState { var exists = false }

@MainActor
private final class DiscoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}
