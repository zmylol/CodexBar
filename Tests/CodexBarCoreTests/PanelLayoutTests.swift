import CodexBarCore
import Foundation

@MainActor
func panelLayoutTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "uses the approved compact desktop footprint") {
            try expect(CodexBarPanelLayout.compactWidth == 112, "compact width is not two-thirds")
            try expect(CodexBarPanelLayout.detailWidth == 320, "hover detail width changed")
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
                CodexBarPanelLayout.compactWidth == 112,
                "a notice widened the persistent panel contract"
            )
        },
        CodexBarTestCase(name: "sizes hover details from visible content") {
            try expect(
                CodexBarPanelLayout.detailHeight(visibleItemCount: 0) == 136,
                "an empty hover detail did not use the compact one-line height"
            )
            try expect(
                CodexBarPanelLayout.detailHeight(visibleItemCount: 1) == 136,
                "one visible item changed the compact hover detail height"
            )
            try expect(
                CodexBarPanelLayout.detailHeight(visibleItemCount: 3) == 176,
                "three activity items did not grow the hover detail"
            )
            try expect(
                CodexBarPanelLayout.detailHeight(visibleItemCount: 5) == 216,
                "five plan steps did not fit the expanded hover detail"
            )
            try expect(
                CodexBarPanelLayout.detailHeight(visibleItemCount: 99) == 216,
                "hover detail height was not capped at five visible items"
            )
            try expect(
                CodexBarPanelLayout.detailHeight(visibleItemCount: -1) == 136,
                "an invalid item count produced an invalid hover detail height"
            )
        },
        CodexBarTestCase(name: "places hover details beside the matching compact row") {
            let panelFrame = CGRect(
                x: 900,
                y: 700,
                width: CodexBarPanelLayout.compactWidth,
                height: 140
            )
            let visibleFrame = CGRect(x: 0, y: 0, width: 1200, height: 900)
            let detailHeight = CodexBarPanelLayout.detailHeight(visibleItemCount: 1)

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
            let detailHeight = CodexBarPanelLayout.detailHeight(visibleItemCount: 5)

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
            try expect(rightFrame.origin.x == 138, "hover detail did not follow the narrower bar")
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
