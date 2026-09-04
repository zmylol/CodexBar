import AppKit
import CodexBarCore
import SwiftUI

struct TaskListView: View {
    private static let coordinateSpaceName = "CodexBarPanel"

    @ObservedObject var model: CodexBarAppModel
    @ObservedObject private var store: TaskStore
    @ObservedObject private var activityStore: LiveTaskActivityStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let onTaskHoverChanged: (CodexTask, CGFloat, Bool) -> Void
    private let onTaskFocusChanged: (CodexTask, CGFloat, Bool) -> Void
    private let onDismissTaskDetail: () -> Void

    init(
        model: CodexBarAppModel,
        onTaskHoverChanged: @escaping (CodexTask, CGFloat, Bool) -> Void = { _, _, _ in },
        onTaskFocusChanged: @escaping (CodexTask, CGFloat, Bool) -> Void = { _, _, _ in },
        onDismissTaskDetail: @escaping () -> Void = {}
    ) {
        self.model = model
        self.store = model.store
        self.activityStore = model.activityStore
        self.onTaskHoverChanged = onTaskHoverChanged
        self.onTaskFocusChanged = onTaskFocusChanged
        self.onDismissTaskDetail = onDismissTaskDetail
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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: store.tasks)
        .onExitCommand(perform: onDismissTaskDetail)
        .onDisappear(perform: onDismissTaskDetail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CodexBar VS Code Codex 任务")
    }

    private var header: some View {
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                PanelDragHandle()
                HStack(spacing: 5) {
                    Text("CodexBar")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !store.tasks.isEmpty {
                        Text("· \(store.tasks.count)")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("共 \(store.tasks.count) 个任务")
                    }
                    Spacer(minLength: 2)
                    if store.tasks.contains(where: { $0.status == .needsAttention }) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.orange)
                            .help("有任务需要处理")
                            .accessibilityHidden(true)
                    }
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Menu {
                Button("清除已读", action: model.clearRead)
                    .disabled(!store.tasks.contains { $0.status == .ready && !$0.isUnread })
                Button("清除 7 天前不可匹配任务", action: model.clearOldUnmatchedTasks)
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
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("CodexBar 菜单")
            Button(action: model.refreshOpenTasks) {
                ZStack {
                    if model.isRecoveringOpenTasks {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .disabled(model.isRecoveringOpenTasks)
            .accessibilityLabel("刷新已打开的 VS Code Codex 任务")
            .accessibilityValue(model.isRecoveringOpenTasks
                ? "正在同步已打开的 VS Code Codex 任务"
                : "就绪")
            .accessibilityHint(model.isRecoveringOpenTasks
                ? "刷新完成后可再次使用"
                : "重新扫描所有已打开的 VS Code 窗口并更新任务列表")
            .accessibilityInputLabels(["刷新任务", "刷新"])
            .help("刷新已打开的 VS Code Codex 任务")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: CodexBarPanelLayout.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        let sortedTasks = store.sortedTasks
        VStack(spacing: 0) {
            if let notice = model.notice {
                noticeView(notice)
                    .overlay(alignment: .bottom) {
                        Divider().opacity(0.25)
                    }
            }

            if sortedTasks.isEmpty {
                Text("等待 VS Code Codex 事件")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedTasks, id: \.cwd) { task in
                            CompactTaskRow(
                                task: task,
                                activitySummary: activityStore.nodes(for: task).last?.summary,
                                plan: activityStore.plan(for: task),
                                coordinateSpaceName: Self.coordinateSpaceName,
                                action: { model.activate(task) },
                                deleteAction: { model.remove(task) },
                                onHoverChanged: onTaskHoverChanged,
                                onFocusChanged: onTaskFocusChanged
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
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
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct CompactTaskRow: View {
    private enum FocusedControl: Hashable {
        case task
        case menu
    }

    let task: CodexTask
    let activitySummary: String?
    let plan: CodexTaskPlan?
    let coordinateSpaceName: String
    let action: () -> Void
    let deleteAction: () -> Void
    let onHoverChanged: (CodexTask, CGFloat, Bool) -> Void
    let onFocusChanged: (CodexTask, CGFloat, Bool) -> Void

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isHovered = false
    @FocusState private var focusedControl: FocusedControl?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let accessibilityTimeText = CodexTaskTimeFormatter.accessibilityText(
                for: task,
                relativeTo: context.date
            )
            let accessibilityProgressText = plan.map {
                "，\(planAccessibilitySummary($0))"
            } ?? activitySummary.map {
                "，最近动作，\($0)"
            } ?? ""

            GeometryReader { geometry in
                let rowMidY = geometry.frame(in: .named(coordinateSpaceName)).midY

                HStack(spacing: 0) {
                    Button(action: action) {
                        HStack(spacing: 7) {
                            Image(systemName: task.status.symbolName)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(task.status.color)
                                .frame(width: 10)
                                .accessibilityHidden(true)
                            Text(task.workspaceName)
                                .font(.system(
                                    size: 12,
                                    weight: task.isUnread ? .semibold : .medium
                                ))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 2)
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                        .frame(height: CodexBarPanelLayout.rowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($focusedControl, equals: .task)
                    .accessibilityLabel(
                        "\(task.workspaceName)，\(task.status.label)，\(task.title)"
                    )
                    .accessibilityValue(
                        "\(task.isUnread ? "未读，" : "")\(accessibilityTimeText)"
                            + accessibilityProgressText
                    )
                    .accessibilityHint("切换到对应的 VS Code 窗口")
                    .accessibilityInputLabels([task.workspaceName, task.title])

                    Menu {
                        Button("删除任务", role: .destructive, action: deleteAction)
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
                    .fixedSize()
                    .focused($focusedControl, equals: .menu)
                    .opacity(showsTaskMenu ? 1 : 0)
                    .allowsHitTesting(showsTaskMenu)
                    .accessibilityLabel("\(task.workspaceName) 任务菜单")
                }
                .frame(height: CodexBarPanelLayout.rowHeight)
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
                .onHover { hovering in
                    isHovered = hovering
                    onHoverChanged(task, rowMidY, hovering)
                }
                .onChange(of: focusedControl) { focusedControl in
                    onFocusChanged(task, rowMidY, focusedControl != nil)
                }
                .contextMenu {
                    Button("删除任务", role: .destructive, action: deleteAction)
                }
            }
        }
        .frame(height: CodexBarPanelLayout.rowHeight)
    }

    private func planAccessibilitySummary(_ plan: CodexTaskPlan) -> String {
        let overview: String
        if plan.isComplete {
            overview = "计划已完成，共 \(plan.totalStepCount) 步"
        } else if let currentStep = plan.currentStep {
            overview = "当前第 \(plan.currentStepNumber) 步，共 \(plan.totalStepCount) 步；"
                + "已完成 \(plan.completedStepCount) 步；当前：\(currentStep.title)"
        } else {
            overview = "等待第 \(plan.currentStepNumber) 步，共 \(plan.totalStepCount) 步；"
                + "已完成 \(plan.completedStepCount) 步"
        }
        let visibleSteps = plan.visibleSteps(
            maximumCount: CodexBarPanelLayout.maximumVisiblePlanSteps
        ).map { step in
            "\(step.status.accessibilityLabel)：\(step.title)"
        }.joined(separator: "；")
        return visibleSteps.isEmpty ? overview : "\(overview)；可见步骤：\(visibleSteps)"
    }

    private var showsTaskMenu: Bool {
        isHovered || isRowFocused || voiceOverEnabled
    }

    private var isRowFocused: Bool {
        focusedControl != nil
    }
}

struct TaskHoverDetailView: View {
    @ObservedObject private var store: TaskStore
    @ObservedObject private var activityStore: LiveTaskActivityStore

    let cwd: String
    let onOpen: () -> Void
    let onHoverChanged: (Bool) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        store: TaskStore,
        activityStore: LiveTaskActivityStore,
        cwd: String,
        onOpen: @escaping () -> Void,
        onHoverChanged: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.store = store
        self.activityStore = activityStore
        self.cwd = cwd
        self.onOpen = onOpen
        self.onHoverChanged = onHoverChanged
        self.onDismiss = onDismiss
    }

    var body: some View {
        Group {
            if let task = store.tasks.first(where: { $0.cwd == cwd }) {
                if let plan = activityStore.plan(for: task) {
                    detailContent(
                        task: task,
                        nodes: [],
                        plan: plan,
                        relativeTo: Date()
                    )
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        detailContent(
                            task: task,
                            nodes: activityStore.nodes(for: task),
                            plan: nil,
                            relativeTo: context.date
                        )
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(
            width: CodexBarPanelLayout.detailWidth,
            height: CodexBarPanelLayout.detailHeight,
            alignment: .topLeading
        )
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
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .onHover(perform: onHoverChanged)
        .onExitCommand(perform: onDismiss)
        .accessibilityHidden(true)
    }

    private func detailContent(
        task: CodexTask,
        nodes: [CodexTaskActivity],
        plan: CodexTaskPlan?,
        relativeTo date: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: task.status.symbolName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(task.status.color)
                Text(task.workspaceName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(task.status.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(task.status.color)
            }

            Text(task.title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if let plan {
                    planList(plan)
                } else {
                    activityList(nodes, status: task.status, accent: task.status.color)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().opacity(0.32)

            HStack(spacing: 6) {
                if let plan {
                    HStack(spacing: 5) {
                        PlanProgressIndicator(
                            progressFraction: plan.progressFraction
                        )
                        Text(planProgressText(for: plan))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .background(task.status.color.opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(task.status.color.opacity(0.24), lineWidth: 1)
                    }
                } else {
                    Text(detailTimeText(for: task, relativeTo: date))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button(action: onOpen) {
                    Label("切换到 VS Code", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium))
                        .frame(minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
    }

    private func planList(_ plan: CodexTaskPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(plan.visibleSteps(
                maximumCount: CodexBarPanelLayout.maximumVisiblePlanSteps
            )) { step in
                HStack(spacing: 7) {
                    PlanStepIndicator(status: step.status)
                    Text(step.title)
                        .font(.system(
                            size: 11,
                            weight: step.status == .inProgress ? .medium : .regular
                        ))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(step.title)
                }
            }
        }
    }

    @ViewBuilder
    private func activityList(
        _ nodes: [CodexTaskActivity],
        status: CodexTaskStatus,
        accent: Color
    ) -> some View {
        if nodes.isEmpty {
            Label(
                status == .ready ? "暂无实时动作" : "等待 VS Code Codex 执行动作…",
                systemImage: status == .ready ? "minus" : "ellipsis"
            )
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(nodes) { node in
                    HStack(spacing: 6) {
                        Image(systemName: node.kind.symbolName)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(node.id == nodes.last?.id ? accent : .secondary)
                            .frame(width: 10)
                        Text(node.summary)
                            .font(.system(
                                size: 10,
                                weight: node.id == nodes.last?.id ? .medium : .regular
                            ))
                            .foregroundStyle(node.id == nodes.last?.id ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func detailTimeText(for task: CodexTask, relativeTo date: Date) -> String {
        let timeText = CodexTaskTimeFormatter.text(for: task, relativeTo: date)
        switch task.status {
        case .running:
            return "已运行 \(timeText)"
        case .needsAttention:
            return "\(timeText)需要处理"
        case .ready:
            return "\(timeText)变为可查看"
        }
    }

    private func planProgressText(for plan: CodexTaskPlan) -> String {
        if plan.isComplete {
            return "计划已完成 \(plan.totalStepCount) / \(plan.totalStepCount) 步"
        }
        if plan.currentStep == nil {
            return "等待第 \(plan.currentStepNumber) / \(plan.totalStepCount) 步"
        }
        return "第 \(plan.currentStepNumber) / \(plan.totalStepCount) 步"
    }
}

private struct PlanProgressIndicator: View {
    let progressFraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.35), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: min(max(CGFloat(progressFraction), 0), 1))
                .stroke(
                    Color.primary,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

private struct PlanStepIndicator: View {
    let status: CodexTaskPlanStepStatus

    var body: some View {
        Group {
            switch status {
            case .completed:
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            case .inProgress:
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 1.5)
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(
                            Color.primary,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
            case .pending:
                Circle()
                    .stroke(Color.primary, lineWidth: 1.25)
                    .frame(width: 9, height: 9)
                    .padding(1)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

private extension CodexTaskPlanStepStatus {
    var accessibilityLabel: String {
        switch self {
        case .completed:
            return "已完成"
        case .inProgress:
            return "当前"
        case .pending:
            return "待处理"
        }
    }
}

private extension CodexTaskActivityKind {
    var symbolName: String {
        switch self {
        case .read:
            return "doc.text"
        case .search:
            return "magnifyingglass"
        case .edit:
            return "pencil"
        case .test:
            return "checkmark.diamond"
        case .command:
            return "terminal"
        }
    }
}

private extension CodexTaskStatus {
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

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
