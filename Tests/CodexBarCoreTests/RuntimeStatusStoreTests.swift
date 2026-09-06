import CodexBarCore
import Foundation

@MainActor
func runtimeStatusStoreTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "runtime updates preserve in-flight Hook correlations for disconnect fallback") {
            for resumeFirst in [false, true] {
                let store = TaskStore()
                _ = try await store.apply([
                    runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                    runtimeStatusEvent(.preToolUse, timestamp: 101, invocation: "a")
                ])
                _ = try await applyRuntimeStatus(.needsAttention, to: store)
                if resumeFirst { _ = try await applyRuntimeStatus(.running, to: store) }
                _ = try await store.apply(runtimeStatusEvent(.permissionRequest, timestamp: 102))
                _ = try await store.apply(runtimeStatusEvent(.postToolUse, timestamp: 103, invocation: "a"))
                try expect(store.tasks.first?.status == .running, "live transition discarded the in-flight invocation")
            }
        },
        CodexBarTestCase(name: "runtime status resumes a persisted approval without losing task identity") {
            let root = runtimeStatusTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let persistenceURL = root.appendingPathComponent("tasks.json")
            let original = TaskStore(persistenceURL: persistenceURL)
            _ = try await original.apply([
                runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                runtimeStatusEvent(.permissionRequest, timestamp: 101)
            ])
            let previous = try require(original.tasks.first, "approval task is missing")
            let reloaded = TaskStore(persistenceURL: persistenceURL)
            await reloaded.load()
            try expect(try await applyRuntimeStatus(.running, to: reloaded), "runtime did not resume a persisted approval")
            let resumed = try require(reloaded.tasks.first, "resumed task is missing")
            try expect(resumed.status == .running && !resumed.isUnread, "runtime execution remained unread or blocked")
            try expect(resumed.id == previous.id && resumed.title == previous.title, "runtime changed task identity or title")
            try expect(resumed.startedAt == previous.startedAt, "runtime reset the task start time")
            try expect(resumed.updatedAt >= previous.updatedAt, "runtime moved the update time backwards")
            let persisted = TaskStore(persistenceURL: persistenceURL)
            await persisted.load()
            let durable = try require(persisted.tasks.first, "persisted runtime task is missing")
            try expect(durable.id == resumed.id && durable.status == .running && !durable.isUnread, "runtime transition was not persisted")
            try expect(abs(durable.updatedAt.timeIntervalSince(resumed.updatedAt)) < 1, "persisted runtime timestamp was lost")
        },
        CodexBarTestCase(name: "runtime status handles repeated approval cycles and aggregate waiting") {
            let store = TaskStore()
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100))
            for _ in 0..<2 {
                try expect(try await applyRuntimeStatus(.needsAttention, to: store), "new approval did not show attention")
                let waiting = store.tasks
                try expect(try await !applyRuntimeStatus(.needsAttention, to: store), "unchanged aggregate waiting republished the task")
                try expect(store.tasks == waiting, "remaining parallel approval lost its attention state")
                try expect(store.tasks.first?.isUnread == true, "approval was not unread")
                try expect(try await applyRuntimeStatus(.running, to: store), "resolved approvals did not resume execution")
                try expect(store.tasks.first?.isUnread == false, "resumed execution stayed unread")
            }
            _ = try await applyRuntimeStatus(.ready, to: store)
            let task = try require(store.tasks.first, "finished task is missing")
            try expect(task.isUnread, "runtime completion was not unread")
            _ = try await store.markRead(taskID: task.id)
            try expect(try await !applyRuntimeStatus(.ready, to: store), "unchanged runtime completion republished the task")
            try expect(store.tasks.first?.isUnread == false, "repeated runtime completion marked a read task unread")
        },
        CodexBarTestCase(name: "runtime status cannot overwrite another turn or revive a removed task") {
            let root = runtimeStatusTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
            try expect(try await !applyRuntimeStatus(.needsAttention, to: store), "runtime created an unknown task")
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100))
            let initial = store.tasks
            for identity in [
                ("another-session", "runtime-turn", "/tmp/runtime-project"),
                ("runtime-session", "another-turn", "/tmp/runtime-project"),
                ("runtime-session", "runtime-turn", "/tmp/another-project")
            ] {
                try expect(try await !store.applyRuntimeStatus(
                    sessionID: identity.0, turnID: identity.1, cwd: identity.2, status: .needsAttention
                ), "mismatched runtime identity changed a task")
            }
            try expect(store.tasks == initial, "mismatched runtime identity mutated state")
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 200, turn: "newer-turn"))
            try expect(try await !applyRuntimeStatus(.needsAttention, to: store), "old runtime turn overwrote the current task")
            let current = try require(store.tasks.first, "newer task is missing")
            _ = try await store.remove(taskID: current.id)
            let reloaded = TaskStore(persistenceURL: root.appendingPathComponent("tasks.json"))
            try expect(try await !reloaded.applyRuntimeStatus(
                sessionID: current.sessionID, turnID: current.turnID, cwd: current.cwd, status: .running
            ), "runtime revived a durable deletion")
            try expect(reloaded.tasks.isEmpty, "deleted task returned")
        },
        CodexBarTestCase(name: "runtime status matches normalized workspace paths without moving timestamps backwards") {
            let store = TaskStore()
            let future = Date().addingTimeInterval(60).timeIntervalSince1970
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: future))
            let previous = try require(store.tasks.first, "future task is missing")
            try expect(try await store.applyRuntimeStatus(
                sessionID: previous.sessionID,
                turnID: previous.turnID,
                cwd: "/tmp/runtime-project/../runtime-project/",
                status: .needsAttention
            ), "equivalent workspace path did not match")
            try expect(store.tasks.first?.updatedAt == previous.updatedAt, "runtime moved a future timestamp backwards")
        },
        CodexBarTestCase(name: "runtime persistence failure leaves visible state and approval correlation intact") {
            let root = runtimeStatusTemporaryDirectory()
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
                try? FileManager.default.removeItem(at: root)
            }
            let persistenceURL = root.appendingPathComponent("tasks.json")
            let store = TaskStore(persistenceURL: persistenceURL)
            _ = try await store.apply([
                runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                runtimeStatusEvent(.preToolUse, timestamp: 101, invocation: "a"),
                runtimeStatusEvent(.permissionRequest, timestamp: 102)
            ])
            let previous = store.tasks
            let snapshot = try Data(contentsOf: persistenceURL)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: root.path)
            var didThrow = false
            do { _ = try await applyRuntimeStatus(.running, to: store) }
            catch { didThrow = true }
            try expect(didThrow, "runtime persistence failure was swallowed")
            try expect(store.tasks == previous, "failed runtime transition published new state")
            try expect(try Data(contentsOf: persistenceURL) == snapshot, "failed runtime transition changed the snapshot")
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
            _ = try await store.apply(runtimeStatusEvent(.postToolUse, timestamp: 103, invocation: "a"))
            try expect(store.tasks.first?.status == .running, "failed runtime transition discarded approval correlation")
        },
        CodexBarTestCase(name: "runtime resumption clears obsolete approval blockers for subsequent tool cycles") {
            let store = TaskStore()
            _ = try await store.apply([
                runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                runtimeStatusEvent(.permissionRequest, timestamp: 101)
            ])
            _ = try await applyRuntimeStatus(.running, to: store)
            _ = try await store.apply([
                runtimeStatusEvent(.preToolUse, timestamp: 102, invocation: "b"),
                runtimeStatusEvent(.permissionRequest, timestamp: 103),
                runtimeStatusEvent(.postToolUse, timestamp: 104, invocation: "b")
            ])
            try expect(store.tasks.first?.status == .running, "old unknown approval kept a later resolved tool cycle blocked")
        },
        CodexBarTestCase(name: "reapplying runtime status corrects a delayed approval hook") {
            let store = TaskStore()
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100))
            _ = try await applyRuntimeStatus(.needsAttention, to: store)
            _ = try await applyRuntimeStatus(.running, to: store)
            _ = try await store.apply(runtimeStatusEvent(.permissionRequest, timestamp: 101))
            try expect(store.tasks.first?.status == .needsAttention, "fixture did not reproduce the delayed Hook race")
            _ = try await applyRuntimeStatus(.running, to: store)
            try expect(store.tasks.first?.status == .running, "latest runtime status did not correct the delayed approval")
        }
    ]
}

@MainActor
private func applyRuntimeStatus(_ status: CodexTaskStatus, to store: TaskStore) async throws -> Bool {
    try await store.applyRuntimeStatus(
        sessionID: "runtime-session",
        turnID: "runtime-turn",
        cwd: "/tmp/runtime-project",
        status: status
    )
}

private func runtimeStatusTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarRuntimeStatus-\(UUID().uuidString)", isDirectory: true)
}

private func runtimeStatusEvent(
    _ name: CodexHookEventName,
    timestamp: TimeInterval,
    turn: String = "runtime-turn",
    invocation: String? = nil
) -> CodexHookEvent {
    CodexHookEvent(
        id: "runtime-\(name.rawValue)-\(turn)-\(timestamp)",
        sessionID: "runtime-session",
        turnID: turn,
        cwd: "/tmp/runtime-project",
        name: name,
        promptSummary: name == .userPromptSubmit ? "Preserve this task title" : nil,
        toolName: name == .userPromptSubmit ? nil : "Bash",
        timestamp: Date(timeIntervalSince1970: timestamp),
        lastAssistantMessagePresent: false,
        toolExecution: name == .userPromptSubmit ? nil : CodexHookToolExecution(
            invocationID: invocation.map { String(repeating: $0, count: 64) },
            inputFingerprint: String(repeating: "a", count: 64)
        ),
        source: .visualStudioCode
    )
}
