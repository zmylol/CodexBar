import CodexBarCore
import Foundation

/// Recovers only a live turn that has moved ahead of its existing Hook row.
@MainActor
final class RuntimeTaskHandoffCoordinator {
    var onRecovered: (() -> Void)?
    var onFailure: (() -> Void)?

    private struct Request {
        let id: UUID
        let cwd: String
        let turnID: String
        var task: Task<CodexTask?, Never>?
    }

    private let store: TaskStore
    private let loader: any CodexThreadSnapshotLoading
    private let reconciler: StartupTaskReconciler
    private let windowSnapshot: @MainActor () async -> [VSCodeWindowDescriptor]?
    private let retryDelays: [Duration]
    private var requests: [String: Request] = [:]
    private var isStarted = false

    init(
        store: TaskStore,
        loader: any CodexThreadSnapshotLoading,
        windowSnapshot: @escaping @MainActor () async -> [VSCodeWindowDescriptor]?,
        retryDelays: [Duration] = [.milliseconds(100), .milliseconds(300)]
    ) {
        self.store = store
        self.loader = loader
        self.reconciler = StartupTaskReconciler(store: store)
        self.windowSnapshot = windowSnapshot
        self.retryDelays = Array(retryDelays.prefix(2))
    }

    func start() { stop(); isStarted = true }

    func stop() {
        isStarted = false
        for request in requests.values { request.task?.cancel() }
        requests.removeAll()
    }

    func receive(_ update: CodexRuntimeStatusUpdate, currentTask: CodexTask) {
        guard isStarted, update.sessionID == currentTask.sessionID,
              let cwd = update.cwd, cwd == currentTask.cwd,
              let turnID = update.turnID,
              !turnID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              turnID.utf8.count <= 512
        else { return }

        let session = update.sessionID
        if turnID == currentTask.turnID {
            requests.removeValue(forKey: session)?.task?.cancel()
            return
        }
        if let previous = requests[session], previous.cwd == cwd, previous.turnID == turnID { return }
        let previous = requests[session]?.task
        previous?.cancel()
        let id = UUID()
        requests[session] = Request(id: id, cwd: cwd, turnID: turnID)
        requests[session]?.task = Task { [weak self] in
            // Cancellation cannot interrupt an atomic write already in progress.
            // Wait for its result, including through a cancelled intermediate request.
            let inheritedCommit = await previous?.value
            guard let self, isCurrent(session, id: id) else { return inheritedCommit }
            let expectedTask: CodexTask
            if stillContains(currentTask) {
                expectedTask = currentTask
            } else if let inheritedCommit,
                      inheritedCommit.sessionID == session, inheritedCommit.cwd == cwd,
                      store.tasks.contains(inheritedCommit) {
                expectedTask = inheritedCommit
            } else {
                return inheritedCommit
            }
            return await recover(session: session, turnID: turnID, id: id, expectedTask: expectedTask)
                ?? inheritedCommit
        }
    }

    private func recover(session: String, turnID: String, id: UUID, expectedTask: CodexTask) async -> CodexTask? {
        for attempt in 0...retryDelays.count {
            guard isCurrent(session, id: id), stillContains(expectedTask) else { return nil }
            do {
                if attempt > 0 { try await Task.sleep(for: retryDelays[attempt - 1]) }
                guard isCurrent(session, id: id), stillContains(expectedTask) else { return nil }
                if let windows = await windowSnapshot() {
                    guard isCurrent(session, id: id), stillContains(expectedTask) else { return nil }
                    let snapshots = try await loader.loadSnapshots(matching: windows)
                    guard isCurrent(session, id: id), stillContains(expectedTask) else { return nil }
                    let target = snapshots.filter { $0.sessionID == session && $0.turnID == turnID }
                    if !target.isEmpty, let freshWindows = await windowSnapshot() {
                        guard isCurrent(session, id: id), stillContains(expectedTask) else { return nil }
                        guard !freshWindows.isEmpty else { return nil }
                        let changed = try await reconciler.reconcile(
                            snapshots: target, windows: freshWindows, replacing: expectedTask
                        )
                        if changed > 0 {
                            let committed = store.tasks.first {
                                $0.sessionID == session && $0.turnID == turnID && $0.cwd == expectedTask.cwd
                            }
                            if isCurrent(session, id: id) { onRecovered?() }
                            return committed
                        }
                        guard isCurrent(session, id: id), stillContains(expectedTask) else { return nil }
                    }
                }
            } catch is CancellationError {
                return nil
            } catch {
                // Snapshot files can lag the runtime stream. Retry only within this short handoff.
            }
        }
        if isCurrent(session, id: id), stillContains(expectedTask) { onFailure?() }
        return nil
    }

    private func isCurrent(_ session: String, id: UUID) -> Bool {
        isStarted && !Task.isCancelled && requests[session]?.id == id
    }

    private func stillContains(_ expected: CodexTask) -> Bool {
        store.tasks.contains {
            $0.id == expected.id && $0.sessionID == expected.sessionID
                && $0.cwd == expected.cwd
        }
    }
}
