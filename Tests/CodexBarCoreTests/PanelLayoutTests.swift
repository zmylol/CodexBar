import CodexBarCore
import Foundation

@MainActor
func panelLayoutTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "uses the approved compact desktop footprint") {
            try expect(CodexBarPanelLayout.compactWidth == 168, "compact width changed")
            try expect(CodexBarPanelLayout.detailWidth == 320, "hover detail width changed")
            try expect(CodexBarPanelLayout.detailHeight == 260, "hover detail height changed")
            try expect(
                CodexBarPanelLayout.maximumVisiblePlanSteps == 5,
                "hover detail no longer fits the approved five plan steps"
            )
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
                CodexBarPanelLayout.compactWidth == 168,
                "a notice widened the persistent panel contract"
            )
        },
        CodexBarTestCase(name: "places hover details beside the matching compact row") {
            let panelFrame = CGRect(x: 900, y: 700, width: 168, height: 140)
            let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)

            let detailFrame = CodexBarPanelLayout.detailFrame(
                panelFrame: panelFrame,
                rowMidYFromTop: 42,
                visibleFrame: visibleFrame
            )

            try expect(detailFrame.origin.x == 572, "hover detail was not placed to the left")
            try expect(detailFrame.origin.y == 668, "hover detail was not aligned with its row")
            try expect(detailFrame.size.width == 320, "hover detail width changed")
            try expect(detailFrame.size.height == 260, "hover detail height changed")
        },
        CodexBarTestCase(name: "keeps hover details within the visible screen") {
            let visibleFrame = CGRect(x: 0, y: 24, width: 1200, height: 876)

            let rightFrame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(x: 18, y: 760, width: 168, height: 140),
                rowMidYFromTop: 14,
                visibleFrame: visibleFrame
            )
            try expect(rightFrame.origin.x == 194, "hover detail did not fall back to the right")
            try expect(rightFrame.maxY == visibleFrame.maxY, "top edge was not clamped")

            let bottomFrame = CodexBarPanelLayout.detailFrame(
                panelFrame: CGRect(x: 900, y: 20, width: 168, height: 140),
                rowMidYFromTop: 126,
                visibleFrame: visibleFrame
            )
            try expect(bottomFrame.minY == visibleFrame.minY, "bottom edge was not clamped")
        }
    ]
}
