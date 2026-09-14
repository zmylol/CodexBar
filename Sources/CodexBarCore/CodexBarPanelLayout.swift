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
    public static let branchRowHeight: CGFloat = 40
    public static let repositoryHeaderHeight: CGFloat = 18
    public static let cornerRadius: CGFloat = 11
    public static let emptyHeight: CGFloat = 56
    public static let noticeHeight: CGFloat = 84
    public static let maximumRows = 5
    public static let defaultDetailHeight: CGFloat = 520

    public static func rowHeight(for row: GitWorkspaceTreeRow) -> CGFloat {
        let showsOrigin = row.label?.sourceBranch != nil && row.parentRowID == nil
        let baseHeight = showsOrigin || row.depth >= 2 ? branchRowHeight : rowHeight
        return baseHeight + (row.row.task == nil ? 12 : 0)
    }

    public static func rowHeights(groups: [GitWorkspaceGroup]) -> [CGFloat] {
        groups.flatMap { group in
            group.rows.enumerated().map { index, row in
                // A repository heading belongs to its first task, so the scroll limit still counts workspaces.
                rowHeight(for: row) + (index == 0 && group.repositoryName != nil ? repositoryHeaderHeight : 0)
            }
        }
    }

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
        return height(contentHeight: contentHeight, noticeVisible: noticeVisible, maximumHeight: maximumHeight)
    }

    public static func height(
        rowHeights: [CGFloat],
        noticeVisible: Bool,
        displayMode: CodexBarPanelDisplayMode = .scrolling,
        maximumHeight: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat {
        let visibleRowCount = displayMode == .expanded ? rowHeights.count : maximumRows
        let contentHeight = rowHeights.isEmpty
            ? emptyHeight
            : rowHeights.prefix(visibleRowCount).reduce(0, +)
        return height(contentHeight: contentHeight, noticeVisible: noticeVisible, maximumHeight: maximumHeight)
    }

    private static func height(
        contentHeight: CGFloat,
        noticeVisible: Bool,
        maximumHeight: CGFloat
    ) -> CGFloat {
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
        return panelFrame(currentFrame: currentFrame, height: height, visibleFrame: visibleFrame)
    }

    public static func panelFrame(
        currentFrame: CGRect,
        rowHeights: [CGFloat],
        noticeVisible: Bool,
        displayMode: CodexBarPanelDisplayMode,
        visibleFrame: CGRect
    ) -> CGRect {
        let height = height(
            rowHeights: rowHeights,
            noticeVisible: noticeVisible,
            displayMode: displayMode,
            maximumHeight: visibleFrame.height
        )
        return panelFrame(currentFrame: currentFrame, height: height, visibleFrame: visibleFrame)
    }

    private static func panelFrame(
        currentFrame: CGRect,
        height: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
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
        detailHeight: CGFloat,
        detailWidth: CGFloat = CodexBarPanelLayout.detailWidth
    ) -> CGRect {
        let boundedDetailWidth = min(max(detailWidth, 0), max(visibleFrame.width, 0))
        let leftX = panelFrame.minX - detailGap - boundedDetailWidth
        let rightX = panelFrame.maxX + detailGap
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - boundedDetailWidth)
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

        return CGRect(x: x, y: y, width: boundedDetailWidth, height: boundedDetailHeight)
    }
}
