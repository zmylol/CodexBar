import CoreGraphics

public enum CodexBarPanelLayout {
    public static let compactWidth: CGFloat = 168
    public static let detailWidth: CGFloat = 320
    public static let detailGap: CGFloat = 8
    public static let headerHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 28
    public static let cornerRadius: CGFloat = 11
    public static let emptyHeight: CGFloat = 56
    public static let noticeHeight: CGFloat = 84
    public static let maximumRows = 5
    public static let maximumVisiblePlanSteps = 5

    private static let compactDetailHeight: CGFloat = 136
    private static let additionalDetailItemHeight: CGFloat = 20

    public static func height(taskCount: Int, noticeVisible: Bool) -> CGFloat {
        let visibleTaskCount = min(max(taskCount, 0), maximumRows)
        let contentHeight = visibleTaskCount == 0
            ? emptyHeight
            : CGFloat(visibleTaskCount) * rowHeight
        return headerHeight + contentHeight + (noticeVisible ? noticeHeight : 0)
    }

    public static func detailHeight(visibleItemCount: Int) -> CGFloat {
        let visibleItemCount = min(
            max(visibleItemCount, 1),
            maximumVisiblePlanSteps
        )
        return compactDetailHeight
            + CGFloat(visibleItemCount - 1) * additionalDetailItemHeight
    }

    public static func detailFrame(
        panelFrame: CGRect,
        rowMidYFromTop: CGFloat,
        visibleFrame: CGRect,
        detailHeight: CGFloat
    ) -> CGRect {
        let leftX = panelFrame.minX - detailGap - detailWidth
        let rightX = panelFrame.maxX + detailGap
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - detailWidth)
        let x: CGFloat
        if leftX >= visibleFrame.minX {
            x = min(leftX, maximumX)
        } else {
            x = min(max(rightX, visibleFrame.minX), maximumX)
        }

        let boundedDetailHeight = min(
            max(detailHeight, 0),
            max(visibleFrame.height, 0)
        )
        let rowCenterY = panelFrame.maxY - rowMidYFromTop
        let proposedY = rowCenterY - boundedDetailHeight / 2
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - boundedDetailHeight)
        let y = min(max(proposedY, visibleFrame.minY), maximumY)

        return CGRect(x: x, y: y, width: detailWidth, height: boundedDetailHeight)
    }
}
