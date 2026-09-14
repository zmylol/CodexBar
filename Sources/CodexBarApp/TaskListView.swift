import AppKit
import CodexBarCore
import SwiftUI

struct TaskListView: View {
    private static let coordinateSpaceName = "CodexBarPanel"

    @ObservedObject var model: CodexBarAppModel
    @ObservedObject private var store: TaskStore
    @ObservedObject private var activityStore: LiveTaskActivityStore
    @ObservedObject private var knowledgeStore: KnowledgeReviewStore
    @ObservedObject private var library: KnowledgeLibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let onTaskHoverChanged: (VSCodeTaskRow, CGFloat, Bool) -> Void
    let onTaskFocusChanged: (VSCodeTaskRow, CGFloat, Bool) -> Void
    let onTaskDetailRequested: (VSCodeTaskRow, CGFloat) -> Void
    let onTaskPositionChanged: (VSCodeTaskRow, CGFloat) -> Void
    private let onDismissTaskDetail: () -> Void
    let onKnowledgeRequested: () -> Void

    init(
        model: CodexBarAppModel,
        onTaskHoverChanged: @escaping (VSCodeTaskRow, CGFloat, Bool) -> Void = { _, _, _ in },
        onTaskFocusChanged: @escaping (VSCodeTaskRow, CGFloat, Bool) -> Void = { _, _, _ in },
        onTaskDetailRequested: @escaping (VSCodeTaskRow, CGFloat) -> Void = { _, _ in },
        onTaskPositionChanged: @escaping (VSCodeTaskRow, CGFloat) -> Void = { _, _ in },
        onDismissTaskDetail: @escaping () -> Void = {},
        onKnowledgeRequested: @escaping () -> Void = {}
    ) {
        self.model = model
        self.store = model.store
        self.activityStore = model.activityStore
        self.knowledgeStore = model.knowledgeStore
        self.library = model.knowledgeLibrary
        self.onTaskHoverChanged = onTaskHoverChanged
        self.onTaskFocusChanged = onTaskFocusChanged
        self.onTaskDetailRequested = onTaskDetailRequested
        self.onTaskPositionChanged = onTaskPositionChanged
        self.onDismissTaskDetail = onDismissTaskDetail
        self.onKnowledgeRequested = onKnowledgeRequested
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground()
            }
        }
        .clipShape(RoundedRectangle(
            cornerRadius: CodexBarPanelLayout.cornerRadius,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(
                cornerRadius: CodexBarPanelLayout.cornerRadius,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.28)
                .offset(y: CodexBarPanelLayout.headerHeight)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.visibleRows)
        .onExitCommand(perform: onDismissTaskDetail)
        .onDisappear(perform: onDismissTaskDetail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CodexBar VS Code 任务")
        .accessibilityValue("\(model.visibleRows.count) 个工作区")
    }

    private var header: some View {
        HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                PanelDragHandle()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("CodexBar")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: onKnowledgeRequested) {
                Image(systemName: "book.closed")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24, alignment: .center)
                    .overlay(alignment: .topTrailing) {
                        if library.unseenChangeCount > 0 {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                                .padding(2)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("知识库")
            .accessibilityValue("\(library.unseenChangeCount) 篇今日新增文章未查看")
            .accessibilityHint("打开知识库列表，点击某个知识库查看文章并清除该库提醒")
            .accessibilityInputLabels(["知识库", "打开知识库"])
            .accessibilityIdentifier("knowledge-library-open")
            .help(library.unseenChangeCount > 0 ? "\(library.unseenChangeCount) 篇今日新增文章，点击查看" : "知识库 · 今日新增")
            Menu {
                Menu("连接与设置") {
                    Text(model.connectionStatusMessage)
                    Text("待处理事件：\(model.inboxHealth.pendingCount)")
                    if model.inboxHealth.discardedCount > 0 {
                        Text("历史积压累计裁剪：\(model.inboxHealth.discardedCount)")
                    }
                    Divider()
                    Button("安装或更新任务连接…", action: model.installTaskConnection)
                        .help("在终端合并 Codex Hook 配置；随后需要在 Codex 中审核")
                    Button("刷新连接与任务", action: model.refreshOpenTasks)
                        .disabled(model.isRecoveringOpenTasks)
                    Button("连接指南", action: model.openConnectionGuide)
                    Button("辅助功能设置", action: model.openAccessibilitySettings)
                }
                Button("知识库…", action: onKnowledgeRequested)
                Button(model.isRecoveringOpenTasks ? "正在刷新任务…" : "刷新 VS Code 任务", action: model.refreshOpenTasks)
                    .disabled(model.isRecoveringOpenTasks)
                    .accessibilityLabel("刷新已打开的 VS Code Codex 任务")
                    .accessibilityValue(model.isRecoveringOpenTasks ? "正在同步已打开的 VS Code Codex 任务" : "就绪")
                Divider()
                Button("清除已读", action: model.clearRead)
                    .disabled(!model.visibleTasks.contains { $0.status == .ready && !$0.isUnread })
                Button("清除 7 天前不可匹配任务", action: model.clearOldUnmatchedTasks)
                Picker("显示模式", selection: Binding(
                    get: { model.panelDisplayMode },
                    set: { model.setPanelDisplayMode($0) }
                )) {
                    Text("固定高度（滚动）").tag(CodexBarPanelDisplayMode.scrolling)
                    Text("自动展开").tag(CodexBarPanelDisplayMode.expanded)
                }
                Menu("移动悬浮条") {
                    Button("左上", action: { model.placePanel(.topLeft) })
                    Button("右上", action: { model.placePanel(.topRight) })
                    Button("左下", action: { model.placePanel(.bottomLeft) })
                    Button("右下", action: { model.placePanel(.bottomRight) })
                }
                Divider()
                Button("辅助功能设置", action: model.openAccessibilitySettings)
                Button("退出 CodexBar", action: model.quit)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24, alignment: .center)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .accessibilityLabel("CodexBar 菜单")
        }
        .padding(.leading, 6)
        .padding(.trailing, 4)
        .frame(height: CodexBarPanelLayout.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        let rows = model.visibleRows
        let rowCount = rows.count
        VStack(spacing: 0) {
            if let notice = model.notice {
                noticeView(notice)
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.25)
                    }
            }

            if rowCount == 0 {
                VStack(spacing: 2) {
                    Text(model.hasNoOpenWindows ? "未打开 VS Code" : "等待 Codex 任务")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("打开知识库", action: onKnowledgeRequested)
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.link)
                        .frame(minHeight: 24)
                        .accessibilityIdentifier("knowledge-library-empty-open")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    if model.panelDisplayMode == .expanded,
                       model.visibleRowHeights.reduce(0, +) <= geometry.size.height {
                        VStack(spacing: 0) {
                            taskGroups(model.visibleGroups)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                taskGroups(model.visibleGroups)
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
            }
        }
    }

    private func taskGroups(_ groups: [GitWorkspaceGroup]) -> some View {
        ForEach(groups) { group in
            if let repositoryName = group.repositoryName {
                GitRepositoryHeader(name: repositoryName)
            }
            let parents = Set(group.rows.compactMap(\.parentRowID))
            ForEach(group.rows) { treeRow in
                let row = treeRow.row
                let task = row.task
                CompactTaskRow(
                    treeRow: treeRow,
                    hasChildren: parents.contains(row.id),
                    activities: activityStore.nodes(for: task),
                    plan: activityStore.plan(for: task),
                    knowledgePendingCount: knowledgeStore.pendingCounts[task.sessionID] ?? 0,
                    coordinateSpaceName: Self.coordinateSpaceName,
                    action: { model.activate(row) },
                    focusAction: { model.activate(row, minimizeOtherWindows: true) },
                    deleteAction: { model.remove(task) },
                    onHoverChanged: onTaskHoverChanged,
                    onFocusChanged: onTaskFocusChanged,
                    onDetailRequested: onTaskDetailRequested,
                    onPositionChanged: onTaskPositionChanged
                )
            }
        }
    }

    private func noticeView(_ notice: PanelNotice) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(notice.message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if notice.showsAccessibilityAction {
                    Button("去设置", action: model.requestAccessibilityPermission)
                        .buttonStyle(.link)
                        .font(.system(size: 10, weight: .medium))
                        .frame(minHeight: 24)
                }
                Spacer(minLength: 2)
                Button(action: model.dismissNotice) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(height: CodexBarPanelLayout.noticeHeight)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}

private struct PanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PanelDragHandleView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class PanelDragHandleView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct CompactTaskRow: View {
    private enum FocusedControl: Hashable {
        case task
        case menu
    }

    let treeRow: GitWorkspaceTreeRow
    let hasChildren: Bool
    private var row: VSCodeTaskRow { treeRow.row }
    private var task: CodexTask { row.task }
    private var workspaceLabel: GitWorkspaceLabel? { treeRow.label }
    let activities: [CodexTaskActivity]
    let plan: CodexTaskPlan?
    let knowledgePendingCount: Int
    let coordinateSpaceName: String
    let action: () -> Void
    let focusAction: () -> Void
    let deleteAction: () -> Void
    let onHoverChanged: (VSCodeTaskRow, CGFloat, Bool) -> Void
    let onFocusChanged: (VSCodeTaskRow, CGFloat, Bool) -> Void
    let onDetailRequested: (VSCodeTaskRow, CGFloat) -> Void
    let onPositionChanged: (VSCodeTaskRow, CGFloat) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isHovered = false
    @FocusState private var focusedControl: FocusedControl?

    private var rowHeight: CGFloat {
        CodexBarPanelLayout.rowHeight(for: treeRow)
    }

    private var workspaceDescription: String {
        guard let workspaceLabel else {
            return row.displayName + (row.isMultiRoot ? "，多项目工作区" : "")
        }
        return "\(workspaceLabel.repositoryName)，\(row.displayName)，分支 \(workspaceLabel.branch)"
            + (workspaceLabel.isLinkedWorktree ? "，关联工作树" : "，主工作目录")
            + (workspaceLabel.sourceBranch.map { "，创建自 \($0)" } ?? "")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let accessibilityTimeText = CodexTaskTimeFormatter.accessibilityText(
                for: task,
                relativeTo: context.date
            )
            let summary = CodexTaskDetailSummary(task: task, plan: plan, activities: activities)

            GeometryReader { geometry in
                let rowMidY = geometry.frame(in: .named(coordinateSpaceName)).midY

                ZStack(alignment: .topTrailing) {
                    Button(action: action) {
                        GitWorkspaceRowContent(
                            treeRow: treeRow,
                            hasChildren: hasChildren,
                            statusSymbol: task.status.symbolName,
                            statusColor: task.status.color,
                            knowledgePendingCount: knowledgePendingCount,
                            showsWorktreeBadge: !showsTaskMenu
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focusedControl, equals: .task)
                    .accessibilityLabel(
                        "\(workspaceDescription)，\(task.status.label)，\(task.title)"
                    )
                    .accessibilityValue(
                        "\(task.isUnread ? "未读，" : "")\(accessibilityTimeText)"
                            + "，\(summary.accessibilitySummary)"
                            + (knowledgePendingCount > 0 ? "，\(knowledgePendingCount) 篇笔记待回看" : "")
                    )
                    .accessibilityHint("切换到对应的 VS Code 窗口，按右方向键查看任务详情")
                    .accessibilityInputLabels([row.displayName, workspaceLabel?.branch ?? row.displayName, task.title])
                    .help("\(workspaceDescription)\n\(row.rootPath)")

                    Menu {
                        Button("查看任务详情") { onDetailRequested(row, rowMidY) }
                        Button("专注此项目（最小化其他窗口）", action: focusAction)
                            .accessibilityHint("切换到此项目并最小化其他 VS Code 窗口")
                        Button("删除当前任务", role: .destructive, action: deleteAction)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 9, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                            .overlay {
                                if focusedControl == .menu {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .stroke(Color.accentColor, lineWidth: 1.5)
                                        .padding(2)
                                }
                            }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24, height: 24)
                    .padding(.trailing, 4)
                    .padding(.top, (rowHeight - 24) / 2)
                    .focused($focusedControl, equals: .menu)
                    .opacity(showsTaskMenu ? 1 : 0)
                    .allowsHitTesting(showsTaskMenu)
                    .accessibilityLabel("\(workspaceDescription) 任务菜单")
                }
                .frame(width: geometry.size.width, height: rowHeight)
                .background {
                    if isHovered || isRowFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .padding(.horizontal, 3)
                    }
                }
                .overlay {
                    if isRowFocused {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                    }
                }
                .contentShape(Rectangle())
                .onAppear {
                    onPositionChanged(row, rowMidY)
                }
                .onHover { hovering in
                    isHovered = hovering
                    onHoverChanged(row, rowMidY, hovering)
                }
                .onChange(of: focusedControl) { focusedControl in
                    onFocusChanged(row, rowMidY, focusedControl != nil)
                }
                .onChange(of: rowMidY) { position in
                    onPositionChanged(row, position)
                }
                .onChange(of: task.id) { _ in
                    if isHovered { onHoverChanged(row, rowMidY, true) }
                    if isRowFocused { onFocusChanged(row, rowMidY, true) }
                }
                .onMoveCommand { direction in
                    if direction == .right { onDetailRequested(row, rowMidY) }
                }
                .contextMenu {
                    Button("查看任务详情") { onDetailRequested(row, rowMidY) }
                    Button("专注此项目（最小化其他窗口）", action: focusAction)
                        .accessibilityHint("切换到此项目并最小化其他 VS Code 窗口")
                    Button("删除当前任务", role: .destructive, action: deleteAction)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private var showsTaskMenu: Bool {
        isHovered || isRowFocused || voiceOverEnabled
    }

    private var isRowFocused: Bool {
        focusedControl != nil
    }
}

struct TaskHoverDetailView: View {
    @ObservedObject private var model: CodexBarAppModel
    @ObservedObject private var store: TaskStore
    @ObservedObject private var activityStore: LiveTaskActivityStore
    @ObservedObject private var previewStore: ConversationPreviewStore
    @ObservedObject private var knowledgeStore: KnowledgeReviewStore

    let rowID: String
    let onOpen: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onPreferredHeightChanged: (CGFloat) -> Void
    let onDismiss: () -> Void
    let onRefreshPreview: () -> Void
    let onLoadHistory: () -> Void
    let onToggleReview: (KnowledgeNoteChange, CodexTask) -> Void
    let onOpenNote: (KnowledgeNoteChange, CodexTask) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        model: CodexBarAppModel,
        store: TaskStore,
        activityStore: LiveTaskActivityStore,
        previewStore: ConversationPreviewStore,
        knowledgeStore: KnowledgeReviewStore,
        rowID: String,
        onRefreshPreview: @escaping () -> Void,
        onLoadHistory: @escaping () -> Void,
        onToggleReview: @escaping (KnowledgeNoteChange, CodexTask) -> Void,
        onOpenNote: @escaping (KnowledgeNoteChange, CodexTask) -> Void,
        onOpen: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void,
        onPreferredHeightChanged: @escaping (CGFloat) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.model = model
        self.store = store
        self.activityStore = activityStore
        self.previewStore = previewStore
        self.knowledgeStore = knowledgeStore
        self.rowID = rowID
        self.onOpen = onOpen
        self.onHoverChanged = onHoverChanged
        self.onPreferredHeightChanged = onPreferredHeightChanged
        self.onDismiss = onDismiss
        self.onRefreshPreview = onRefreshPreview
        self.onLoadHistory = onLoadHistory
        self.onToggleReview = onToggleReview
        self.onOpenNote = onOpenNote
    }

    var body: some View {
        Group {
            if let row = model.visibleRows.first(where: { $0.id == rowID }) {
                let task = row.task
                let summary = CodexTaskDetailSummary(
                    task: task,
                    plan: activityStore.plan(for: task),
                    activities: activityStore.nodes(for: task)
                )
                let preview = previewStore.preview.flatMap { candidate in
                    candidate.sessionID == task.sessionID && candidate.cwd == task.cwd ? candidate : nil
                }
                TaskDetailCard(
                    task: task,
                    summary: summary,
                    preview: preview,
                    state: previewStore.state,
                    message: previewStore.message,
                    isLoadingHistory: previewStore.isLoadingHistory,
                    onOpen: onOpen,
                    onRefreshPreview: onRefreshPreview,
                    onLoadHistory: onLoadHistory,
                    workspaceLabel: model.workspaceLabel(for: row),
                    workspaceRow: row,
                    knowledge: knowledgeStore.review(for: task),
                    onToggleReview: { onToggleReview($0, task) },
                    onOpenNote: { onOpenNote($0, task) }
                )
                .id(task.sessionID)
            } else {
                Color.clear
            }
        }
        .frame(width: CodexBarPanelLayout.detailWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                VisualEffectBackground()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .onHover(perform: onHoverChanged)
        .onAppear { onPreferredHeightChanged(520) }
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.visibleRows.first(where: { $0.id == rowID })?.displayName ?? "任务") 任务详情")
    }
}

extension CodexTaskActivityKind {
    var symbolName: String {
        switch self {
        case .read:
            return "book"
        case .search:
            return "magnifyingglass"
        case .edit:
            return "pencil"
        case .test:
            return "checkmark.diamond"
        case .command:
            return "terminal"
        case .agent:
            return "circle.hexagongrid.fill"
        }
    }
}

extension CodexTaskStatus {
    var label: String {
        switch self {
        case .running:
            return "执行中"
        case .needsAttention:
            return "需要处理"
        case .ready:
            return "可查看"
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "circle.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .ready:
            return "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .running:
            return .blue
        case .needsAttention:
            return .orange
        case .ready:
            return .green
        }
    }
}
