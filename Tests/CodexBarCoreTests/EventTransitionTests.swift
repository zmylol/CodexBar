import Combine
import Foundation
import CodexBarCore

@MainActor
func eventTransitionTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "applies lifecycle state transitions") {
            let store = TaskStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Build the parser")
            let permission = event(.permissionRequest, timestamp: 110)
            let stop = event(.stop, timestamp: 120)

            try expect(try await store.apply(start), "start event was not applied")
            try expect(store.tasks.first?.status == .running, "start did not set running")
            try expect(store.tasks.first?.title == "Build the parser", "prompt did not become title")
            try expect(store.tasks.first?.workspaceName == "project-alpha", "workspace name is wrong")

            try expect(try await store.apply(permission), "permission event was not applied")
            try expect(store.tasks.first?.status == .needsAttention, "permission did not need attention")
            try expect(store.tasks.first?.title == "Build the parser", "existing title was not preserved")

            try expect(try await store.apply(stop), "stop event was not applied")
            try expect(store.tasks.first?.status == .ready, "stop did not set ready")
            try expect(store.tasks.first?.isUnread ?? false, "ready task should be unread")
        },
        CodexBarTestCase(name: "applies an Inbox batch as one persisted state") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarBatchStoreTests-\(UUID().uuidString)", isDirectory: true)
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TaskStore(persistenceURL: persistenceURL)
            let events = [
                event(.userPromptSubmit, timestamp: 100, prompt: "Batch task"),
                event(.stop, timestamp: 110)
            ]

            try expect(try await store.apply(events) == 2, "batch did not apply both events")
            try expect(store.tasks.first?.status == .ready, "batch did not commit its final state")
            let reloadedStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedStore.load()
            try expect(
                reloadedStore.tasks.first?.status == .ready,
                "batch final state was not persisted"
            )
        },
        CodexBarTestCase(name: "does not publish an unchanged storage revision") {
            let store = TaskStore()
            var publicationCount = 0
            let observation = store.objectWillChange.sink {
                publicationCount += 1
            }
            defer { observation.cancel() }

            await store.load()
            _ = try await store.apply([CodexHookEvent]())
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Publish once")
            try expect(try await store.apply(start), "new event was not applied")
            try expect(try await !store.apply(start), "duplicate event was applied")

            try expect(
                publicationCount == 1,
                "unchanged storage revisions triggered \(publicationCount) publications"
            )
        },
        CodexBarTestCase(name: "deduplicates repeated events") {
            let store = TaskStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Run project-gamma")

            try expect(try await store.apply(start), "first event was not applied")
            let snapshot = store.tasks
            try expect(try await !store.apply(start), "duplicate event was reported as applied")
            try expect(store.tasks == snapshot, "duplicate event changed tasks")
        },
        CodexBarTestCase(name: "keeps only the latest turn for one cwd") {
            let store = TaskStore()
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "old-session",
                turn: "old-turn",
                timestamp: 100,
                prompt: "Old task"
            ))
            _ = try await store.apply(event(
                .stop,
                session: "old-session",
                turn: "old-turn",
                timestamp: 110
            ))

            try expect(try await store.apply(event(
                .userPromptSubmit,
                session: "new-session",
                turn: "new-turn",
                timestamp: 120,
                prompt: "New task"
            )), "new turn was not applied")

            try expect(store.tasks.count == 1, "same cwd produced more than one task")
            let task = try require(store.tasks.first, "latest task is missing")
            try expect(task.id == "new-session:new-turn", "old turn remained visible")
            try expect(task.status == .running, "latest turn status is wrong")
            try expect(task.title == "New task", "latest turn title is wrong")
        },
        CodexBarTestCase(name: "ignores a late stop from a superseded turn") {
            let store = TaskStore()
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "old-session",
                turn: "old-turn",
                timestamp: 100
            ))
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "new-session",
                turn: "new-turn",
                timestamp: 200
            ))

            try expect(try await !store.apply(event(
                .stop,
                session: "old-session",
                turn: "old-turn",
                timestamp: 300
            )), "late stop was reported as applied")

            try expect(store.tasks.count == 1, "late stop recreated the old turn")
            let task = try require(store.tasks.first, "current task is missing")
            try expect(task.id == "new-session:new-turn", "late stop replaced the current turn")
            try expect(task.status == .running, "late stop changed the current status")
        },
        CodexBarTestCase(name: "closes a continued turn whose stop has a new turn id") {
            let store = TaskStore()
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "same-session",
                turn: "initial-turn",
                timestamp: 100,
                prompt: "Finish the task"
            ))

            try expect(try await store.apply(event(
                .stop,
                session: "same-session",
                turn: "continued-turn",
                timestamp: 120
            )), "continued turn stop was not applied")

            let task = try require(store.tasks.first, "continued task is missing")
            try expect(store.tasks.count == 1, "continued turn created a duplicate row")
            try expect(
                task.id == "same-session:continued-turn",
                "continued turn did not become the current row"
            )
            try expect(task.status == .ready, "continued turn remained running")
            try expect(task.title == "Finish the task", "continued turn lost the task title")
            try expect(task.isUnread, "continued turn completion was not marked unread")
        },
        CodexBarTestCase(name: "ignores an older same-session stop after a newer prompt") {
            let store = TaskStore()
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "same-session",
                turn: "new-turn",
                timestamp: 200,
                prompt: "Current task"
            ))

            try expect(try await !store.apply(event(
                .stop,
                session: "same-session",
                turn: "old-turn",
                timestamp: 150
            )), "older same-session stop was applied")

            let task = try require(store.tasks.first, "current task is missing")
            try expect(task.id == "same-session:new-turn", "older stop replaced the current turn")
            try expect(task.status == .running, "older stop changed the current status")
        },
        CodexBarTestCase(name: "does not replace a ready row with an unmatched stop") {
            let store = TaskStore()
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "same-session",
                turn: "completed-turn",
                timestamp: 100,
                prompt: "Completed task"
            ))
            _ = try await store.apply(event(
                .stop,
                session: "same-session",
                turn: "completed-turn",
                timestamp: 110
            ))

            try expect(try await !store.apply(event(
                .stop,
                session: "same-session",
                turn: "unmatched-turn",
                timestamp: 120
            )), "unmatched stop replaced an already-ready row")

            let task = try require(store.tasks.first, "ready task is missing")
            try expect(
                task.id == "same-session:completed-turn",
                "unmatched stop changed the completed turn identity"
            )
            try expect(task.status == .ready, "unmatched stop changed the ready status")
            try expect(
                task.updatedAt == Date(timeIntervalSince1970: 110),
                "unmatched stop changed the completion time"
            )
        },
        CodexBarTestCase(name: "ignores a late prompt from an older turn") {
            let store = TaskStore()
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "old-session",
                turn: "old-turn",
                timestamp: 100
            ))
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "new-session",
                turn: "new-turn",
                timestamp: 200,
                prompt: "Current task"
            ))

            try expect(try await !store.apply(event(
                .userPromptSubmit,
                session: "old-session",
                turn: "old-turn",
                timestamp: 150,
                prompt: "Late old title"
            )), "older prompt was reported as applied")

            let task = try require(store.tasks.first, "current task is missing")
            try expect(store.tasks.count == 1, "older prompt recreated the old turn")
            try expect(task.id == "new-session:new-turn", "older prompt replaced the current turn")
            try expect(task.title == "Current task", "older prompt replaced the current title")
        },
        CodexBarTestCase(name: "merges turns whose cwd normalizes to the same path") {
            let store = TaskStore()
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "old-session",
                turn: "old-turn",
                timestamp: 100,
                cwd: "/tmp/project"
            ))
            _ = try await store.apply(event(
                .userPromptSubmit,
                session: "new-session",
                turn: "new-turn",
                timestamp: 200,
                cwd: "/tmp/parent/../project"
            ))

            try expect(store.tasks.count == 1, "normalized cwd produced duplicate tasks")
            try expect(store.tasks.first?.id == "new-session:new-turn", "wrong normalized cwd task remained")
        },
        CodexBarTestCase(name: "ignores incomplete events") {
            let store = TaskStore()
            let incomplete = CodexHookEvent(
                id: "incomplete",
                sessionID: nil,
                turnID: nil,
                cwd: nil,
                name: nil,
                promptSummary: nil,
                toolName: nil,
                timestamp: Date(timeIntervalSince1970: 100),
                lastAssistantMessagePresent: false
            )

            try expect(try await !store.apply(incomplete), "incomplete event was applied")
            try expect(store.tasks.isEmpty, "incomplete event created a task")
        },
        CodexBarTestCase(name: "sorts tasks by attention and unread priority") {
            let store = TaskStore()
            _ = try await store.apply(event(.userPromptSubmit, session: "running", turn: "1", timestamp: 100, cwd: "/tmp/running"))
            _ = try await store.apply(event(.userPromptSubmit, session: "attention", turn: "1", timestamp: 101, cwd: "/tmp/attention"))
            _ = try await store.apply(event(.permissionRequest, session: "attention", turn: "1", timestamp: 102, cwd: "/tmp/attention"))
            _ = try await store.apply(event(.userPromptSubmit, session: "unread", turn: "1", timestamp: 103, cwd: "/tmp/unread"))
            _ = try await store.apply(event(.stop, session: "unread", turn: "1", timestamp: 104, cwd: "/tmp/unread"))
            _ = try await store.apply(event(.userPromptSubmit, session: "read", turn: "1", timestamp: 105, cwd: "/tmp/read"))
            _ = try await store.apply(event(.stop, session: "read", turn: "1", timestamp: 106, cwd: "/tmp/read"))
            try await store.markRead(taskID: "read:1")

            try expect(
                store.sortedTasks.map(\.id) == ["attention:1", "unread:1", "running:1", "read:1"],
                "task priority order is wrong"
            )
        },
        CodexBarTestCase(name: "persists tasks and event deduplication across restart") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarStoreTests-\(UUID().uuidString)", isDirectory: true)
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let start = event(.userPromptSubmit, timestamp: 200, prompt: "Persist me")

            let firstStore = TaskStore(persistenceURL: persistenceURL)
            try expect(try await firstStore.apply(start), "first store did not apply event")
            let reloadedStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedStore.load()

            try expect(reloadedStore.tasks.first?.title == "Persist me", "task did not reload")
            try expect(try await !reloadedStore.apply(start), "processed event id did not reload")
            let attributes = try FileManager.default.attributesOfItem(atPath: persistenceURL.path)
            try expect(
                (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "task snapshot mode is not 0600"
            )
        },
        CodexBarTestCase(name: "serializes concurrent mutations without losing durable state") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodexBarConcurrentStoreTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TaskStore(persistenceURL: persistenceURL)
            let first = event(
                .userPromptSubmit,
                session: "concurrent-a",
                turn: "1",
                timestamp: 300,
                cwd: "/tmp/concurrent-a"
            )
            let second = event(
                .userPromptSubmit,
                session: "concurrent-b",
                turn: "1",
                timestamp: 301,
                cwd: "/tmp/concurrent-b"
            )

            async let firstApplied = store.apply(first)
            async let secondApplied = store.apply(second)
            let applied = try await (firstApplied, secondApplied)

            try expect(applied.0 && applied.1, "a concurrent mutation was discarded")
            try expect(store.tasks.count == 2, "published state lost a concurrent mutation")
            let reloadedStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedStore.load()
            try expect(
                Set(reloadedStore.tasks.map(\.id)) == ["concurrent-a:1", "concurrent-b:1"],
                "durable state lost a concurrent mutation"
            )
        },
        CodexBarTestCase(name: "keeps memory and disk consistent when mutation caller is cancelled") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodexBarCancelledStoreTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TaskStore(persistenceURL: persistenceURL)
            let mutation = Task {
                try await store.apply(event(
                    .userPromptSubmit,
                    session: "cancelled-caller",
                    turn: "1",
                    timestamp: 310,
                    cwd: "/tmp/cancelled-caller"
                ))
            }
            mutation.cancel()

            try expect(try await mutation.value, "cancelled caller left the mutation incomplete")
            let reloadedStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedStore.load()
            try expect(
                reloadedStore.tasks == store.tasks && store.tasks.count == 1,
                "cancelled caller left memory and disk at different revisions"
            )
        },
        CodexBarTestCase(name: "does not delete a task updated after stale cleanup took its snapshot") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodexBarConditionalCleanupTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TaskStore(persistenceURL: persistenceURL)
            _ = try await store.apply(event(.stop, timestamp: 100))
            let staleCandidate = try require(store.tasks.first, "stale candidate is missing")

            _ = try await store.apply(event(
                .userPromptSubmit,
                timestamp: 200,
                prompt: "Now running again"
            ))
            let removedCount = try await store.removeUnchangedTasks(
                [staleCandidate],
                olderThan: Date(timeIntervalSince1970: 150)
            )

            try expect(removedCount == 0, "cleanup removed a task changed after its snapshot")
            try expect(store.tasks.first?.status == .running, "cleanup lost the newer running state")
            try expect(store.tasks.first?.title == "Now running again", "cleanup lost the newer title")
            let reloadedStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedStore.load()
            try expect(
                reloadedStore.tasks == store.tasks,
                "conditional cleanup left the durable snapshot behind published state"
            )
        },
        CodexBarTestCase(name: "removes one task and clears read tasks") {
            let store = TaskStore()
            _ = try await store.apply(event(.userPromptSubmit, session: "read", turn: "1", timestamp: 300, cwd: "/tmp/read"))
            _ = try await store.apply(event(.stop, session: "read", turn: "1", timestamp: 301, cwd: "/tmp/read"))
            try await store.markRead(taskID: "read:1")
            _ = try await store.apply(event(.userPromptSubmit, session: "keep", turn: "1", timestamp: 302, cwd: "/tmp/keep"))
            _ = try await store.apply(event(.userPromptSubmit, session: "remove", turn: "1", timestamp: 303, cwd: "/tmp/remove"))

            try await store.remove(taskID: "remove:1")
            try await store.clearRead()

            try expect(store.tasks.map(\.id) == ["keep:1"], "delete or clear-read removed the wrong tasks")
        },
        CodexBarTestCase(name: "rejects relative event cwd") {
            let store = TaskStore()

            try expect(
                try await !store.apply(event(.userPromptSubmit, timestamp: 400, cwd: "relative/project")),
                "relative cwd was accepted"
            )
            try expect(store.tasks.isEmpty, "relative cwd created a task")
        },
        CodexBarTestCase(name: "quarantines snapshots with duplicate task ids") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarCorruptStoreTests-\(UUID().uuidString)", isDirectory: true)
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let firstStore = TaskStore(persistenceURL: persistenceURL)
            _ = try await firstStore.apply(event(.userPromptSubmit, timestamp: 500))

            var object = try require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: persistenceURL)) as? [String: Any],
                "snapshot is not an object"
            )
            var tasks = try require(object["tasks"] as? [[String: Any]], "snapshot tasks are missing")
            tasks.append(try require(tasks.first, "snapshot task is missing"))
            object["tasks"] = tasks
            try JSONSerialization.data(withJSONObject: object).write(to: persistenceURL)

            let recoveredStore = TaskStore(persistenceURL: persistenceURL)
            await recoveredStore.load()

            try expect(recoveredStore.tasks.isEmpty, "invalid snapshot tasks were loaded")
            let recoveryURL = try require(
                recoveredStore.recoverySnapshotURL,
                "invalid snapshot was not quarantined"
            )
            try expect(FileManager.default.fileExists(atPath: recoveryURL.path), "recovery copy is missing")
            try expect(try await recoveredStore.apply(event(.userPromptSubmit, timestamp: 501)), "store did not recover")
        },
        CodexBarTestCase(name: "quarantines invalid recovery-deletion identifiers") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CodexBarInvalidDeletionTests-\(UUID().uuidString)",
                isDirectory: true
            )
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let firstStore = TaskStore(persistenceURL: persistenceURL)
            _ = try await firstStore.apply(event(.userPromptSubmit, timestamp: 510))

            var object = try require(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: persistenceURL)
                ) as? [String: Any],
                "snapshot is not an object"
            )
            object["deletedTaskTombstones"] = [[
                "taskID": "",
                "deletedAt": "2026-09-01T00:00:00.000Z"
            ]]
            try JSONSerialization.data(withJSONObject: object).write(to: persistenceURL)

            let recoveredStore = TaskStore(persistenceURL: persistenceURL)
            await recoveredStore.load()

            try expect(recoveredStore.tasks.isEmpty, "invalid deletion metadata was loaded")
            try expect(
                recoveredStore.recoverySnapshotURL != nil,
                "invalid deletion metadata was not quarantined"
            )
        },
        CodexBarTestCase(name: "keeps memory unchanged when a mutation cannot persist") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarPersistenceFailureTests-\(UUID().uuidString)", isDirectory: true)
            let persistenceURL = root.appendingPathComponent("tasks.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: root.path
                )
                try? FileManager.default.removeItem(at: root)
            }
            let store = TaskStore(persistenceURL: persistenceURL)
            _ = try await store.apply(event(.stop, timestamp: 600))
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o500)],
                ofItemAtPath: root.path
            )

            var didThrow = false
            do {
                try await store.markRead(taskID: "session-A:turn-1")
            } catch {
                didThrow = true
            }

            try expect(didThrow, "persistence failure was swallowed")
            try expect(store.tasks.first?.isUnread == true, "memory changed despite persistence failure")
        },
        CodexBarTestCase(name: "merges a late prompt without regressing ready state") {
            let store = TaskStore()
            _ = try await store.apply(event(.stop, timestamp: 710))

            try expect(
                try await store.apply(event(.userPromptSubmit, timestamp: 700, prompt: "Late prompt title")),
                "late prompt metadata was discarded"
            )
            let task = try require(store.tasks.first, "task is missing")
            try expect(task.status == .ready, "late prompt regressed task status")
            try expect(task.updatedAt == Date(timeIntervalSince1970: 710), "late prompt regressed update time")
            try expect(task.startedAt == Date(timeIntervalSince1970: 700), "start time was not recovered")
            try expect(task.title == "Late prompt title", "late prompt title was not recovered")
        },
        CodexBarTestCase(name: "collapses duplicate cwd tasks from an older snapshot") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarLegacyStoreTests-\(UUID().uuidString)", isDirectory: true)
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let oldTask = CodexTask(
                id: "old-session:old-turn",
                sessionID: "old-session",
                turnID: "old-turn",
                cwd: "/tmp/project",
                workspaceName: "project",
                title: "Old task",
                status: .ready,
                startedAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 150),
                isUnread: true
            )
            let newTask = CodexTask(
                id: "new-session:new-turn",
                sessionID: "new-session",
                turnID: "new-turn",
                cwd: "/tmp/project",
                workspaceName: "project",
                title: "New task",
                status: .running,
                startedAt: Date(timeIntervalSince1970: 200),
                updatedAt: Date(timeIntervalSince1970: 200),
                isUnread: false
            )
            let snapshot = LegacyTaskStoreSnapshot(
                tasks: [oldTask, newTask],
                appliedEventIDs: ["old-event", "new-event"]
            )
            try JSONEncoder.codexBar.encode(snapshot).write(to: persistenceURL)

            let store = TaskStore(persistenceURL: persistenceURL)
            await store.load()

            try expect(store.tasks.count == 1, "legacy duplicate cwd tasks were not collapsed")
            try expect(store.tasks.first?.id == "new-session:new-turn", "legacy migration kept the old turn")
        },
        CodexBarTestCase(name: "rejects event ids that cannot be persisted") {
            let store = TaskStore()
            let oversizedID = String(repeating: "x", count: 129)
            for identifier in ["", oversizedID] {
                let invalid = CodexHookEvent(
                    id: identifier,
                    sessionID: "session",
                    turnID: "turn",
                    cwd: "/tmp/project-alpha",
                    name: .userPromptSubmit,
                    promptSummary: "Invalid identifier",
                    toolName: nil,
                    timestamp: Date(timeIntervalSince1970: 800),
                    lastAssistantMessagePresent: false
                )
                try expect(try await !store.apply(invalid), "invalid event id was accepted")
            }
            try expect(store.tasks.isEmpty, "invalid event id changed tasks")
        }
    ]
}

private struct LegacyTaskStoreSnapshot: Encodable {
    let tasks: [CodexTask]
    let appliedEventIDs: [String]
}

private func event(
    _ name: CodexHookEventName,
    session: String = "session-A",
    turn: String = "turn-1",
    timestamp: TimeInterval,
    prompt: String? = nil,
    cwd: String = "/tmp/project-alpha"
) -> CodexHookEvent {
    CodexHookEvent(
        id: "\(session)-\(turn)-\(name.rawValue)-\(timestamp)",
        sessionID: session,
        turnID: turn,
        cwd: cwd,
        name: name,
        promptSummary: prompt,
        toolName: nil,
        timestamp: Date(timeIntervalSince1970: timestamp),
        lastAssistantMessagePresent: false
    )
}
