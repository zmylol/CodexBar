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
            try expect(CodexBarPanelLayout.detailWidth == 320, "hover detail width changed")
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

            try expect(detailFrame.origin.x == 572, "hover detail was not placed to the left")
            try expect(detailFrame.origin.y == 730, "hover detail was not centered beside its row")
            try expect(detailFrame.size.width == 320, "hover detail width changed")
            try expect(detailFrame.size.height == 136, "hover detail ignored its content height")
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
