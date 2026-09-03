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
        CodexBarTestCase(name: "keeps PreToolUse out of durable task state") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarTransientActivityTests-\(UUID().uuidString)", isDirectory: true)
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TaskStore(persistenceURL: persistenceURL)
            _ = try await store.apply(event(
                .userPromptSubmit,
                timestamp: 100,
                prompt: "Keep lifecycle stable"
            ))
            let taskBefore = try require(store.tasks.first, "running task is missing")
            let snapshotBefore = try Data(contentsOf: persistenceURL)
            let activity = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "tool-read-1",
                timestamp: 110,
                toolInput: ["file_path": "/tmp/project-alpha/TaskStore.swift"]
            )

            try expect(try await !store.apply(activity), "TaskStore applied a transient activity")

            let taskAfter = try require(store.tasks.first, "activity removed the running task")
            try expect(taskAfter.status == taskBefore.status, "activity changed task status")
            try expect(taskAfter.updatedAt == taskBefore.updatedAt, "activity changed task update time")
            try expect(taskAfter.isUnread == taskBefore.isUnread, "activity changed unread state")
            try expect(
                try Data(contentsOf: persistenceURL) == snapshotBefore,
                "activity changed the durable task snapshot"
            )
        },
        CodexBarTestCase(name: "records activity only for the exact active turn") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let beforeStart = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "before-start",
                timestamp: 90,
                toolInput: ["file_path": "/tmp/project-alpha/Before.swift"]
            )
            try expect(
                !activityStore.apply(beforeStart, deliveryID: "delivery-before", currentTasks: []),
                "activity without an existing task was accepted"
            )

            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Trace this turn")
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)

            let wrongSession = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "wrong-session",
                session: "session-B",
                timestamp: 101,
                toolInput: ["file_path": "/tmp/project-alpha/WrongSession.swift"]
            )
            let wrongTurn = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "wrong-turn",
                turn: "turn-2",
                timestamp: 102,
                toolInput: ["file_path": "/tmp/project-alpha/WrongTurn.swift"]
            )
            try expect(
                !activityStore.apply(
                    wrongSession,
                    deliveryID: "delivery-wrong-session",
                    currentTasks: taskStore.tasks
                ),
                "activity from another session was accepted"
            )
            try expect(
                !activityStore.apply(
                    wrongTurn,
                    deliveryID: "delivery-wrong-turn",
                    currentTasks: taskStore.tasks
                ),
                "activity from another turn was accepted"
            )

            let matching = try parsedActivityEvent(
                toolName: "apply_patch",
                toolUseID: "matching",
                timestamp: 103,
                toolInput: [
                    "command": "*** Begin Patch\n*** Update File: /tmp/project-alpha/TaskStore.swift\n*** End Patch"
                ]
            )
            try expect(
                activityStore.apply(
                    matching,
                    deliveryID: "delivery-matching",
                    currentTasks: taskStore.tasks
                ),
                "activity from the active turn was ignored"
            )

            let task = try require(taskStore.tasks.first, "active task is missing")
            let node = try require(activityStore.nodes(for: task).first, "activity node is missing")
            try expect(activityStore.nodes(for: task).count == 1, "unmatched activities were retained")
            try expect(node.kind == .edit, "apply_patch was not classified as an edit")
            try expect(node.summary == "修改 TaskStore.swift", "edit summary is not useful")
            try expect(
                node.occurredAt == Date(timeIntervalSince1970: 103),
                "activity node timestamp is wrong"
            )
        },
        CodexBarTestCase(name: "revalidates an activity summary loaded from disk") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Validate activity")
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)
            let injected = CodexHookEvent(
                id: "event-injected",
                sessionID: "session-A",
                turnID: "turn-1",
                cwd: "/tmp/project-alpha",
                name: .preToolUse,
                promptSummary: nil,
                toolName: "Read",
                timestamp: Date(timeIntervalSince1970: 101),
                lastAssistantMessagePresent: false,
                activity: CodexHookActivitySummary(
                    kind: .read,
                    safeSubject: "secret=example-private-value\u{202E}File.swift"
                )
            )

            _ = activityStore.apply(
                injected,
                deliveryID: "delivery-injected",
                currentTasks: taskStore.tasks
            )

            let task = try require(taskStore.tasks.first, "active task is missing")
            let summary = try require(activityStore.nodes(for: task).first?.summary, "summary is missing")
            try expect(!summary.contains("example-private-value"), "injected secret reached the UI")
            try expect(!summary.contains("\u{202E}"), "injected bidi control reached the UI")
        },
        CodexBarTestCase(name: "keeps three nodes and replaces adjacent activity kinds") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Bound the activity trace")
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)
            let firstRead = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "read-a",
                timestamp: 101,
                toolInput: ["file_path": "/tmp/project-alpha/A.swift"]
            )
            let secondRead = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "read-b",
                timestamp: 102,
                toolInput: ["file_path": "/tmp/project-alpha/B.swift"]
            )
            _ = activityStore.apply(firstRead, deliveryID: "delivery-read-a", currentTasks: taskStore.tasks)
            _ = activityStore.apply(secondRead, deliveryID: "delivery-read-b", currentTasks: taskStore.tasks)

            let task = try require(taskStore.tasks.first, "active task is missing")
            let mergedReads = activityStore.nodes(for: task)
            try expect(mergedReads.count == 1, "adjacent read nodes were not merged")
            try expect(mergedReads.first?.summary == "读取 B.swift", "newest read did not replace the older read")
            try expect(
                mergedReads.first?.occurredAt == Date(timeIntervalSince1970: 102),
                "merged read kept the older timestamp"
            )

            let search = try parsedActivityEvent(
                toolName: "Grep",
                toolUseID: "search",
                timestamp: 103,
                toolInput: ["pattern": "CodexTask", "path": "/tmp/project-alpha/Sources"]
            )
            let edit = try parsedActivityEvent(
                toolName: "apply_patch",
                toolUseID: "edit",
                timestamp: 104,
                toolInput: [
                    "command": "*** Begin Patch\n*** Update File: /tmp/project-alpha/C.swift\n*** End Patch"
                ]
            )
            let command = try parsedActivityEvent(
                toolName: "Bash",
                toolUseID: "command",
                timestamp: 105,
                toolInput: ["command": "git status --short"]
            )
            for (deliveryID, activity) in [
                ("delivery-search", search),
                ("delivery-edit", edit),
                ("delivery-command", command)
            ] {
                try expect(
                    activityStore.apply(
                        activity,
                        deliveryID: deliveryID,
                        currentTasks: taskStore.tasks
                    ),
                    "activity \(deliveryID) was ignored"
                )
            }

            let nodes = activityStore.nodes(for: task)
            try expect(nodes.count == 3, "activity trace exceeded or missed its three-node bound")
            try expect(
                nodes.map(\.kind) == [.search, .edit, .command],
                "activity nodes are not chronological or did not drop the oldest node"
            )
            try expect(
                nodes.map(\.occurredAt) == [103, 104, 105].map(Date.init(timeIntervalSince1970:)),
                "activity node timestamps are not chronological"
            )
        },
        CodexBarTestCase(name: "freezes nodes at Stop and ignores late activity") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Finish with a trace")
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)
            let read = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "read-before-stop",
                timestamp: 101,
                toolInput: ["file_path": "/tmp/project-alpha/BeforeStop.swift"]
            )
            _ = activityStore.apply(read, deliveryID: "delivery-read", currentTasks: taskStore.tasks)

            let stop = event(.stop, timestamp: 102)
            _ = try await taskStore.apply(stop)
            _ = activityStore.apply(stop, deliveryID: "delivery-stop", currentTasks: taskStore.tasks)
            let completedTask = try require(taskStore.tasks.first, "completed task is missing")
            let frozenNodes = activityStore.nodes(for: completedTask)
            let lateActivity = try parsedActivityEvent(
                toolName: "Bash",
                toolUseID: "late-command",
                timestamp: 103,
                toolInput: ["command": "git status --short"]
            )

            try expect(
                !activityStore.apply(
                    lateActivity,
                    deliveryID: "delivery-late",
                    currentTasks: taskStore.tasks
                ),
                "activity arriving after Stop was accepted"
            )
            try expect(activityStore.nodes(for: completedTask) == frozenNodes, "late activity changed frozen nodes")
        },
        CodexBarTestCase(name: "keeps activity when a continued turn stops with a new turn id") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let start = event(
                .userPromptSubmit,
                session: "same-session",
                turn: "initial-turn",
                timestamp: 100,
                prompt: "Finish with a continued turn"
            )
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)
            let edit = try parsedActivityEvent(
                toolName: "apply_patch",
                toolUseID: "edit-before-stop",
                session: "same-session",
                turn: "initial-turn",
                timestamp: 110,
                toolInput: [
                    "command": "*** Begin Patch\n*** Update File: /tmp/project-alpha/Continued.swift\n*** End Patch"
                ]
            )
            _ = activityStore.apply(edit, deliveryID: "delivery-edit", currentTasks: taskStore.tasks)

            let stop = event(
                .stop,
                session: "same-session",
                turn: "continued-turn",
                timestamp: 120
            )
            _ = try await taskStore.apply(stop)
            _ = activityStore.apply(stop, deliveryID: "delivery-stop", currentTasks: taskStore.tasks)

            let completedTask = try require(taskStore.tasks.first, "continued task is missing")
            let node = try require(
                activityStore.nodes(for: completedTask).first,
                "continued stop discarded the activity trace"
            )
            try expect(completedTask.turnID == "continued-turn", "test did not exercise a continued turn")
            try expect(node.summary == "修改 Continued.swift", "continued trace changed during migration")
        },
        CodexBarTestCase(name: "freezes activity when recovery marks a task ready") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Recover this turn")
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)
            let read = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "read-before-recovery",
                timestamp: 110,
                toolInput: ["file_path": "/tmp/project-alpha/BeforeRecovery.swift"]
            )
            _ = activityStore.apply(read, deliveryID: "delivery-read", currentTasks: taskStore.tasks)

            _ = try await taskStore.apply(event(.stop, timestamp: 120))
            activityStore.synchronize(with: taskStore.tasks)
            let recoveredTask = try require(taskStore.tasks.first, "recovered task is missing")
            let nodesBeforeLateEvent = activityStore.nodes(for: recoveredTask)
            let late = try parsedActivityEvent(
                toolName: "Bash",
                toolUseID: "late-after-recovery",
                timestamp: 130,
                toolInput: ["command": "git status --short"]
            )

            try expect(
                !activityStore.apply(
                    late,
                    deliveryID: "delivery-late",
                    currentTasks: taskStore.tasks
                ),
                "late activity changed a task completed by recovery"
            )
            try expect(
                activityStore.nodes(for: recoveredTask) == nodesBeforeLateEvent,
                "recovery-completed task did not freeze its trace"
            )
        },
        CodexBarTestCase(name: "clears activity when a new turn replaces the task") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let firstStart = event(.userPromptSubmit, timestamp: 100, prompt: "First turn")
            _ = try await taskStore.apply(firstStart)
            _ = activityStore.apply(
                firstStart,
                deliveryID: "delivery-first-start",
                currentTasks: taskStore.tasks
            )
            let activity = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "first-read",
                timestamp: 101,
                toolInput: ["file_path": "/tmp/project-alpha/FirstTurn.swift"]
            )
            _ = activityStore.apply(activity, deliveryID: "delivery-first-read", currentTasks: taskStore.tasks)
            let oldTask = try require(taskStore.tasks.first, "first task is missing")
            try expect(!activityStore.nodes(for: oldTask).isEmpty, "first turn has no activity to clear")

            let secondStart = event(
                .userPromptSubmit,
                session: "session-B",
                turn: "turn-2",
                timestamp: 200,
                prompt: "Second turn"
            )
            _ = try await taskStore.apply(secondStart)
            _ = activityStore.apply(
                secondStart,
                deliveryID: "delivery-second-start",
                currentTasks: taskStore.tasks
            )

            let newTask = try require(taskStore.tasks.first, "replacement task is missing")
            try expect(activityStore.nodes(for: oldTask).isEmpty, "replaced turn remained in memory")
            try expect(activityStore.nodes(for: newTask).isEmpty, "new turn inherited old activity")
        },
        CodexBarTestCase(name: "does not restore activity after reload") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarActivityReloadTests-\(UUID().uuidString)", isDirectory: true)
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let taskStore = TaskStore(persistenceURL: persistenceURL)
            let activityStore = LiveTaskActivityStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Keep only the task")
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)
            let activity = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "reload-read",
                timestamp: 101,
                toolInput: ["file_path": "/tmp/project-alpha/TransientOnly.swift"]
            )
            _ = activityStore.apply(activity, deliveryID: "delivery-read", currentTasks: taskStore.tasks)
            let task = try require(taskStore.tasks.first, "persisted task is missing")
            try expect(!activityStore.nodes(for: task).isEmpty, "live activity was not captured")
            let snapshot = String(decoding: try Data(contentsOf: persistenceURL), as: UTF8.self)
            try expect(!snapshot.contains("TransientOnly.swift"), "activity leaked into tasks.json")

            let reloadedTaskStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedTaskStore.load()
            let reloadedActivityStore = LiveTaskActivityStore()
            let reloadedTask = try require(reloadedTaskStore.tasks.first, "task did not reload")
            try expect(
                reloadedActivityStore.nodes(for: reloadedTask).isEmpty,
                "activity survived a LiveTaskActivityStore reload"
            )
        },
        CodexBarTestCase(name: "drops activity as soon as its task is removed") {
            let taskStore = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let start = event(.userPromptSubmit, timestamp: 100, prompt: "Remove this trace")
            _ = try await taskStore.apply(start)
            _ = activityStore.apply(start, deliveryID: "delivery-start", currentTasks: taskStore.tasks)
            let read = try parsedActivityEvent(
                toolName: "Read",
                toolUseID: "read-before-remove",
                timestamp: 101,
                toolInput: ["file_path": "/tmp/project-alpha/Removed.swift"]
            )
            _ = activityStore.apply(read, deliveryID: "delivery-read", currentTasks: taskStore.tasks)
            let removedTask = try require(taskStore.tasks.first, "task is missing before removal")

            _ = try await taskStore.remove(taskID: removedTask.id)
            activityStore.synchronize(with: taskStore.tasks)

            try expect(activityStore.nodes(for: removedTask).isEmpty, "removed task kept its activity")
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

private func parsedActivityEvent(
    toolName: String,
    toolUseID: String,
    session: String = "session-A",
    turn: String = "turn-1",
    timestamp: TimeInterval,
    cwd: String = "/tmp/project-alpha",
    toolInput: [String: Any]
) throws -> CodexHookEvent {
    let input = try JSONSerialization.data(withJSONObject: [
        "session_id": session,
        "turn_id": turn,
        "cwd": cwd,
        "hook_event_name": "PreToolUse",
        "tool_name": toolName,
        "tool_use_id": toolUseID,
        "tool_input": toolInput,
        "timestamp": timestamp
    ])
    return try CodexHookEventParser(
        now: { Date(timeIntervalSince1970: timestamp) }
    ).parse(input)
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
