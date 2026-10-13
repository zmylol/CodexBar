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
        CodexBarTestCase(name: "project headings preserve the five workspace scroll limit") {
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
            try expect(heights == [58, 40, 46, 28, 28, 28], "tree geometry clips a project heading or workspace role caption")
            try expect(CodexBarPanelLayout.height(rowHeights: heights, noticeVisible: false) == 228,
                       "scrolling no longer fits five actual workspaces")
            try expect(CodexBarPanelLayout.height(rowHeights: heights, noticeVisible: false, displayMode: .expanded) == 256,
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
        CodexBarTestCase(name: "preserves a custom scrolling size as the task list changes") {
            let currentFrame = CGRect(x: 300, y: 500, width: 126, height: 168)
            let screen = CGRect(x: 18, y: 42, width: 1164, height: 840)
            let expected = CGRect(x: 300, y: 348, width: 240, height: 320)
            let taskFrame = CodexBarPanelLayout.panelFrame(
                currentFrame: currentFrame, taskCount: 1, noticeVisible: false,
                displayMode: .scrolling, visibleFrame: screen, width: 240, preferredHeight: 320
            )
            let mixedFrame = CodexBarPanelLayout.panelFrame(
                currentFrame: taskFrame, rowHeights: [40, 28, 40, 28, 40, 28], noticeVisible: false,
                displayMode: .scrolling, visibleFrame: screen, width: 240, preferredHeight: 320
            )
            try expect(taskFrame == expected, "custom size moved the top edge or horizontal position")
            try expect(mixedFrame == expected, "a refreshed task list discarded the custom scrolling size")
        },
        CodexBarTestCase(name: "expanded mode retains custom width and sizes height from its content") {
            let currentFrame = CGRect(x: 300, y: 500, width: 240, height: 168)
            let screen = CGRect(x: 18, y: 42, width: 1164, height: 840)
            let taskFrame = CodexBarPanelLayout.panelFrame(
                currentFrame: currentFrame, taskCount: 12, noticeVisible: false,
                displayMode: .expanded, visibleFrame: screen, width: 240, preferredHeight: 100
            )
            let mixedFrame = CodexBarPanelLayout.panelFrame(
                currentFrame: currentFrame, rowHeights: [40, 28, 40, 28, 40, 28], noticeVisible: true,
                displayMode: .expanded, visibleFrame: screen, width: 240, preferredHeight: 100
            )
            try expect(taskFrame.width == 240 && taskFrame.height == 364,
                       "expanded tasks used the scrolling height override")
            try expect(mixedFrame.width == 240 && mixedFrame.height == 316,
                       "expanded mixed rows did not include all content and the notice")
        },
        CodexBarTestCase(name: "bounds custom panel dimensions and reserves notice space") {
            let currentFrame = CGRect(x: 300, y: 300, width: 126, height: 1400)
            let screen = CGRect(x: 0, y: 0, width: 2000, height: 2000)
            let minimum = CodexBarPanelLayout.panelFrame(
                currentFrame: currentFrame, rowHeights: [40], noticeVisible: false,
                displayMode: .scrolling, visibleFrame: screen, width: -20, preferredHeight: -20
            )
            let maximum = CodexBarPanelLayout.panelFrame(
                currentFrame: currentFrame, taskCount: 1, noticeVisible: false,
                displayMode: .scrolling, visibleFrame: screen, width: 3000, preferredHeight: 3000
            )
            let notice = CodexBarPanelLayout.panelFrame(
                currentFrame: currentFrame, rowHeights: [40], noticeVisible: true,
                displayMode: .scrolling, visibleFrame: screen, width: 240, preferredHeight: 100
            )
            try expect(minimum.size == CGSize(width: 126, height: 84), "minimum usable panel size was lost")
            try expect(maximum.size == CGSize(width: 480, height: 1200), "custom size exceeded its limits")
            try expect(notice.height == 168, "the notice consumed the entire custom content area")
        },
        CodexBarTestCase(name: "fits custom dimensions onto a smaller screen") {
            let screen = CGRect(x: -500, y: 24, width: 100, height: 80)
            let frame = CodexBarPanelLayout.panelFrame(
                currentFrame: CGRect(x: 900, y: 600, width: 240, height: 320),
                taskCount: 10, noticeVisible: true, displayMode: .scrolling,
                visibleFrame: screen, width: 240, preferredHeight: 320
            )
            try expect(frame == screen, "custom minimum dimensions overflowed the visible screen")
            let defaultFrame = CodexBarPanelLayout.panelFrame(
                currentFrame: frame, rowHeights: [40], noticeVisible: false,
                displayMode: .scrolling, visibleFrame: screen
            )
            try expect(defaultFrame.width == screen.width, "the default width overflowed a narrow screen")
        },
        CodexBarTestCase(name: "invalid custom dimensions fall back to automatic compact sizing") {
            let currentFrame = CGRect(x: 300, y: 500, width: 240, height: 168)
            let screen = CGRect(x: 18, y: 42, width: 1164, height: 840)
            for invalid: CGFloat in [.nan, .infinity, -.infinity] {
                let taskFrame = CodexBarPanelLayout.panelFrame(
                    currentFrame: currentFrame, taskCount: 4, noticeVisible: false,
                    displayMode: .scrolling, visibleFrame: screen, width: invalid, preferredHeight: invalid
                )
                let mixedFrame = CodexBarPanelLayout.panelFrame(
                    currentFrame: currentFrame, rowHeights: [40, 28], noticeVisible: false,
                    displayMode: .scrolling, visibleFrame: screen, width: invalid, preferredHeight: invalid
                )
                try expect(taskFrame == CGRect(x: 300, y: 528, width: 126, height: 140),
                           "invalid task size did not fall back to automatic dimensions")
                try expect(mixedFrame == CGRect(x: 300, y: 572, width: 126, height: 96),
                           "invalid mixed-row size did not fall back to automatic dimensions")
            }
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
