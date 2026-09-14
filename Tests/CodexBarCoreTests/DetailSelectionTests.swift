import CodexBarCore
import Foundation

@MainActor
func detailSelectionTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "details follow changed row heights without changing the selected project") {
            var selection = CodexBarDetailSelection()
            selection.updateFocus(rowID: "/main", rowMidY: 70, active: true)
            selection.updateHover(rowID: "/worktree", rowMidY: 98, active: true)
            selection.updatePosition(rowID: "/main", rowMidY: 82)
            selection.updatePosition(rowID: "/worktree", rowMidY: 122)
            selection.updatePosition(rowID: "/unrelated", rowMidY: 150)
            try expect(selection.selected?.rowID == "/worktree" && selection.selected?.rowMidY == 122,
                       "layout change lost the hovered worktree or retained its old anchor")
            selection.updateHover(rowID: "/worktree", rowMidY: 122, active: false)
            try expect(selection.selected?.rowID == "/main" && selection.selected?.rowMidY == 82,
                       "keyboard focus fell back to the old row position")
        },
        CodexBarTestCase(name: "keeps folder and workspace detail anchors independent when they share a task") {
            var selection = CodexBarDetailSelection()
            let folderRowID = "workspace:/projects/shared"
            let workspaceRowID = "workspace:/workspaces/Untitled/workspace.json"
            selection.updateFocus(rowID: folderRowID, rowMidY: 42, active: true)
            selection.updateHover(rowID: workspaceRowID, rowMidY: 70, active: true)

            selection.updatePosition(rowID: folderRowID, rowMidY: 54)
            selection.updateHover(rowID: folderRowID, rowMidY: 54, active: false)
            try expect(selection.selected?.rowID == workspaceRowID && selection.selected?.rowMidY == 70,
                       "callbacks from the folder row displaced the workspace detail sharing its task")

            selection.updateHover(rowID: workspaceRowID, rowMidY: 70, active: false)
            try expect(selection.selected?.rowID == folderRowID && selection.selected?.rowMidY == 54,
                       "leaving the workspace detail lost the distinct folder focus")
        },
        CodexBarTestCase(name: "prefers hover details and falls back to keyboard focus") {
            var selection = CodexBarDetailSelection()

            selection.updateFocus(rowID: "/focus-a", rowMidY: 42, active: true)
            try expect(selection.selected?.rowID == "/focus-a", "focus did not select its task")

            selection.updateHover(rowID: "/hover-b", rowMidY: 70, active: true)
            try expect(selection.selected?.rowID == "/hover-b", "hover did not take priority")

            selection.updateHover(rowID: "/hover-b", rowMidY: 70, active: false)
            try expect(selection.selected?.rowID == "/focus-a", "focus was not restored after hover")
        },
        CodexBarTestCase(name: "ignores stale detail exit callbacks") {
            var selection = CodexBarDetailSelection()

            selection.updateHover(rowID: "/new", rowMidY: 70, active: true)
            selection.updateHover(rowID: "/old", rowMidY: 42, active: false)
            try expect(selection.selected?.rowID == "/new", "a stale hover exit cleared the current task")

            selection.updateFocus(rowID: "/new-focus", rowMidY: 98, active: true)
            selection.updateFocus(rowID: "/old-focus", rowMidY: 42, active: false)
            try expect(selection.focused?.rowID == "/new-focus", "a stale focus exit cleared the current task")
        },
        CodexBarTestCase(name: "clears all active detail triggers on explicit dismissal") {
            var selection = CodexBarDetailSelection()
            selection.updateFocus(rowID: "/focus", rowMidY: 42, active: true)
            selection.updateHover(rowID: "/hover", rowMidY: 70, active: true)

            selection.clear()

            try expect(selection.selected == nil, "explicit dismissal kept a selected detail")
            try expect(selection.hovered == nil, "explicit dismissal kept hover state")
            try expect(selection.focused == nil, "explicit dismissal kept focus state")
        }
    ]
}
