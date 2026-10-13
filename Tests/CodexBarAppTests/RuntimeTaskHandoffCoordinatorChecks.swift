import CodexBarCore
import Foundation

@main
@MainActor
struct RuntimeTaskHandoffCoordinatorChecks {
    static let cwd = "/synthetic/resume"
    static let windows = [VSCodeWindowDescriptor(
        id: 1, title: "resume", workspaceFolderPaths: [cwd], workspace: .folder(cwd)
    )]

    static func main() async throws {
        try await recoversOnlyExactTarget()
        try await latestTargetWins()
        try await serializesPersistedHandoffs()
        try await stopAndSameTurnCancelLateWork()
        try await retriesAreBounded()
        try await retriesUntilTargetExists()
        try await retriesWhenTargetDirectoryIsWrong()
        try await storeAndWindowChangesRemainAuthoritative()
        try await rejectsUnrelatedUpdates()
        print("PASS runtime handoff identity, latest-target ordering, bounded retries, cancellation and no resurrection")
    }

    static func recoversOnlyExactTarget() async throws {
        let store = try await seededStore()
        let original = store.tasks[0]
        let loader = HandoffSnapshotLoader(results: [[
            snapshot("turn-2", cwd: cwd + "/./"),
            snapshot("turn-2", session: "other-session"),
            snapshot("turn-2", cwd: "/synthetic/other"),
            snapshot("turn-3")
        ]])
        var windowReads = 0
        var recovered = 0
        let coordinator = RuntimeTaskHandoffCoordinator(store: store, loader: loader) {
            windowReads += 1
            return windows
        }
        coordinator.onRecovered = { recovered += 1 }
        coordinator.start()
        coordinator.receive(update("turn-2"), currentTask: original)
        coordinator.receive(update("turn-2"), currentTask: original)
        try await eventually { recovered == 1 }
        precondition(store.tasks.count == 1 && store.tasks[0].turnID == "turn-2")
        precondition(store.tasks[0].status == .ready, "Completed follow-up retained the old running status")
        precondition(windowReads == 2, "Window membership must be refreshed before committing")
        coordinator.receive(update("turn-2"), currentTask: original)
        try await settle()
        let count = await loader.calls
        precondition(count == 1, "Repeated live states restarted the same handoff")
        coordinator.stop()
    }

    static func latestTargetWins() async throws {
        let store = try await seededStore()
        let original = store.tasks[0]
        let loader = HandoffSnapshotLoader(
            results: [[snapshot("turn-2")], [snapshot("turn-3")]], blockFirst: true
        )
        let coordinator = coordinator(store, loader)
        var recovered = 0
        coordinator.onRecovered = { recovered += 1 }
        coordinator.start()
        coordinator.receive(update("turn-2"), currentTask: original)
        try await eventually { await loader.isWaiting }
        coordinator.receive(update("turn-3"), currentTask: original)
        await loader.release()
        try await eventually { store.tasks.first?.turnID == "turn-3" }
        try await settle()
        precondition(store.tasks.first?.turnID == "turn-3" && recovered == 1,
                     "An older in-flight handoff overwrote the latest target")
        coordinator.stop()
    }

    static func stopAndSameTurnCancelLateWork() async throws {
        for stops in [true, false] {
            let store = try await seededStore()
            let original = store.tasks[0]
            let loader = HandoffSnapshotLoader(results: [[snapshot("turn-2")]], blockFirst: true)
            let coordinator = coordinator(store, loader)
            coordinator.onRecovered = { preconditionFailure("Cancelled handoff published") }
            coordinator.start()
            coordinator.receive(update("turn-2"), currentTask: original)
            try await eventually { await loader.isWaiting }
            if stops {
                coordinator.stop()
                coordinator.start()
            } else {
                coordinator.receive(update("turn-1"), currentTask: original)
            }
            await loader.release()
            try await settle()
            precondition(store.tasks == [original], "Cancelled work changed the task")
            coordinator.stop()
        }
    }

    static func serializesPersistedHandoffs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar-handoff-race-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for finalTurn in ["turn-3", "turn-4"] {
            for attempt in 0..<300 {
                let store = TaskStore(persistenceURL: root.appendingPathComponent("\(finalTurn)-\(attempt).json"))
                _ = try await store.apply(event("turn-1", timestamp: 100))
                let loader = HandoffSnapshotLoader(results: [[snapshot("turn-2")], [
                    CodexThreadSnapshot(
                        sessionID: "session", turnID: finalTurn, cwd: cwd, title: finalTurn, status: .completed,
                        startedAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 350)
                    )
                ]])
                var reads = 0
                var coordinator: RuntimeTaskHandoffCoordinator!
                coordinator = RuntimeTaskHandoffCoordinator(store: store, loader: loader, windowSnapshot: {
                    reads += 1
                    if reads == 2 {
                        Task {
                            try? await Task.sleep(for: .microseconds((attempt % 20) * 25))
                            let current = store.tasks[0]
                            coordinator.receive(update("turn-3"), currentTask: current)
                            if finalTurn == "turn-4" {
                                // T4 supersedes T3 while T3 still waits for T2's write to finish.
                                coordinator.receive(update("turn-4"), currentTask: current)
                            }
                        }
                    }
                    return windows
                }, retryDelays: [.milliseconds(1), .milliseconds(1)])
                coordinator.start()
                coordinator.receive(update("turn-2"), currentTask: store.tasks[0])
                try await eventually { store.tasks.first?.turnID == finalTurn }
                coordinator.stop()
            }
        }
    }

    static func retriesAreBounded() async throws {
        for throwsError in [false, true] {
            let store = try await seededStore()
            let original = store.tasks[0]
            let loader = HandoffSnapshotLoader(results: [[]], throwsError: throwsError)
            let coordinator = coordinator(store, loader)
            var failures = 0
            coordinator.onFailure = { failures += 1 }
            coordinator.start()
            coordinator.receive(update("turn-2"), currentTask: original)
            try await eventually { failures == 1 }
            coordinator.receive(update("turn-2"), currentTask: original)
            try await settle()
            let count = await loader.calls
            precondition(count == 3 && failures == 1, "Failed recovery retried without a new target")
            precondition(store.tasks == [original])
            coordinator.stop()
        }
    }

    static func retriesUntilTargetExists() async throws {
        let store = try await seededStore()
        let loader = HandoffSnapshotLoader(results: [[], [snapshot("turn-1")], [snapshot("turn-2")]])
        let coordinator = coordinator(store, loader)
        coordinator.start()
        coordinator.receive(update("turn-2"), currentTask: store.tasks[0])
        try await eventually { store.tasks.first?.turnID == "turn-2" }
        let count = await loader.calls
        precondition(count == 3)
        coordinator.stop()
    }

    static func retriesWhenTargetDirectoryIsWrong() async throws {
        let store = try await seededStore()
        let loader = HandoffSnapshotLoader(results: [
            [snapshot("turn-2", cwd: "/synthetic/other")], [snapshot("turn-2")]
        ])
        let coordinator = coordinator(store, loader)
        coordinator.start()
        coordinator.receive(update("turn-2"), currentTask: store.tasks[0])
        try await eventually { store.tasks.first?.turnID == "turn-2" }
        let count = await loader.calls
        precondition(count == 2, "A rejected directory stopped the remaining handoff retries")
        coordinator.stop()
    }

    static func storeAndWindowChangesRemainAuthoritative() async throws {
        for change in ["delete", "hook", "window"] {
            let store = try await seededStore()
            let original = store.tasks[0]
            let loader = HandoffSnapshotLoader(results: [[snapshot("turn-2")]], blockFirst: true)
            let currentWindows = HandoffWindowState(windows)
            let coordinator = RuntimeTaskHandoffCoordinator(store: store, loader: loader) { currentWindows.windows }
            coordinator.onRecovered = { preconditionFailure("Stale recovery published") }
            coordinator.start()
            coordinator.receive(update("turn-2"), currentTask: original)
            try await eventually { await loader.isWaiting }
            switch change {
            case "delete": _ = try await store.remove(taskID: original.id)
            case "hook": _ = try await store.apply(event("turn-3", timestamp: 300))
            default: currentWindows.windows = []
            }
            let expected = store.tasks
            await loader.release()
            try await settle()
            precondition(store.tasks == expected, "Recovery resurrected or replaced newer state")
            coordinator.stop()
        }
    }

    static func rejectsUnrelatedUpdates() async throws {
        let store = try await seededStore()
        let loader = HandoffSnapshotLoader(results: [[snapshot("turn-2")]])
        let coordinator = coordinator(store, loader)
        let original = store.tasks[0]
        coordinator.receive(update("turn-2"), currentTask: original)
        coordinator.start()
        for update in [
            update("turn-2", session: "other-session"), update("turn-2", cwd: "/synthetic/other"),
            update(nil), update(" "), update("turn-1"), update("turn-2", cwd: nil)
        ] { coordinator.receive(update, currentTask: original) }
        try await settle()
        let count = await loader.calls
        precondition(count == 0 && store.tasks == [original])
        coordinator.stop()
    }

    private static func coordinator(_ store: TaskStore, _ loader: HandoffSnapshotLoader) -> RuntimeTaskHandoffCoordinator {
        RuntimeTaskHandoffCoordinator(
            store: store, loader: loader, windowSnapshot: { windows },
            retryDelays: [.milliseconds(1), .milliseconds(1)]
        )
    }

    static func seededStore() async throws -> TaskStore {
        let store = TaskStore()
        _ = try await store.apply(event("turn-1", timestamp: 100))
        return store
    }

    static func event(_ turn: String, timestamp: TimeInterval) -> CodexHookEvent {
        CodexHookEvent(
            id: "event-\(turn)", sessionID: "session", turnID: turn, cwd: cwd,
            name: .userPromptSubmit, promptSummary: turn, toolName: nil,
            timestamp: Date(timeIntervalSince1970: timestamp), lastAssistantMessagePresent: false,
            source: .visualStudioCode
        )
    }

    static func snapshot(_ turn: String, session: String = "session", cwd: String = cwd) -> CodexThreadSnapshot {
        CodexThreadSnapshot(
            sessionID: session, turnID: turn, cwd: cwd, title: turn, status: .completed,
            startedAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 250)
        )
    }

    static func update(_ turn: String?, session: String = "session", cwd: String? = cwd) -> CodexRuntimeStatusUpdate {
        CodexRuntimeStatusUpdate(sessionID: session, turnID: turn, cwd: cwd, status: .ready)
    }

    static func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Runtime handoff check timed out")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(30)) }
}

@MainActor
private final class HandoffWindowState {
    var windows: [VSCodeWindowDescriptor]
    init(_ windows: [VSCodeWindowDescriptor]) { self.windows = windows }
}

private actor HandoffSnapshotLoader: CodexThreadSnapshotLoading {
    private let results: [[CodexThreadSnapshot]]
    private let blockFirst: Bool
    private let throwsError: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    var isWaiting: Bool { continuation != nil }

    init(results: [[CodexThreadSnapshot]], blockFirst: Bool = false, throwsError: Bool = false) {
        self.results = results
        self.blockFirst = blockFirst
        self.throwsError = throwsError
    }

    func loadSnapshots(matching windows: [VSCodeWindowDescriptor]) async throws -> [CodexThreadSnapshot] {
        calls += 1
        let result = results[min(calls - 1, results.count - 1)]
        if calls == 1 && blockFirst { await withCheckedContinuation { continuation = $0 } }
        if throwsError { throw CocoaError(.fileReadUnknown) }
        return result
    }

    func release() { continuation?.resume(); continuation = nil }
}
