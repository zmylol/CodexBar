import CodexBarCore
import Foundation

@MainActor
func taskVisibilityTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "closing individual and all windows hides their tasks without deleting state") {
            let tasks = [visibilityTask("alpha"), visibilityTask("beta")]
            var visibility = VSCodeTaskVisibility()
            try expect(visibility.visibleTasks(in: tasks) == tasks, "unknown inventory hid persisted tasks")
            _ = visibility.update(windows: [visibilityWindow("alpha"), visibilityWindow("beta", id: 2)])
            try expect(visibility.visibleTasks(in: tasks) == tasks, "open projects were hidden")
            _ = visibility.update(windows: [visibilityWindow("beta", id: 2)])
            try expect(visibility.visibleTasks(in: tasks) == [tasks[1]], "closed project stayed visible")
            _ = visibility.update(windows: [])
            try expect(visibility.visibleTasks(in: tasks).isEmpty, "closing all windows left stale rows")
            try expect(visibility.hasNoOpenWindows, "empty inventory did not select the no-windows state")
            _ = visibility.update(windows: [visibilityWindow("alpha")])
            try expect(visibility.visibleTasks(in: tasks) == [tasks[0]], "reopening lost the original task state")
        },
        CodexBarTestCase(name: "unavailable window reads preserve the last successful inventory") {
            let tasks = [visibilityTask("alpha")]
            var visibility = VSCodeTaskVisibility()
            try expect(!visibility.update(windows: nil), "failed initial scan changed inventory")
            try expect(!visibility.hasNoOpenWindows, "unknown inventory was treated as no windows")
            _ = visibility.update(windows: [visibilityWindow("alpha")])
            try expect(!visibility.update(windows: nil), "failed scan changed open windows")
            try expect(visibility.visibleTasks(in: tasks) == tasks, "AX failure hid an open task")
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

private func visibilityTask(_ name: String) -> CodexTask {
    CodexTask(
        id: name, sessionID: name, turnID: "turn", cwd: "/work/\(name)",
        workspaceName: name, title: name, status: .ready,
        startedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100),
        isUnread: true
    )
}
