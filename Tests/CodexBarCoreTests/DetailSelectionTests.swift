import CodexBarCore
import Foundation

@MainActor
func detailSelectionTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "prefers hover details and falls back to keyboard focus") {
            var selection = CodexBarDetailSelection()

            selection.updateFocus(cwd: "/focus-a", rowMidY: 42, active: true)
            try expect(selection.selected?.cwd == "/focus-a", "focus did not select its task")

            selection.updateHover(cwd: "/hover-b", rowMidY: 70, active: true)
            try expect(selection.selected?.cwd == "/hover-b", "hover did not take priority")

            selection.updateHover(cwd: "/hover-b", rowMidY: 70, active: false)
            try expect(selection.selected?.cwd == "/focus-a", "focus was not restored after hover")
        },
        CodexBarTestCase(name: "ignores stale detail exit callbacks") {
            var selection = CodexBarDetailSelection()

            selection.updateHover(cwd: "/new", rowMidY: 70, active: true)
            selection.updateHover(cwd: "/old", rowMidY: 42, active: false)
            try expect(selection.selected?.cwd == "/new", "a stale hover exit cleared the current task")

            selection.updateFocus(cwd: "/new-focus", rowMidY: 98, active: true)
            selection.updateFocus(cwd: "/old-focus", rowMidY: 42, active: false)
            try expect(selection.focused?.cwd == "/new-focus", "a stale focus exit cleared the current task")
        },
        CodexBarTestCase(name: "clears all active detail triggers on explicit dismissal") {
            var selection = CodexBarDetailSelection()
            selection.updateFocus(cwd: "/focus", rowMidY: 42, active: true)
            selection.updateHover(cwd: "/hover", rowMidY: 70, active: true)

            selection.clear()

            try expect(selection.selected == nil, "explicit dismissal kept a selected detail")
            try expect(selection.hovered == nil, "explicit dismissal kept hover state")
            try expect(selection.focused == nil, "explicit dismissal kept focus state")
        }
    ]
}
