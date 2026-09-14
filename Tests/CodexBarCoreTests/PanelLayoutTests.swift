import CodexBarCore
import Foundation

@MainActor
func panelLayoutTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "uses the approved compact desktop footprint") {
            try expect(
                CodexBarPanelLayout.compactWidth == 126,
                "compact width is not three-quarters"
            )
            try expect(CodexBarPanelLayout.detailWidth == 420, "conversation preview needs a readable width")
            try expect(CodexBarPanelLayout.defaultDetailHeight == 520, "conversation preview needs a stable reading height")
            try expect(CodexBarPanelLayout.detailGap == 8, "hover detail gap changed")
            try expect(CodexBarPanelLayout.headerHeight == 28, "header height changed")
            try expect(CodexBarPanelLayout.rowHeight == 28, "row height changed")
            try expect(CodexBarPanelLayout.cornerRadius == 11, "corner radius changed")
        },
        CodexBarTestCase(name: "sizes the compact panel without exposing row details") {
            try expect(
                CodexBarPanelLayout.height(taskCount: 4, noticeVisible: false) == 140,
                "four projects did not fit the approved compact height"
            )
            try expect(
                CodexBarPanelLayout.height(taskCount: 100, noticeVisible: false) == 168,
                "task overflow was not capped at five compact rows"
            )
            try expect(
                CodexBarPanelLayout.height(taskCount: 0, noticeVisible: false) == 84,
                "empty state height changed"
            )
            try expect(
                CodexBarPanelLayout.height(taskCount: -1, noticeVisible: false) == 84,
                "invalid negative task count produced an invalid height"
            )
        },
        CodexBarTestCase(name: "adds temporary notice space without widening the panel") {
            try expect(
                CodexBarPanelLayout.height(taskCount: 4, noticeVisible: true) == 224,
                "notice space was not added to the compact panel"
            )
            try expect(
                CodexBarPanelLayout.compactWidth == 126,
                "a notice widened the persistent panel contract"
            )
        },
        CodexBarTestCase(name: "sizes mixed project rows in their displayed order") {
            try expect(CodexBarPanelLayout.branchRowHeight == 40, "branch labels need two-line row space")
            let rowHeights: [CGFloat] = [28, 40, 28, 40, 28, 40]
            try expect(
                CodexBarPanelLayout.height(rowHeights: rowHeights, noticeVisible: false) == 192,
                "scrolling mode did not sum the first five mixed rows"
            )
            try expect(
                CodexBarPanelLayout.height(
                    rowHeights: rowHeights,
                    noticeVisible: true,
                    displayMode: .expanded
                ) == 316,
                "expanded mode did not include all mixed rows and the notice"
            )
            try expect(
                CodexBarPanelLayout.height(rowHeights: [40, 28], noticeVisible: false) == 96,
                "a branch row clipped the following project"
            )
        },
        CodexBarTestCase(name: "preserves empty state and screen limits for mixed project rows") {
            try expect(
                CodexBarPanelLayout.height(rowHeights: [], noticeVisible: false) == 84,
                "mixed rows changed the empty state height"
            )
            try expect(
                CodexBarPanelLayout.height(
                    rowHeights: [40, 28, 40, 28, 40, 28],
                    noticeVisible: true,
                    displayMode: .expanded,
                    maximumHeight: 180
                ) == 180,
                "mixed rows overflowed the available screen height"
            )
            try expect(
                CodexBarPanelLayout.height(taskCount: Int.max, noticeVisible: false) == 168,
                "legacy task count sizing should stay bounded without allocating rows"
            )
        },
        CodexBarTestCase(name: "repository headings preserve the five workspace scroll limit") {
            let rows = (0..<6).map { index in
                let path = "/layout/work-\(index)"
                return VSCodeTaskRow(
                    id: path, displayName: "work-\(index)", rootPath: path, isMultiRoot: false,
                    task: CodexTask(
                        id: path, sessionID: path, turnID: "turn", cwd: path,
                        workspaceName: "project", title: "task", status: .ready,
                        startedAt: Date(), updatedAt: Date(), isUnread: false
                    )
                )
            }
            let parent = GitWorkspaceLabel(
                repositoryName: "project", branch: "main", shortBranch: "main",
                isLinkedWorktree: false, workspaceRoot: rows[0].rootPath, repositoryID: "/repo/.git"
            )
            let child = GitWorkspaceLabel(
                repositoryName: "project", branch: "feature", shortBranch: "feature",
                isLinkedWorktree: true, workspaceRoot: rows[1].rootPath,
                sourceBranch: "main", repositoryID: "/repo/.git"
            )
            let labels = [rows[0].rootPath: parent, rows[1].rootPath: child]
            let groups = GitWorkspaceTree.groups(rows: rows, labels: labels)
            let heights = CodexBarPanelLayout.rowHeights(groups: groups)
            try expect(heights.count == 6, "repository heading counted as an extra workspace")
            try expect(heights == [46, 28, 28, 28, 28, 28], "tree geometry clips a heading or branch")
            try expect(CodexBarPanelLayout.height(rowHeights: heights, noticeVisible: false) == 186,
                       "scrolling no longer fits five actual workspaces")
            try expect(CodexBarPanelLayout.height(rowHeights: heights, noticeVisible: false, displayMode: .expanded) == 214,
                       "expanded panel dropped a workspace or repository heading")
            let onlyChild = GitWorkspaceTree.groups(rows: [rows[1]], labels: labels)
            try expect(CodexBarPanelLayout.rowHeights(groups: onlyChild) == [58],
                       "closed parent source caption has insufficient vertical space")
        },
        CodexBarTestCase(name: "preserves the top edge when branch labels increase row heights") {
            let frame = CodexBarPanelLayout.panelFrame(
                currentFrame: CGRect(x: 900, y: 600, width: 126, height: 84),
                rowHeights: [40, 28],
                noticeVisible: false,
                displayMode: .expanded,
                visibleFrame: CGRect(x: 18, y: 42, width: 1164, height: 840)
            )
            try expect(frame == CGRect(x: 900, y: 588, width: 126, height: 96),
                       "a branch label moved the panel top or clipped a row")
            let screen = CGRect(x: 18, y: 42, width: 1164, height: 180)
            let clamped = CodexBarPanelLayout.panelFrame(
                currentFrame: CGRect(x: 2000, y: 900, width: 126, height: 168),
                rowHeights: [40, 40, 40, 40, 40, 40],
                noticeVisible: true,
                displayMode: .expanded,
                visibleFrame: screen
            )
            try expect(clamped.height == screen.height && clamped.minY == screen.minY
                       && clamped.maxX == screen.maxX,
                       "mixed row growth did not stay within the visible display")
        },
        CodexBarTestCase(name: "expands the panel to show every task when the screen has room") {
            try expect(
                CodexBarPanelLayout.height(
                    taskCount: 12,
                    noticeVisible: false,
                    displayMode: .expanded
                ) == 364,
                "expanded mode still capped the task list at five rows"
            )
            try expect(
                CodexBarPanelLayout.height(
                    taskCount: 12,
                    noticeVisible: true,
                    displayMode: .expanded
                ) == 448,
                "expanded mode did not reserve space for the notice"
            )
            try expect(
                CodexBarPanelLayout.height(
                    taskCount: 0,
                    noticeVisible: false,
                    displayMode: .expanded
                ) == 84,
                "expanded mode changed the empty state height"
            )
        },
        CodexBarTestCase(name: "bounds both display modes by the available screen height") {
            try expect(
                CodexBarPanelLayout.height(
                    taskCount: 100,
                    noticeVisible: true,
                    displayMode: .expanded,
                    maximumHeight: 700
                ) == 700,
                "expanded mode overflowed the available screen height"
            )
            try expect(
                CodexBarPanelLayout.height(
                    taskCount: 100,
                    noticeVisible: false,
                    displayMode: .scrolling,
                    maximumHeight: 700
                ) == 168,
                "scrolling mode no longer shows at most five rows"
            )
            try expect(
                CodexBarPanelLayout.height(
                    taskCount: 5,
                    noticeVisible: true,
                    displayMode: .scrolling,
                    maximumHeight: 200
                ) == 200,
                "scrolling mode overflowed a short screen"
            )
        },
        CodexBarTestCase(name: "preserves the panel top edge while expanding when it fits") {
            let frame = CodexBarPanelLayout.panelFrame(
                currentFrame: CGRect(x: 900, y: 600, width: 126, height: 168),
                taskCount: 12,
                noticeVisible: false,
                displayMode: .expanded,
                visibleFrame: CGRect(x: 18, y: 42, width: 1164, height: 840)
            )
            try expect(frame.maxY == 768, "expanding moved a valid top edge")
            try expect(frame.height == 364, "expanding did not show all 12 tasks")
            try expect(frame.minX == 900, "expanding moved a valid horizontal position")
        },
        CodexBarTestCase(name: "keeps an expanded panel visible after growth and screen changes") {
            let screen = CGRect(x: 18, y: 42, width: 1164, height: 640)
            let growingFrame = CodexBarPanelLayout.panelFrame(
                currentFrame: CGRect(x: 900, y: 42, width: 126, height: 168),
                taskCount: 12,
                noticeVisible: true,
                displayMode: .expanded,
                visibleFrame: screen
            )
            try expect(growingFrame.minY == 42, "expanded tasks disappeared below the screen")
            try expect(growingFrame.height == 448, "bottom-edge adjustment lost task rows")

            let movedFrame = CodexBarPanelLayout.panelFrame(
                currentFrame: CGRect(x: 2000, y: 900, width: 126, height: 1000),
                taskCount: 100,
                noticeVisible: false,
                displayMode: .expanded,
                visibleFrame: screen
            )
            try expect(movedFrame.height == 640, "panel did not shrink to the new screen")
            try expect(movedFrame.maxX == screen.maxX, "panel stayed beyond the screen right edge")
            try expect(movedFrame.minY == screen.minY, "panel did not stay within the new screen")
        },
        CodexBarTestCase(name: "places hover details beside the matching compact row") {
            let panelFrame = CGRect(
                x: 900,
                y: 700,
                width: CodexBarPanelLayout.compactWidth,
                height: 140
            )
            let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)
            let detailHeight: CGFloat = 136

            let detailFrame = CodexBarPanelLayout.detailFrame(
                panelFrame: panelFrame,
                rowMidYFromTop: 42,
                visibleFrame: visibleFrame,
                detailHeight: detailHeight
            )

            try expect(detailFrame.origin.x == 472, "hover detail was not placed to the left")
            try expect(detailFrame.origin.y == 730, "hover detail was not centered beside its row")
            try expect(detailFrame.size.width == 420, "hover detail width changed")
            try expect(detailFrame.size.height == 136, "hover detail ignored its content height")
        },
        CodexBarTestCase(name: "places a wide library beside the bar without changing conversation width") {
            let frame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(x: 900, y: 400, width: 126, height: 140),
                rowMidYFromTop: 14,
                visibleFrame: CGRect(x: 18, y: 42, width: 1164, height: 840),
                detailHeight: 520,
                detailWidth: 620
            )
            try expect(frame == CGRect(x: 272, y: 266, width: 620, height: 520),
                       "the two-column library lost its width, alignment or gap")
        },
        CodexBarTestCase(name: "flips a wide library onto a display with negative coordinates") {
            let screen = CGRect(x: -1280, y: 24, width: 1280, height: 776)
            let frame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(x: -1262, y: 620, width: 126, height: 140),
                rowMidYFromTop: 14,
                visibleFrame: screen,
                detailHeight: 520,
                detailWidth: 620
            )
            try expect(frame.minX == -1128 && frame.maxY == screen.maxY && frame.width == 620,
                       "the library failed to flip right and stay below the display top")
        },
        CodexBarTestCase(name: "shrinks wide details to fit a smaller visible display") {
            let screen = CGRect(x: 100, y: 24, width: 500, height: 400)
            let frame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(x: 110, y: 200, width: 126, height: 140),
                rowMidYFromTop: 42,
                visibleFrame: screen,
                detailHeight: 520,
                detailWidth: 620
            )
            try expect(frame == screen, "the library extended beyond the available display")
        },
        CodexBarTestCase(name: "keeps hover details within the visible screen") {
            let visibleFrame = CGRect(x: 0, y: 24, width: 1200, height: 876)
            let detailHeight: CGFloat = 320

            let rightFrame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(
                    x: 18,
                    y: 760,
                    width: CodexBarPanelLayout.compactWidth,
                    height: 140
                ),
                rowMidYFromTop: 14,
                visibleFrame: visibleFrame,
                detailHeight: detailHeight
            )
            try expect(rightFrame.origin.x == 152, "hover detail did not follow the narrower bar")
            try expect(rightFrame.maxY == visibleFrame.maxY, "top edge was not clamped")

            let bottomFrame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(
                    x: 900,
                    y: 20,
                    width: CodexBarPanelLayout.compactWidth,
                    height: 140
                ),
                rowMidYFromTop: 126,
                visibleFrame: visibleFrame,
                detailHeight: detailHeight
            )
            try expect(bottomFrame.minY == visibleFrame.minY, "bottom edge was not clamped")

            let shortVisibleFrame = CGRect(x: 0, y: 24, width: 1200, height: 150)
            let shortScreenFrame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(
                    x: 900,
                    y: 20,
                    width: CodexBarPanelLayout.compactWidth,
                    height: 140
                ),
                rowMidYFromTop: 70,
                visibleFrame: shortVisibleFrame,
                detailHeight: detailHeight
            )
            try expect(
                shortScreenFrame.height == shortVisibleFrame.height,
                "hover detail exceeded a short visible screen"
            )
            try expect(
                shortScreenFrame.minY == shortVisibleFrame.minY
                    && shortScreenFrame.maxY == shortVisibleFrame.maxY,
                "screen-height clamping moved the hover detail out of bounds"
            )
        }
    ]
}
