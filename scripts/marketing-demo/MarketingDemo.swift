import AppKit
import CodexBarCore
import SwiftUI

@MainActor private final class DemoState: ObservableObject {
    @Published var scene = 0
    @Published var generation = 0
    @Published var selectedTaskID = TaskStore.uiTaskID
    let appModel = CodexBarAppModel()

    init() {
        appModel.onActivate = { [weak self] row in self?.activate(row) }
        appModel.knowledgeLibrary.onSeen = { [weak self] in
            if self?.scene == 4 { self?.scene = 5 }
        }
        appModel.knowledgeLibrary.onArrival = { [weak self] in self?.scene = 6 }
    }

    var selectedRow: VSCodeTaskRow {
        appModel.row(forTaskID: selectedTaskID) ?? appModel.visibleRows[0]
    }

    var selectedTask: CodexTask {
        appModel.store.tasks.first { $0.id == selectedTaskID } ?? appModel.store.tasks[0]
    }

    func activate(_ row: VSCodeTaskRow) {
        guard let task = row.task else { return }
        selectedTaskID = task.id
        scene = 2
    }

    func showPreview(_ row: VSCodeTaskRow) {
        guard let task = row.task else { return }
        selectedTaskID = task.id
        scene = 1
    }

    func continueTask() {
        appModel.setTaskStatus(id: selectedTaskID, status: .running)
        if selectedTaskID == TaskStore.uiTaskID {
            appModel.setTaskStatus(id: TaskStore.runtimeTaskID, status: .ready)
        }
        scene = 3
    }

    func next() {
        switch scene {
        case 0: showPreview(selectedRow)
        case 1: activate(selectedRow)
        case 2: continueTask()
        case 3: scene = 4
        case 4: scene = 5
        case 5: appModel.knowledgeLibrary.refresh()
        default: reset()
        }
    }

    func reset() {
        appModel.resetTasks()
        appModel.knowledgeLibrary.reset()
        selectedTaskID = TaskStore.uiTaskID
        generation += 1
        scene = 0
    }

    var title: String {
        ["多个任务，\n一眼分清。", "需要接手，\n先看上下文。", "点击分支，\n回到对应项目。", "继续推进，\n状态各自更新。",
         "新知识，\n有数可查。", "点开即看，\n提醒归零。", "新的文章，\n来了就知道。"][scene]
    }
    var detail: String {
        ["独立状态，父子分支。\n谁在执行、谁需要你，扫一眼就知道。",
         "读取当前分支的回复与工具输出。\n完整分支名、来源和路径就在详情里。",
         "main、graph-runtime、graph-ui，\n每个工作目录都有自己的入口。",
         "一个分支继续执行，另一个可以回看。\n同仓库保持成组，任务状态各自独立。",
         "按知识库分类，只看今日收录。\n数字告诉你还有几篇没看。",
         "标题和一段摘要，快速了解内容。\n点击知识库后，它的数字消失。",
         "稍后收录的文章带着摘要到达。\n刚看过的知识库也会再次提醒。"][scene]
    }
}

private struct MarketingDemoView: View {
    @ObservedObject var state: DemoState

    private var preview: CodexConversationPreview {
        let task = state.selectedTask
        let target = state.appModel.workspaceLabel(for: state.selectedRow)?.branch ?? state.selectedRow.displayName
        let progress: String
        switch task.status {
        case .needsAttention: progress = "方案已准备，等待你确认后继续实现。"
        case .running: progress = "当前正在执行，新的进展会继续出现在这里。"
        case .ready: progress = "本轮已停止，可以回到项目检查改动。"
        }
        return CodexConversationPreview(sessionID: task.sessionID, cwd: task.cwd, items: [
            CodexConversationItem(id: "request", kind: .user, title: "你",
                                  text: "继续 \(target) 的任务：\(task.title)。"),
            CodexConversationItem(id: "reply", kind: .assistant, title: "Codex",
                                  text: "### \(target) 的演示进展\n\(task.title)\n\n- 当前工作目录单独跟踪进度\n- 保留其他分支的任务状态\n- 改动与检查结果可以分别回看\n\n**\(progress)**"),
            CodexConversationItem(id: "tool", kind: .tool, title: "工具完成 · 演示检查",
                                  text: "✓ Independent branch state\n✓ Parent and child layout\n✓ Workspace target identity\n3 demo checks passed", detail: "$ run-demo-checks")
        ], historyComplete: true, revision: 1)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.055, blue: 0.10),
                                    Color(red: 0.09, green: 0.10, blue: 0.20),
                                    Color(red: 0.035, green: 0.13, blue: 0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.indigo.opacity(0.25)).frame(width: 540, height: 540)
                .blur(radius: 100).offset(x: 390, y: -240)
            Circle().fill(Color.teal.opacity(0.14)).frame(width: 470, height: 470)
                .blur(radius: 100).offset(x: 140, y: 280)

            VStack(alignment: .leading, spacing: 0) {
                masthead
                HStack(alignment: .center, spacing: 24) {
                    introduction.frame(width: 280, alignment: .leading)
                    stage.frame(width: 620, height: 548)
                }
                .frame(maxHeight: .infinity)
                footer
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
        }
        .frame(width: 1024, height: 760)
        .preferredColorScheme(.dark)
    }

    private var masthead: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(LinearGradient(colors: [.indigo, .teal], startPoint: .topLeading,
                                           endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
            Text("CodexBar").font(.system(size: 23, weight: .semibold, design: .rounded))
            Spacer()
            Text("KEEP THE VIBE. KEEP THE CONTEXT.")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(1.1).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(String(format: "%02d", state.scene < 4 ? state.scene + 1 : state.scene - 3) + (state.scene < 4 ? " / 04" : " / 03"))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(red: 0.47, green: 0.81, blue: 0.88))
            Text(state.title).font(.system(size: 37, weight: .semibold))
                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Text(state.detail).font(.system(size: 13)).lineSpacing(8)
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(0..<(state.scene < 4 ? 4 : 3), id: \.self) { index in
                    Capsule().fill(index == (state.scene < 4 ? state.scene : state.scene - 4) ? Color.teal : Color.white.opacity(0.15))
                        .frame(width: index == (state.scene < 4 ? state.scene : state.scene - 4) ? 26 : 7, height: 5)
                }
            }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var taskBarHeight: CGFloat {
        CodexBarPanelLayout.height(rowHeights: state.appModel.visibleRowHeights, noticeVisible: false, displayMode: .expanded)
    }

    @ViewBuilder private var stage: some View {
        if state.scene >= 4 {
            KnowledgeLibraryView(model: state.appModel.knowledgeLibrary,
                                 onChooseVault: {}, onHoverChanged: { _ in }, onClose: {})
                .id(state.generation)
                .frame(width: 600, height: 520)
                .shadow(color: .black.opacity(0.25), radius: 22, y: 14)
        } else if state.scene == 1 {
            HStack(alignment: .top, spacing: 14) {
                taskBar.frame(width: 126, height: taskBarHeight).padding(.top, 52)
                TaskDetailCard(task: state.selectedTask,
                               summary: CodexTaskDetailSummary(task: state.selectedTask, plan: nil, activities: []),
                               preview: preview, state: .ready, message: nil, isLoadingHistory: false,
                               onOpen: { state.activate(state.selectedRow) }, onRefreshPreview: {}, onLoadHistory: {},
                               workspaceLabel: state.appModel.workspaceLabel(for: state.selectedRow),
                               workspaceRow: state.selectedRow)
                    .frame(width: 420, height: 510)
                    .background(VisualEffectBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15)))
            }
            .shadow(color: .black.opacity(0.25), radius: 22, y: 14)
        } else if state.scene == 2 {
            HStack(alignment: .top, spacing: 18) {
                taskBar.frame(width: 126, height: taskBarHeight).padding(.top, 52)
                workspaceScene.frame(width: 420, height: 420)
            }
        } else {
            ZStack(alignment: .trailing) {
                projectBackdrop.frame(width: 450, height: 370)
                    .rotationEffect(.degrees(-3)).offset(x: -80, y: 18)
                VStack(spacing: 18) {
                    taskBar.frame(width: 126, height: taskBarHeight)
                        .scaleEffect(2.2)
                        .frame(width: 278, height: taskBarHeight * 2.2)
                    Text("原生任务条 · 放大展示")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                }.offset(x: -12, y: -5)
            }
        }
    }

    private var taskBar: some View {
        TaskListView(model: state.appModel,
                     onTaskHoverChanged: { _, _, _ in },
                     onTaskDetailRequested: { row, _ in state.showPreview(row) },
                     onKnowledgeRequested: { state.scene = 4 })
    }

    private var workspaceScene: some View {
        let row = state.selectedRow
        let branch = state.appModel.workspaceLabel(for: row)?.branch ?? row.displayName
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.75)).frame(width: 8, height: 8)
                }
                Text(state.appModel.workspaceLabel(for: row).map { $0.repositoryName + " · " + branch } ?? row.displayName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1).padding(.leading, 8)
                Spacer()
            }.padding(18)
            Divider().opacity(0.2)
            VStack(alignment: .leading, spacing: 18) {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.teal)
                Text(state.selectedTask.title)
                    .font(.system(size: 14, weight: .medium))
                Text("struct BranchCard: View {\n    let branch: Branch\n\n    var body: some View {\n        Text(branch.name)\n    }\n}")
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.7))
                Button("继续演示任务", action: state.continueTask)
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .accessibilityIdentifier("demo-continue-task")
                Text("虚构项目窗口 · 切换场景示意")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }.padding(24)
            Spacer(minLength: 0)
        }
        .background(Color(red: 0.07, green: 0.10, blue: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.18)))
    }

    private var projectBackdrop: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.65)).frame(width: 8, height: 8)
                }
                Text("ATLAS / BRANCH WORKSPACE").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.5).foregroundStyle(.white.opacity(0.4)).padding(.leading, 12)
                Spacer()
            }.padding(18)
            Divider().opacity(0.15)
            VStack(alignment: .leading, spacing: 15) {
                Text("main\n  └ graph-runtime\n       └ graph-ui")
                    .font(.system(size: 21, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.74))
                    .lineSpacing(4)
                ForEach([0.8, 1.0, 0.65], id: \.self) { width in
                    Capsule().fill(.white.opacity(0.07)).frame(width: 245 * width, height: 8)
                }
                Text("项目场景示意").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 10)
            }.padding(28)
            Spacer()
        }
        .background(Color(red: 0.08, green: 0.10, blue: 0.15).opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 18)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.teal)
            Text("原生界面 · 虚构数据 · 窗口场景示意")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.46))
            Spacer()
            Button("重播", action: state.reset)
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.45))
                .accessibilityIdentifier("demo-reset")
            Button(action: state.next) {
                Image(systemName: "arrow.right").frame(width: 30, height: 24)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).keyboardShortcut(.rightArrow, modifiers: [])
            .accessibilityLabel("下一幕").accessibilityIdentifier("demo-next")
        }
        .font(.system(size: 10))
    }
}

@main private struct MarketingDemo {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menuBar = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 CodexBar Public Demo",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        menuBar.addItem(appMenuItem)
        app.mainMenu = menuBar
        let state = DemoState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 760),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "CodexBar · Public Demo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isOpaque = true
        window.backgroundColor = NSColor(red: 0.035, green: 0.055, blue: 0.10, alpha: 1)
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: MarketingDemoView(state: state))
        host.sizingOptions = []
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
