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
        }
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.28)
                .offset(y: CodexBarPanelLayout.headerHeight)
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
            Text("CodexBar")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 2)
            if store.tasks.contains(where: { $0.status == .needsAttention }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
                    .help("有任务需要处理")
                    .accessibilityHidden(true)
            }
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

private struct CompactTaskRow: View {
    private enum FocusedControl: Hashable {
        case task
        case menu
    }

    let task: CodexTask
    let activitySummary: String?
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
            let accessibilityActivityText = activitySummary.map {
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
                            + accessibilityActivityText
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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    detailContent(
                        task: task,
                        nodes: activityStore.nodes(for: task),
                        relativeTo: context.date
                    )
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

            activityList(nodes, status: task.status, accent: task.status.color)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)

            Divider().opacity(0.32)

            HStack(spacing: 6) {
                Text(detailTimeText(for: task, relativeTo: date))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
