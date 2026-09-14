import CodexBarCore
import Foundation

@MainActor
func taskVisibilityTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "closing individual and all windows hides their tasks without deleting state") {
            let tasks = [visibilityTask("alpha"), visibilityTask("beta")]
            var visibility = VSCodeTaskVisibility()
            try expect(visibility.visibleTasks(in: tasks).isEmpty, "unknown inventory displayed historical tasks as open")
            try expect(visibility.visibleRows(in: tasks).isEmpty, "unknown inventory displayed historical rows as open")
            _ = visibility.update(windows: [visibilityWindow("alpha"), visibilityWindow("beta", id: 2)])
            try expect(visibility.visibleTasks(in: tasks) == tasks, "open projects were hidden")
            _ = visibility.update(windows: [visibilityWindow("beta", id: 2)])
            try expect(visibility.visibleTasks(in: tasks) == [tasks[1]], "closed project stayed visible")
            _ = visibility.update(windows: [])
            try expect(visibility.visibleTasks(in: tasks).isEmpty, "closing all windows left stale rows")
            try expect(visibility.visibleRows(in: tasks).isEmpty, "closing all windows left stale root rows")
            try expect(visibility.hasNoOpenWindows, "empty inventory did not select the no-windows state")
            _ = visibility.update(windows: [visibilityWindow("alpha")])
            try expect(visibility.visibleTasks(in: tasks) == [tasks[0]], "reopening lost the original task state")
        },
        CodexBarTestCase(name: "unavailable window reads preserve the last successful inventory") {
            let tasks = [visibilityTask("alpha")]
            var visibility = VSCodeTaskVisibility()
            try expect(!visibility.update(windows: nil), "failed initial scan changed inventory")
            try expect(!visibility.hasNoOpenWindows, "unknown inventory was treated as no windows")
            try expect(visibility.visibleRows(in: tasks).isEmpty, "failed initial scan displayed historical rows")
            _ = visibility.update(windows: [visibilityWindow("alpha")])
            let openRows = visibility.visibleRows(in: tasks)
            try expect(!visibility.update(windows: nil), "failed scan changed open windows")
            try expect(visibility.visibleTasks(in: tasks) == tasks, "AX failure hid an open task")
            try expect(visibility.visibleRows(in: tasks) == openRows, "AX failure changed the last successful rows")
            _ = visibility.update(windows: [])
            _ = visibility.update(windows: nil)
            try expect(visibility.visibleTasks(in: tasks).isEmpty, "AX failure resurrected closed tasks")
        },
        CodexBarTestCase(name: "same-name open windows stay visible and inventory ordering does not trigger recovery") {
            var visibility = VSCodeTaskVisibility()
            let windows = [visibilityWindow("alpha"), visibilityWindow("alpha", id: 2)]
            try expect(visibility.update(windows: windows), "first inventory was ignored")
            try expect(!visibility.update(windows: windows.reversed()), "window order unnecessarily triggered recovery")
            let tasks = [visibilityTask("alpha")]
            try expect(visibility.visibleTasks(in: tasks) == tasks, "ambiguous open project was treated as closed")
            try expect(visibility.visibleRows(in: tasks).map(\.task) == tasks, "ambiguous title matching discarded the task")
        },
        CodexBarTestCase(name: "multi-root workspace presents one named row and retains all live task identities") {
            let tasks = [visibilityTask("project-alpha", cwd: "/work/sources/project-alpha"),
                         visibilityTask("project-gamma", cwd: "/work/sources/project-gamma")]
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: [VSCodeWindowDescriptor(
                id: 1, title: "Welcome — Example-Workspace (Workspace)",
                workspaceFolderPaths: tasks.map(\.cwd),
                workspace: .workspace("/work/Example-Workspace.code-workspace")
            )])
            let rows = visibility.visibleRows(in: tasks)
            try expect(rows.count == 1, "workspace members produced separate rows")
            let row = try require(rows.first, "workspace row missing")
            try expect(row.displayName == "Example-Workspace", "row used member folder name")
            try expect(row.rootPath == "/work/Example-Workspace.code-workspace" && row.isMultiRoot,
                       "row lost its opened workspace identity")
            try expect(row.task == tasks[0], "projection changed the representative task identity")
            try expect(visibility.visibleTasks(in: tasks) == tasks, "projection dropped a live member session")
        },
        CodexBarTestCase(name: "workspace representative follows supplied task priority without changing row identity") {
            let tasks = [visibilityTask("alpha"), visibilityTask("beta")]
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: [VSCodeWindowDescriptor(
                id: 1, title: "Projects (Workspace)", workspaceFolderPaths: tasks.map(\.cwd),
                workspace: .workspace("/work/Projects.code-workspace")
            )])
            let original = try require(visibility.visibleRows(in: tasks).first, "first row missing")
            let reordered = try require(visibility.visibleRows(in: tasks.reversed()).first, "reordered row missing")
            try expect(reordered.task == tasks[1], "representative ignored supplied priority")
            try expect(original.id == reordered.id, "representative update changed root row identity")
        },
        CodexBarTestCase(name: "nested task directories display the opened single folder root") {
            let tasks = [visibilityTask("service", cwd: "/work/project/packages/service"),
                         visibilityTask("web", cwd: "/work/project/packages/web"),
                         visibilityTask("unrelated", cwd: "/work/project-other/packages/service")]
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: [VSCodeWindowDescriptor(
                id: 1, title: "project", workspaceFolderPaths: ["/work/project"],
                workspace: .folder("/work/project")
            )])
            let rows = visibility.visibleRows(in: tasks)
            try expect(rows.count == 1, "nested members were displayed separately")
            let row = try require(rows.first, "opened folder row missing")
            try expect(row.displayName == "project" && row.rootPath == "/work/project" && !row.isMultiRoot,
                       "nested cwd replaced the opened folder identity")
            try expect(row.task == tasks[0], "nested task cwd was rewritten")
            try expect(visibility.visibleTasks(in: tasks) == Array(tasks.prefix(2)),
                       "folder prefix matching included an unrelated root")
        },
        CodexBarTestCase(name: "different opened roots and linked worktrees retain separate rows") {
            let tasks = [visibilityTask("main", cwd: "/work/sample-project"),
                         visibilityTask("graph", cwd: "/work/sample-project-graph-runtime"),
                         visibilityTask("same-name", cwd: "/other/sample-project")]
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: tasks.enumerated().map { index, task in
                VSCodeWindowDescriptor(
                    id: index, title: "sample-project", workspaceFolderPaths: [task.cwd], workspace: .folder(task.cwd)
                )
            })
            let rows = visibility.visibleRows(in: tasks)
            try expect(rows.count == tasks.count, "different paths or worktrees collapsed together")
            try expect(Set(rows.map(\.id)).count == tasks.count, "row identity used a basename")
            try expect(rows.map(\.rootPath) == tasks.map(\.cwd), "root paths changed")
        },
        CodexBarTestCase(name: "closing a multi-root workspace hides every member without deleting tasks") {
            let tasks = [visibilityTask("alpha"), visibilityTask("beta"), visibilityTask("other")]
            let workspace = VSCodeWindowDescriptor(
                id: 1, title: "Projects (Workspace)", workspaceFolderPaths: Array(tasks.prefix(2)).map(\.cwd),
                workspace: .workspace("/work/Projects.code-workspace")
            )
            let otherWindow = VSCodeWindowDescriptor(
                id: 2, title: "other", workspaceFolderPaths: [tasks[2].cwd], workspace: .folder(tasks[2].cwd)
            )
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: [workspace, otherWindow])
            try expect(visibility.visibleRows(in: tasks).count == 2, "initial root rows missing")
            _ = visibility.update(windows: [otherWindow])
            try expect(visibility.visibleRows(in: tasks).map(\.task) == [tasks[2]], "closed workspace row remained")
            try expect(visibility.visibleTasks(in: tasks) == [tasks[2]], "closed member sessions remained live")
            _ = visibility.update(windows: [workspace, otherWindow])
            try expect(visibility.visibleTasks(in: tasks) == tasks, "reopening lost stored members")
        },
        CodexBarTestCase(name: "shared members present both standalone roots and their untitled workspace") {
            let tasks = [visibilityTask("resume"), visibilityTask("project-beta"), visibilityTask("project-gamma")]
            let workspaceIdentity = VSCodeWorkspaceIdentity.untitledWorkspace("/work/Code/Workspaces/123/workspace.json")
            let workspace = VSCodeWindowDescriptor(
                id: 1, title: "Untitled (Workspace)", workspaceFolderPaths: tasks.map(\.cwd),
                workspace: workspaceIdentity
            )
            let folderWindows = tasks.enumerated().map { index, task in
                VSCodeWindowDescriptor(
                    id: index + 2, title: task.workspaceName, workspaceFolderPaths: [task.cwd],
                    workspace: .folder(task.cwd)
                )
            }
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: [workspace] + folderWindows)
            let rows = visibility.visibleRows(in: tasks)
            try expect(rows.count == 4, "shared members lost their workspace or standalone entry")
            let workspaceRow = try require(rows.first(where: { $0.workspace == workspaceIdentity }),
                                           "untitled workspace entry missing")
            try expect(workspaceRow.isMultiRoot && workspaceRow.task == tasks[0],
                       "untitled workspace lost its representative task")
            for task in tasks {
                let row = try require(rows.first(where: { $0.workspace == .folder(task.cwd) }),
                                      "standalone root entry missing")
                try expect(row.task == task, "standalone row used another member task")
            }
            try expect(visibility.visibleTasks(in: tasks) == tasks, "shared membership duplicated underlying tasks")
            let reordered = visibility.visibleRows(in: tasks.reversed())
            let updatedWorkspaceRow = try require(reordered.first(where: { $0.workspace == workspaceIdentity }),
                                                  "reprioritized workspace missing")
            try expect(updatedWorkspaceRow.id == workspaceRow.id && updatedWorkspaceRow.task == tasks[2],
                       "shared workspace representative did not follow priority with a stable row id")
            _ = visibility.update(windows: folderWindows)
            try expect(visibility.visibleRows(in: tasks).count == 3, "closed workspace left an extra row")
            _ = visibility.update(windows: [workspace])
            try expect(visibility.visibleRows(in: tasks).count == 1, "closed standalone roots remained visible")
            try expect(visibility.visibleTasks(in: tasks) == tasks, "workspace closure handling lost member state")
        },
        CodexBarTestCase(name: "duplicate windows for one workspace produce one root row") {
            let tasks = [visibilityTask("alpha"), visibilityTask("beta")]
            let identity = VSCodeWorkspaceIdentity.workspace("/work/Projects.code-workspace")
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: [1, 2].map { id in
                VSCodeWindowDescriptor(
                    id: id, title: "Projects (Workspace)", workspaceFolderPaths: tasks.map(\.cwd), workspace: identity
                )
            })
            let rows = visibility.visibleRows(in: tasks)
            try expect(rows.count == 1, "duplicate workspace windows produced member fallback rows")
            try expect(rows.first?.workspace == identity && rows.first?.task == tasks[0],
                       "duplicate window grouping lost the workspace or task identity")
        },
        CodexBarTestCase(name: "known workspace membership suppresses uncertain duplicate member rows") {
            let task = visibilityTask("alpha")
            let identity = VSCodeWorkspaceIdentity.workspace("/work/Projects.code-workspace")
            var visibility = VSCodeTaskVisibility()
            _ = visibility.update(windows: [
                VSCodeWindowDescriptor(id: 1, title: "Projects (Workspace)",
                                       workspaceFolderPaths: [task.cwd], workspace: identity),
                visibilityWindow("alpha", id: 2), visibilityWindow("alpha", id: 3)
            ])
            let rows = visibility.visibleRows(in: [task])
            try expect(rows.count == 1 && rows.first?.workspace == identity,
                       "uncertain title matches added a member row beside its known workspace")
            _ = visibility.update(windows: [visibilityWindow("alpha", id: 2), visibilityWindow("alpha", id: 3)])
            try expect(visibility.visibleRows(in: [task]).map(\.task) == [task],
                       "unknown same-name windows discarded legacy task visibility")
        },
        CodexBarTestCase(name: "late Hooks stay hidden after closure and explicit deletion survives reopening") {
            let store = TaskStore()
            var visibility = VSCodeTaskVisibility()
            let event = CodexHookEvent(
                id: "visibility-stop", sessionID: "session", turnID: "turn", cwd: "/work/alpha",
                name: .stop, promptSummary: nil, toolName: nil,
                timestamp: Date(timeIntervalSince1970: 100), lastAssistantMessagePresent: false,
                source: .visualStudioCode
            )
            _ = visibility.update(windows: [])
            _ = try await store.apply(event)
            try expect(store.tasks.count == 1, "Hook state was not retained")
            try expect(visibility.visibleTasks(in: store.tasks).isEmpty, "late Hook reopened a closed project")
            _ = visibility.update(windows: [visibilityWindow("alpha")])
            let task = try require(visibility.visibleTasks(in: store.tasks).first, "reopened task is missing")
            try expect(task.status == .ready && task.isUnread, "reopening changed Hook state")
            _ = try await store.remove(taskID: task.id)
            _ = visibility.update(windows: [])
            _ = visibility.update(windows: [visibilityWindow("alpha")])
            _ = try await store.apply(event)
            try expect(visibility.visibleTasks(in: store.tasks).isEmpty, "explicitly deleted task was restored")
        }
    ]
}

private func visibilityWindow(_ name: String, id: Int = 1) -> VSCodeWindowDescriptor {
    VSCodeWindowDescriptor(id: id, title: "\(name) — Visual Studio Code")
}

private func visibilityTask(_ name: String, cwd: String? = nil) -> CodexTask {
    CodexTask(
        id: name, sessionID: name, turnID: "turn", cwd: cwd ?? "/work/\(name)",
        workspaceName: name, title: name, status: .ready,
        startedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100),
        isUnread: true
    )
}
