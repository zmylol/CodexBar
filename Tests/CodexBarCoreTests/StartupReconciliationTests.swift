import Foundation
import CodexBarCore

@MainActor
func startupReconciliationTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "recovers the latest VS Code turn for an already-open workspace") {
            let store = TaskStore()
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "notes — Visual Studio Code")
            ]
            let snapshots = [
                startupSnapshot(
                    session: "old-session",
                    turn: "old-turn",
                    updatedAt: 100,
                    title: "Old task"
                ),
                startupSnapshot(
                    session: "latest-session",
                    turn: "latest-turn",
                    updatedAt: 200,
                    title: "Existing task"
                ),
                startupSnapshot(
                    session: "closed-session",
                    turn: "closed-turn",
                    cwd: "/work/closed",
                    updatedAt: 300,
                    title: "Closed task"
                ),
                startupSnapshot(
                    session: "cli-session",
                    turn: "cli-turn",
                    source: .cli,
                    updatedAt: 400,
                    title: "CLI task"
                ),
                startupSnapshot(
                    session: "future-session",
                    turn: "future-turn",
                    cwd: "/work/notes",
                    updatedAt: Date().addingTimeInterval(8 * 24 * 60 * 60).timeIntervalSince1970,
                    title: "Future task"
                )
            ]

            let reconciler = StartupTaskReconciler(store: store)
            try expect(
                try await reconciler.reconcile(snapshots: snapshots, windows: windows) == 1,
                "startup recovery did not add exactly one task"
            )

            let task = try require(store.tasks.first, "recovered task is missing")
            try expect(store.tasks.count == 1, "closed or non-VS-Code threads were recovered")
            try expect(task.id == "latest-session:latest-turn", "latest VS Code turn was not selected")
            try expect(task.cwd == "/work/project-alpha", "recovered cwd is wrong")
            try expect(task.title == "Existing task", "recovered title is wrong")
            try expect(task.status == .ready, "completed turn did not become ready")
            try expect(!task.isUnread, "historical recovery should not create an unread alert")
            try expect(
                try await reconciler.reconcile(snapshots: snapshots, windows: windows) == 0,
                "repeated startup recovery was not idempotent"
            )
            try expect(store.tasks.count == 1, "repeated startup recovery duplicated the task")
        },
        CodexBarTestCase(name: "keeps an existing Hook task authoritative during startup recovery") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .permissionRequest,
                session: "hook-session",
                turn: "hook-turn",
                timestamp: 100,
                cwd: "/work/project-alpha"
            ))
            let snapshot = startupSnapshot(
                session: "hook-session",
                turn: "hook-turn",
                status: .inProgress,
                updatedAt: 500,
                title: "Snapshot task"
            )

            let added = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [snapshot],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(added == 0, "startup recovery overwrote an existing Hook task")
            let task = try require(store.tasks.first, "Hook task is missing")
            try expect(store.tasks.count == 1, "startup recovery duplicated an existing cwd")
            try expect(task.id == "hook-session:hook-turn", "startup recovery replaced the Hook turn")
            try expect(task.status == .needsAttention, "startup recovery regressed Hook status")
        },
        CodexBarTestCase(name: "replaces an old permission row when a newer turn exists") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .permissionRequest,
                session: "old-session",
                turn: "old-turn",
                timestamp: 100,
                cwd: "/work/project-alpha"
            ))

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "new-session",
                    turn: "new-turn",
                    status: .inProgress,
                    updatedAt: 500,
                    title: "New persisted task"
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(changed == 1, "new turn remained blocked by an old permission row")
            let task = try require(store.tasks.first, "new persisted turn is missing")
            try expect(task.id == "new-session:new-turn", "old permission turn was not replaced")
            try expect(task.status == .running, "new persisted turn did not become running")
        },
        CodexBarTestCase(name: "lets a later Hook turn take over a recovered startup task") {
            let store = TaskStore()
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")
            ]
            _ = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(updatedAt: 100)],
                windows: windows
            )

            try expect(try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "hook-session",
                turn: "hook-turn",
                timestamp: 200,
                cwd: "/work/project-alpha",
                prompt: "New live task"
            )), "later Hook turn was not applied")

            let task = try require(store.tasks.first, "live Hook task is missing")
            try expect(store.tasks.count == 1, "Hook takeover duplicated the recovered cwd")
            try expect(task.id == "hook-session:hook-turn", "Hook did not replace the recovered turn")
            try expect(task.title == "New live task", "Hook title did not replace the recovered title")
            try expect(task.status == .running, "Hook takeover did not become running")
        },
        CodexBarTestCase(name: "replaces a stale stopped row with a newer persisted turn") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .stop,
                session: "old-session",
                turn: "old-turn",
                timestamp: 100,
                cwd: "/work/project-alpha"
            ))

            let added = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "new-session",
                    turn: "new-turn",
                    status: .inProgress,
                    updatedAt: 200,
                    title: "New persisted task"
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(added == 1, "newer persisted turn did not replace the stale row")
            let task = try require(store.tasks.first, "newer persisted task is missing")
            try expect(store.tasks.count == 1, "newer persisted turn duplicated the cwd")
            try expect(task.id == "new-session:new-turn", "stale turn remained after recovery")
            try expect(task.status == .running, "new active turn did not become running")
        },
        CodexBarTestCase(name: "advances the same turn when App Server time is rounded down") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "same-session",
                turn: "same-turn",
                timestamp: 100.8,
                cwd: "/work/project-alpha"
            ))

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "same-session",
                    turn: "same-turn",
                    status: .completed,
                    updatedAt: 100,
                    title: "Completed task"
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(changed == 1, "rounded App Server time blocked a completed status")
            let task = try require(store.tasks.first, "same-turn task is missing")
            try expect(task.status == .ready, "same turn did not advance from running to ready")
            try expect(
                task.updatedAt == Date(timeIntervalSince1970: 100.8),
                "rounded App Server time regressed the stored timestamp"
            )
        },
        CodexBarTestCase(name: "marks an interrupted turn ready when no Stop Hook arrives") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "interrupted-session",
                turn: "interrupted-turn",
                timestamp: 100.8,
                cwd: "/work/project-alpha",
                prompt: "Interrupted task"
            ))
            try expect(
                store.tasks.first?.status == .running,
                "test setup did not create a running Hook task"
            )

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "interrupted-session",
                    turn: "interrupted-turn",
                    status: .interrupted,
                    updatedAt: 101,
                    title: "Interrupted snapshot"
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(changed == 1, "interrupted App Server turn was ignored")
            try expect(
                store.tasks.first?.status == .ready,
                "turn without a Stop Hook remained running after interruption"
            )
        },
        CodexBarTestCase(name: "marks a failed permission turn ready when no Stop Hook arrives") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "failed-session",
                turn: "failed-turn",
                timestamp: 100,
                cwd: "/work/project-alpha",
                prompt: "Failed task"
            ))
            _ = try await store.apply(startupEvent(
                .permissionRequest,
                session: "failed-session",
                turn: "failed-turn",
                timestamp: 100.5,
                cwd: "/work/project-alpha"
            ))
            try expect(
                store.tasks.first?.status == .needsAttention,
                "test setup did not create a permission task"
            )

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "failed-session",
                    turn: "failed-turn",
                    status: .failed,
                    updatedAt: 101,
                    title: "Failed snapshot"
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(changed == 1, "failed App Server turn was ignored")
            try expect(
                store.tasks.first?.status == .ready,
                "failed permission turn remained blocked without a Stop Hook"
            )
        },
        CodexBarTestCase(name: "marks a terminal CLI turn ready and unread without VS Code windows") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "cli-session",
                turn: "cli-turn",
                timestamp: 100.8,
                cwd: "/work/terminal",
                prompt: "Terminal task"
            ))
            let taskID = try require(store.tasks.first?.id, "CLI task id is missing")

            let changed = try await StartupTaskReconciler(store: store).reconcileActiveTasks(
                snapshots: [startupSnapshot(
                    session: "cli-session",
                    turn: "cli-turn",
                    cwd: "/work/terminal",
                    source: .cli,
                    status: .interrupted,
                    updatedAt: 101,
                    title: "Terminal task"
                )],
                matchingExistingTaskIDs: [taskID]
            )

            try expect(changed == 1, "terminal CLI interruption was ignored")
            let task = try require(store.tasks.first, "CLI task disappeared")
            try expect(task.status == .ready, "terminal CLI task remained running")
            try expect(task.isUnread, "real-time recovered CLI completion was marked read")
        },
        CodexBarTestCase(name: "periodic recovery does not restore a deleted active row") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "deleted-session",
                turn: "deleted-turn",
                timestamp: 100,
                cwd: "/work/project-alpha"
            ))
            let taskID = try require(store.tasks.first?.id, "active task id is missing")
            _ = try await store.remove(taskID: taskID)

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "deleted-session",
                    turn: "deleted-turn",
                    status: .interrupted,
                    updatedAt: 101
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")],
                matchingExistingTaskIDs: [taskID]
            )

            try expect(changed == 0, "periodic recovery restored a deleted task")
            try expect(store.tasks.isEmpty, "deleted task reappeared after periodic recovery")
        },
        CodexBarTestCase(name: "persists deletion across forced startup recovery") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CodexBarDeletedRecoveryTests-\(UUID().uuidString)",
                isDirectory: true
            )
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }

            let firstStore = TaskStore(persistenceURL: persistenceURL)
            _ = try await firstStore.apply(startupEvent(
                .userPromptSubmit,
                session: "deleted-session",
                turn: "deleted-turn",
                timestamp: 100,
                cwd: "/work/project-alpha"
            ))
            let taskID = try require(firstStore.tasks.first?.id, "deleted task id is missing")
            _ = try await firstStore.remove(taskID: taskID)

            let staleSnapshot = startupSnapshot(
                session: "deleted-session",
                turn: "deleted-turn",
                status: .inProgress,
                updatedAt: 101
            )
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")
            ]
            try expect(
                try await StartupTaskReconciler(store: firstStore).reconcile(
                    snapshots: [staleSnapshot],
                    windows: windows
                ) == 0,
                "an already queued recovery restored a deleted task"
            )

            let reloadedStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedStore.load()
            try expect(
                try await StartupTaskReconciler(store: reloadedStore).reconcile(
                    snapshots: [staleSnapshot],
                    windows: windows
                ) == 0,
                "forced recovery restored a task after restart"
            )
            try expect(reloadedStore.tasks.isEmpty, "deleted task reappeared after restart")

            try expect(try await !reloadedStore.apply(startupEvent(
                .stop,
                session: "deleted-session",
                turn: "deleted-turn",
                timestamp: 200,
                cwd: "/work/project-alpha"
            )), "a later Hook event recreated the explicitly deleted turn")
            try expect(reloadedStore.tasks.isEmpty, "deleted turn reappeared from a later Hook")

            try expect(try await reloadedStore.apply(startupEvent(
                .userPromptSubmit,
                session: "new-session",
                turn: "new-turn",
                timestamp: 201,
                cwd: "/work/project-alpha",
                prompt: "New live activity"
            )), "a different live turn was blocked by the old deletion")
            try expect(
                reloadedStore.tasks.first?.id == "new-session:new-turn"
                    && reloadedStore.tasks.first?.status == .running,
                "a different live turn did not appear after the old deletion"
            )
        },
        CodexBarTestCase(name: "persists clear-read and stale-cleanup deletions") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CodexBarBulkDeletionTests-\(UUID().uuidString)",
                isDirectory: true
            )
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = TaskStore(persistenceURL: persistenceURL)

            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "read-session",
                turn: "read-turn",
                timestamp: 100,
                cwd: "/work/read"
            ))
            _ = try await store.apply(startupEvent(
                .stop,
                session: "read-session",
                turn: "read-turn",
                timestamp: 101,
                cwd: "/work/read"
            ))
            _ = try await store.markRead(taskID: "read-session:read-turn")
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "stale-session",
                turn: "stale-turn",
                timestamp: 100,
                cwd: "/work/stale"
            ))
            let staleCandidate = try require(
                store.tasks.first(where: { $0.id == "stale-session:stale-turn" }),
                "stale cleanup candidate is missing"
            )

            try expect(try await store.clearRead() == 1, "clear-read removed the wrong count")
            try expect(
                try await store.removeUnchangedTasks(
                    [staleCandidate],
                    olderThan: Date(timeIntervalSince1970: 150)
                ) == 1,
                "stale cleanup removed the wrong count"
            )
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "live-session",
                turn: "live-turn",
                timestamp: 200,
                cwd: "/work/live"
            ))

            let reloadedStore = TaskStore(persistenceURL: persistenceURL)
            await reloadedStore.load()
            let changed = try await StartupTaskReconciler(store: reloadedStore).reconcile(
                snapshots: [
                    startupSnapshot(
                        session: "read-session",
                        turn: "read-turn",
                        cwd: "/work/read",
                        status: .completed,
                        updatedAt: 300
                    ),
                    startupSnapshot(
                        session: "stale-session",
                        turn: "stale-turn",
                        cwd: "/work/stale",
                        status: .inProgress,
                        updatedAt: 301
                    )
                ],
                windows: [
                    VSCodeWindowDescriptor(id: 1, title: "read — Visual Studio Code"),
                    VSCodeWindowDescriptor(id: 2, title: "stale — Visual Studio Code")
                ]
            )

            try expect(changed == 0, "bulk-deleted tasks were recovered after restart")
            try expect(
                reloadedStore.tasks.map(\.id) == ["live-session:live-turn"],
                "a later persisted mutation lost deletion records"
            )
        },
        CodexBarTestCase(name: "periodic recovery cannot overwrite a replacement Hook turn") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "old-session",
                turn: "old-turn",
                timestamp: 100,
                cwd: "/work/project-alpha"
            ))
            let oldTaskID = try require(store.tasks.first?.id, "old active task id is missing")
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "new-session",
                turn: "new-turn",
                timestamp: 200,
                cwd: "/work/project-alpha"
            ))

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "old-session",
                    turn: "old-turn",
                    status: .interrupted,
                    updatedAt: 300
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")],
                matchingExistingTaskIDs: [oldTaskID]
            )

            try expect(changed == 0, "old periodic snapshot overwrote a replacement turn")
            try expect(
                store.tasks.first?.id == "new-session:new-turn"
                    && store.tasks.first?.status == .running,
                "replacement Hook turn did not remain running"
            )
        },
        CodexBarTestCase(name: "does not let an older completed snapshot stop a newer Hook turn") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .userPromptSubmit,
                session: "same-session",
                turn: "same-turn",
                timestamp: 200.8,
                cwd: "/work/project-alpha"
            ))

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [startupSnapshot(
                    session: "same-session",
                    turn: "same-turn",
                    status: .completed,
                    updatedAt: 100,
                    title: "Stale completed task"
                )],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(changed == 0, "older recovery snapshot overwrote a newer Hook event")
            try expect(
                store.tasks.first?.status == .running,
                "older recovery snapshot stopped a newer running task"
            )
        },
        CodexBarTestCase(name: "orders different turns that start in the same whole second") {
            let store = TaskStore()
            _ = try await store.apply(startupEvent(
                .stop,
                session: "a-old-session",
                turn: "old-turn",
                timestamp: 100.8,
                cwd: "/work/project-alpha"
            ))
            let snapshot = CodexThreadSnapshot(
                sessionID: "z-new-session",
                turnID: "new-turn",
                cwd: "/work/project-alpha",
                title: "Same-second new turn",
                source: .vscode,
                status: .inProgress,
                startedAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 100)
            )

            let changed = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: [snapshot],
                windows: [VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")]
            )

            try expect(changed == 1, "whole-second tie blocked the newer turn")
            try expect(
                store.tasks.first?.id == "z-new-session:new-turn",
                "stable same-second turn ordering kept the older task"
            )
            try expect(try await store.apply(startupEvent(
                .permissionRequest,
                session: "z-new-session",
                turn: "new-turn",
                timestamp: 100.5,
                cwd: "/work/project-alpha"
            )), "new turn inherited an old timestamp and rejected its permission event")
            try expect(
                store.tasks.first?.status == .needsAttention,
                "new turn permission event did not take precedence"
            )
        },
        CodexBarTestCase(name: "recovers active and terminal turns but skips ambiguous history") {
            let store = TaskStore()
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "active — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "interrupted — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 3, title: "project — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 4, title: "completed — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 5, title: "failed — Visual Studio Code")
            ]
            let snapshots = [
                startupSnapshot(
                    session: "active-session",
                    turn: "active-turn",
                    cwd: "/work/active",
                    status: .inProgress,
                    updatedAt: 100
                ),
                startupSnapshot(
                    session: "interrupted-session",
                    turn: "interrupted-turn",
                    cwd: "/work/interrupted",
                    status: .interrupted,
                    updatedAt: 101
                ),
                startupSnapshot(
                    session: "completed-session",
                    turn: "completed-turn",
                    cwd: "/work/completed",
                    status: .completed,
                    updatedAt: 102
                ),
                startupSnapshot(
                    session: "failed-session",
                    turn: "failed-turn",
                    cwd: "/work/failed",
                    status: .failed,
                    updatedAt: 103
                ),
                startupSnapshot(
                    session: "ambiguous-a",
                    turn: "turn-a",
                    cwd: "/one/project",
                    updatedAt: 104
                ),
                startupSnapshot(
                    session: "ambiguous-b",
                    turn: "turn-b",
                    cwd: "/two/project",
                    updatedAt: 105
                )
            ]

            _ = try await StartupTaskReconciler(store: store).reconcile(
                snapshots: snapshots,
                windows: windows
            )

            try expect(
                store.tasks.count == 4,
                "terminal turns were skipped or ambiguous history was recovered"
            )
            try expect(
                store.tasks.first(where: { $0.cwd == "/work/active" })?.status == .running,
                "in-progress snapshot did not become running"
            )
            try expect(
                store.tasks.first(where: { $0.cwd == "/work/completed" })?.status == .ready,
                "completed snapshot did not become ready"
            )
            try expect(
                store.tasks.first(where: { $0.cwd == "/work/interrupted" })?.status == .ready,
                "interrupted snapshot did not become ready"
            )
            try expect(
                store.tasks.first(where: { $0.cwd == "/work/failed" })?.status == .ready,
                "failed snapshot did not become ready"
            )
        }
    ]
}

private func startupSnapshot(
    session: String = "snapshot-session",
    turn: String = "snapshot-turn",
    cwd: String = "/work/project-alpha",
    source: CodexThreadSource = .vscode,
    status: CodexThreadTurnStatus = .completed,
    updatedAt: TimeInterval,
    title: String = "Existing task"
) -> CodexThreadSnapshot {
    CodexThreadSnapshot(
        sessionID: session,
        turnID: turn,
        cwd: cwd,
        title: title,
        source: source,
        status: status,
        startedAt: Date(timeIntervalSince1970: updatedAt - 10),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

private func startupEvent(
    _ name: CodexHookEventName,
    session: String,
    turn: String,
    timestamp: TimeInterval,
    cwd: String,
    prompt: String? = nil
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
