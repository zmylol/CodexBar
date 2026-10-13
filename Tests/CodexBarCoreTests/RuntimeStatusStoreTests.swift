import CodexBarCore
import Foundation

@MainActor
func runtimeStatusStoreTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "Hook Stop remains terminal across runtime replay and store restart") {
            let root = runtimeStatusTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("tasks.json")
            let store = TaskStore(persistenceURL: url)
            _ = try await store.apply([
                runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                runtimeStatusEvent(.stop, timestamp: 110)
            ])
            _ = try await store.markRead(taskID: "runtime-session:runtime-turn")
            let reloaded = TaskStore(persistenceURL: url)
            await reloaded.load()
            for candidate in [store, reloaded] {
                let completed = candidate.tasks
                for status in [CodexTaskStatus.running, .needsAttention, .ready] {
                    try expect(try await !applyRuntimeStatus(status, to: candidate), "runtime changed a Hook-confirmed Stop")
                    try expect(candidate.tasks == completed, "runtime replay changed a completed task or its read state")
                }
            }
        },
        CodexBarTestCase(name: "a captured Stop survives a newer runtime receipt timestamp") {
            let store = TaskStore()
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: Date().addingTimeInterval(-2).timeIntervalSince1970))
            _ = try await applyRuntimeStatus(.needsAttention, to: store)
            let stop = runtimeStatusEvent(.stop, timestamp: Date().timeIntervalSince1970)
            try await Task.sleep(for: .milliseconds(1))
            _ = try await applyRuntimeStatus(.running, to: store)
            try expect(store.tasks[0].updatedAt > stop.timestamp, "fixture did not delay the captured Stop")
            try expect(try await store.apply(stop), "runtime receipt time discarded a valid Stop")
            try expect(store.tasks[0].status == .ready, "a completed turn remained running")
        },
        CodexBarTestCase(name: "a prompt after confirmed Stop reopens despite an earlier runtime receipt") {
            let store = TaskStore()
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100))
            _ = try await applyRuntimeStatus(.needsAttention, to: store)
            _ = try await store.apply(runtimeStatusEvent(.stop, timestamp: 110))
            try expect(store.tasks[0].updatedAt > Date(timeIntervalSince1970: 120), "fixture did not retain the runtime receipt time")
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 110))
            try expect(store.tasks[0].status == .ready, "equal-time prompt reopened a confirmed Stop")
            try expect(try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 120)), "runtime receipt time discarded a prompt after Stop")
            try expect(store.tasks[0].status == .running && store.tasks[0].startedAt == Date(timeIntervalSince1970: 120), "the newer prompt did not establish a reopened execution")
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 105))
            try expect(try await !store.apply(runtimeStatusEvent(.stop, timestamp: 115)), "old Hook events closed the reopened execution")
            try expect(try await applyRuntimeStatus(.needsAttention, to: store), "reopened execution did not accept runtime status")
        },
        CodexBarTestCase(name: "late same-turn prompts preserve Stop while a newer prompt may reopen") {
            let root = runtimeStatusTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("tasks.json")
            var store = TaskStore(persistenceURL: url)
            _ = try await store.apply([
                runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                runtimeStatusEvent(.stop, timestamp: 110)
            ])
            for timestamp in [99.0, 110.0] {
                _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: timestamp))
                try expect(store.tasks[0].status == .ready, "a delayed prompt reopened the completed turn")
                try expect(try await !applyRuntimeStatus(.running, to: store), "a title-only prompt cleared the Stop marker")
            }
            try expect(try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 120)), "a newer prompt could not reopen its turn")
            try expect(store.tasks[0].status == .running, "a newer prompt remained completed")
            try expect(store.tasks[0].startedAt == Date(timeIntervalSince1970: 120), "reopening retained the previous execution's start time")
            store = TaskStore(persistenceURL: url)
            await store.load()
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 105))
            try expect(store.tasks[0].startedAt == Date(timeIntervalSince1970: 120), "a delayed prompt erased the persisted reopening boundary")
            try expect(try await !store.apply(runtimeStatusEvent(.stop, timestamp: 115)), "an old Stop closed the reopened execution")
            try expect(try await applyRuntimeStatus(.needsAttention, to: store), "a reopened turn retained the old Stop marker")
            _ = try await store.apply(runtimeStatusEvent(.stop, timestamp: 130))
            try expect(store.tasks[0].status == .ready, "a reopened turn could not stop again")
            try expect(try await !applyRuntimeStatus(.running, to: store), "the second Stop was not terminal")
        },
        CodexBarTestCase(name: "a new turn and runtime-only ready state remain resumable") {
            let root = runtimeStatusTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("tasks.json")
            let store = TaskStore(persistenceURL: url)
            _ = try await store.apply([
                runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                runtimeStatusEvent(.stop, timestamp: 110),
                runtimeStatusEvent(.userPromptSubmit, timestamp: 120, turn: "new-turn")
            ])
            try expect(store.tasks[0].turnID == "new-turn" && store.tasks[0].status == .running, "Stop blocked a different turn")
            _ = try await store.applyRuntimeStatus(sessionID: "runtime-session", turnID: "new-turn", cwd: "/tmp/runtime-project", status: .ready)
            var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var tasks = snapshot["tasks"] as! [[String: Any]]
            tasks[0].removeValue(forKey: "stoppedAt")
            snapshot["tasks"] = tasks
            try JSONSerialization.data(withJSONObject: snapshot).write(to: url)
            let reloaded = TaskStore(persistenceURL: url)
            await reloaded.load()
            try expect(try await reloaded.applyRuntimeStatus(sessionID: "runtime-session", turnID: "new-turn", cwd: "/tmp/runtime-project", status: .running), "legacy or runtime-only completion became permanently terminal")
        },
        CodexBarTestCase(name: "continued and initially observed Stops retain terminal identity") {
            for hasInitialTurn in [false, true] {
                let store = TaskStore()
                if hasInitialTurn {
                    _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100, turn: "initial-turn"))
                }
                _ = try await store.apply(runtimeStatusEvent(.stop, timestamp: 110))
                try expect(store.tasks.first?.turnID == "runtime-turn" && store.tasks.first?.status == .ready, "Stop did not establish the completed identity")
                try expect(try await !applyRuntimeStatus(.running, to: store), "a newly established Stop lost its terminal marker")
            }
        },
        CodexBarTestCase(name: "a continued Stop survives runtime receipt time but respects the latest prompt") {
            for stopTimestamp in [99.0, 110.0] {
                let store = TaskStore()
                _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100, turn: "initial-turn"))
                _ = try await store.applyRuntimeStatus(
                    sessionID: "runtime-session", turnID: "initial-turn", cwd: "/tmp/runtime-project", status: .needsAttention
                )
                let applied = try await store.apply(runtimeStatusEvent(.stop, timestamp: stopTimestamp))
                if stopTimestamp < 100 {
                    try expect(!applied && store.tasks[0].turnID == "initial-turn", "a continued Stop crossed a newer prompt boundary")
                    try expect(store.tasks[0].status == .needsAttention, "an older Stop changed the active turn")
                } else {
                    try expect(applied, "runtime receipt time discarded a valid continued Stop")
                    try expect(store.tasks[0].turnID == "runtime-turn" && store.tasks[0].status == .ready, "continued completion retained the old active turn")
                    try expect(try await !applyRuntimeStatus(.running, to: store), "runtime reopened a continued Stop")
                }
            }
        },
        CodexBarTestCase(name: "a continued Stop after runtime completion retains Hook terminal identity") {
            let store = TaskStore()
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100, turn: "initial-turn"))
            _ = try await store.applyRuntimeStatus(
                sessionID: "runtime-session", turnID: "initial-turn", cwd: "/tmp/runtime-project", status: .ready
            )
            try expect(try await store.apply(runtimeStatusEvent(.stop, timestamp: 110)), "runtime completion discarded the continued Hook Stop")
            try expect(store.tasks[0].turnID == "runtime-turn" && store.tasks[0].status == .ready, "continued Hook Stop retained the old turn identity")
            try expect(try await !applyRuntimeStatus(.running, to: store), "runtime reopened the continued Hook completion")
            try expect(try await !store.apply(runtimeStatusEvent(.stop, timestamp: 120, turn: "unmatched-turn")), "an unmatched Stop replaced a Hook-confirmed completed row")
        },
        CodexBarTestCase(name: "persisted Stop metadata rejects impossible timestamps and statuses") {
            let invalid: [(Any, String)] = [(111.0, "ready"), (105.0, "running"), (105.0, "needsAttention"), ("nonfinite", "ready")]
            for (value, status) in invalid {
                let root = runtimeStatusTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let url = root.appendingPathComponent("tasks.json")
                let store = TaskStore(persistenceURL: url)
                _ = try await store.apply([
                    runtimeStatusEvent(.userPromptSubmit, timestamp: 100),
                    runtimeStatusEvent(.stop, timestamp: 110)
                ])
                var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                var tasks = snapshot["tasks"] as! [[String: Any]]
                tasks[0]["stoppedAt"] = value
                tasks[0]["status"] = status
                snapshot["tasks"] = tasks
                let text = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
                    .replacingOccurrences(of: "\"nonfinite\"", with: "1e999")
                try Data(text.utf8).write(to: url)
                let reloaded = TaskStore(persistenceURL: url)
                await reloaded.load()
                try expect(reloaded.tasks.isEmpty && reloaded.recoverySnapshotURL != nil, "inconsistent Stop metadata was trusted")
            }
        },
        CodexBarTestCase(name: "failed Stop persistence does not leak a terminal marker into memory") {
            let root = runtimeStatusTemporaryDirectory()
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
                try? FileManager.default.removeItem(at: root)
            }
            let url = root.appendingPathComponent("tasks.json")
            let store = TaskStore(persistenceURL: url)
            _ = try await store.apply(runtimeStatusEvent(.userPromptSubmit, timestamp: 100))
            _ = try await applyRuntimeStatus(.needsAttention, to: store)
            let previous = store.tasks
            let data = try Data(contentsOf: url)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: root.path)
            var failed = false
            do { _ = try await store.apply(runtimeStatusEvent(.stop, timestamp: Date().timeIntervalSince1970)) }
            catch { failed = true }
            try expect(failed && store.tasks == previous, "failed Stop persistence mutated visible state")
            try expect(try Data(contentsOf: url) == data, "failed Stop persistence changed the durable snapshot")
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: root.path)
            try expect(try await applyRuntimeStatus(.running, to: store), "rolled-back Stop still blocked runtime updates")
        },
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
        toolExecution: name == .userPromptSubmit || name == .stop ? nil : CodexHookToolExecution(
            invocationID: invocation.map { String(repeating: $0, count: 64) },
            inputFingerprint: String(repeating: "a", count: 64)
        ),
        source: .visualStudioCode
    )
}
