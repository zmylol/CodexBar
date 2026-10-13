import CodexBarCore
import Foundation
import SwiftUI

struct WorkspaceGroupHeader: View {
    let name: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 8))
                .accessibilityHidden(true)
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: CodexBarPanelLayout.repositoryHeaderHeight)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground()
            }
        }
        .overlay(alignment: .top) {
            Divider().opacity(0.16)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityAddTraits(.isHeader)
        .help(name)
    }
}

struct GitWorkspaceRowContent: View {
    let treeRow: GitWorkspaceTreeRow
    let hasChildren: Bool
    let statusSymbol: String
    let statusColor: Color
    let knowledgePendingCount: Int

    private var label: GitWorkspaceLabel? { treeRow.label }
    private var rowHeight: CGFloat { CodexBarPanelLayout.rowHeight(for: treeRow) }
    // Keep labels readable in the narrow task panel; the workspace browser shows every level.
    private var displayDepth: Int { min(treeRow.depth, 3) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: statusSymbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label?.shortBranch ?? treeRow.row.displayName)
                    .font(.system(
                        size: label == nil ? 12 : 11,
                        weight: treeRow.row.task?.isUnread == true ? .semibold : .medium,
                        design: label == nil ? .default : .monospaced
                    ))
                    .lineLimit(treeRow.depth >= 2 ? 2 : 1)
                    .truncationMode(.tail)
                if let label {
                    HStack(spacing: 4) {
                        Text(label.isLinkedWorktree ? "WT" : "主目录")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                            .fixedSize()
                        if !label.worktreeName.isEmpty {
                            Text("· \(label.worktreeName)")
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                }
                if treeRow.row.task == nil {
                    Text("暂无任务")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if knowledgePendingCount > 0 {
                Text(label == nil ? "\(knowledgePendingCount) 待回看" : "\(knowledgePendingCount)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, label == nil ? 5 : 3)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    .fixedSize()
            }
        }
        .padding(.leading, 10 + CGFloat(displayDepth) * 10)
        .padding(.trailing, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: rowHeight)
        .background {
            GitWorkspaceConnector(row: treeRow, hasChildren: hasChildren)
                .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

private struct GitWorkspaceConnector: Shape {
    let row: GitWorkspaceTreeRow
    let hasChildren: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ start: CGPoint, _ end: CGPoint) {
            path.move(to: start)
            path.addLine(to: end)
        }
        let displayDepth = min(row.depth, 3)
        for level in row.ancestorContinuationLevels where level < displayDepth {
            let x = 15 + CGFloat(level - 1) * 10
            line(CGPoint(x: x, y: 0), CGPoint(x: x, y: rect.height))
        }
        let centerX = 15 + CGFloat(displayDepth) * 10
        if row.parentRowID != nil {
            let parentX = centerX - 10
            line(CGPoint(x: parentX, y: 0), CGPoint(x: parentX, y: row.isLastSibling ? rect.midY : rect.height))
            line(CGPoint(x: parentX, y: rect.midY), CGPoint(x: centerX - 5, y: rect.midY))
        }
        if hasChildren {
            line(CGPoint(x: centerX, y: rect.midY + 5), CGPoint(x: centerX, y: rect.height))
        }
        return path
    }
}
