import Foundation
import CodexBarCore

@MainActor
func startupReconciliationTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "recovers multiple explicit folders in one workspace and excludes unrelated same-name history") {
            let store = TaskStore()
            let paths = ["/work/sources/project-alpha", "/work/sources/project-beta"]
            let snapshots = (paths + ["/other/project-alpha"]).enumerated().map { index, cwd in
                startupSnapshot(session: "workspace-session-\(index)", cwd: cwd, updatedAt: 100)
            }
            let windows = [VSCodeWindowDescriptor(
                id: 1, title: "Example-Workspace (Workspace) — Visual Studio Code", workspaceFolderPaths: paths
            )]
            try expect(try await StartupTaskReconciler(store: store).reconcile(
                snapshots: snapshots, windows: windows
            ) == 2, "multi-root workspace did not recover both tasks")
            try expect(Set(store.tasks.map(\.cwd)) == Set(paths), "unrelated same-name history was recovered")
        },
        CodexBarTestCase(name: "shared folder and untitled workspace recover one real task and still reject title ambiguity") {
            let cwd = "/work/project-alpha"
            let windows = [
                VSCodeWindowDescriptor(id: 2, title: "project-alpha", workspaceFolderPaths: [cwd],
                                       workspace: .folder(cwd)),
                VSCodeWindowDescriptor(id: 1, title: "Untitled (Workspace)", workspaceFolderPaths: [cwd],
                                       workspace: .untitledWorkspace("/work/Code/Workspaces/123/workspace.json"))
            ]
            let snapshot = startupSnapshot(updatedAt: 100)
            let store = TaskStore()
            let reconciler = StartupTaskReconciler(store: store)
            try expect(try await reconciler.reconcile(snapshots: [snapshot], windows: windows) == 1,
                       "explicit shared membership was rejected as ambiguous")
            let task = try require(store.tasks.first, "shared member task missing")
            try expect(store.tasks.count == 1 && task.cwd == cwd && task.sessionID == snapshot.sessionID
                       && task.id == "\(snapshot.sessionID):\(snapshot.turnID)",
                       "shared membership duplicated or rewrote the task identity")
            try expect(try await reconciler.reconcile(snapshots: [snapshot], windows: windows.reversed()) == 0,
                       "window enumeration order duplicated a recovered task")
            let uncertainStore = TaskStore()
            let uncertainWindows = windows + [VSCodeWindowDescriptor(id: 3, title: "project-alpha")]
            try expect(try await StartupTaskReconciler(store: uncertainStore).reconcile(
                snapshots: [snapshot], windows: uncertainWindows
            ) == 0, "a title-only candidate made uncertain history recoverable")
            try expect(uncertainStore.tasks.isEmpty, "uncertain shared membership recovered a task")
        },
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
            try expect(store.tasks.count == 1, "closed VS Code threads were recovered")
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
        CodexBarTestCase(name: "keeps a live Hook turn authoritative over persisted history") {
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

            try expect(changed == 0, "persisted history stopped a live Hook turn")
            let task = try require(store.tasks.first, "same-turn task is missing")
            try expect(task.status == .running, "live Hook turn did not remain running")
            try expect(
                task.updatedAt == Date(timeIntervalSince1970: 100.8),
                "rounded App Server time regressed the stored timestamp"
            )
        },
        CodexBarTestCase(name: "does not infer interruption without a Stop Hook") {
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

            try expect(changed == 0, "persisted interruption overrode the live Hook turn")
            try expect(
                store.tasks.first?.status == .running,
                "turn without a Stop Hook did not remain running"
            )
        },
        CodexBarTestCase(name: "does not infer failure without a Stop Hook") {
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

            try expect(changed == 0, "persisted failure overrode the live Hook turn")
            try expect(
                store.tasks.first?.status == .needsAttention,
                "permission turn changed without a Stop Hook"
            )
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
    status: CodexThreadTurnStatus = .completed,
    updatedAt: TimeInterval,
    title: String = "Existing task"
) -> CodexThreadSnapshot {
    CodexThreadSnapshot(
        sessionID: session,
        turnID: turn,
        cwd: cwd,
        title: title,
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
        lastAssistantMessagePresent: false,
        source: .visualStudioCode
    )
}
