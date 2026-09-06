import CoreGraphics

public enum CodexBarPanelDisplayMode: String, CaseIterable {
    case scrolling
    case expanded
}

public enum CodexBarPanelLayout {
    public static let compactWidth: CGFloat = 126
    public static let detailWidth: CGFloat = 420
    public static let detailGap: CGFloat = 8
    public static let headerHeight: CGFloat = 28
    public static let rowHeight: CGFloat = 28
    public static let cornerRadius: CGFloat = 11
    public static let emptyHeight: CGFloat = 56
    public static let noticeHeight: CGFloat = 84
    public static let maximumRows = 5
    public static let defaultDetailHeight: CGFloat = 520

    public static func height(
        taskCount: Int,
        noticeVisible: Bool,
        displayMode: CodexBarPanelDisplayMode = .scrolling,
        maximumHeight: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat {
        let taskCount = max(taskCount, 0)
        let visibleTaskCount = displayMode == .expanded
            ? taskCount
            : min(taskCount, maximumRows)
        let contentHeight = visibleTaskCount == 0
            ? emptyHeight
            : CGFloat(visibleTaskCount) * rowHeight
        let preferredHeight = headerHeight + contentHeight + (noticeVisible ? noticeHeight : 0)
        return min(preferredHeight, max(maximumHeight, 0))
    }

    public static func panelFrame(
        currentFrame: CGRect,
        taskCount: Int,
        noticeVisible: Bool,
        displayMode: CodexBarPanelDisplayMode,
        visibleFrame: CGRect
    ) -> CGRect {
        let height = height(
            taskCount: taskCount,
            noticeVisible: noticeVisible,
            displayMode: displayMode,
            maximumHeight: visibleFrame.height
        )
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - compactWidth)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - height)
        let x = min(max(currentFrame.minX, visibleFrame.minX), maximumX)
        let y = min(max(currentFrame.maxY - height, visibleFrame.minY), maximumY)
        return CGRect(x: x, y: y, width: compactWidth, height: height)
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
