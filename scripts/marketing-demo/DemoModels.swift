import AppKit
import CodexBarCore
import SwiftUI

// These in-memory substitutes intentionally replace the runtime-facing app models.
// No app monitor, file watcher, saved preference, URL opener or network client is created.
@MainActor final class TaskStore: ObservableObject {
    static let mainTaskID = "atlas-main"
    static let runtimeTaskID = "atlas-graph-runtime"
    static let uiTaskID = "atlas-graph-ui"
    static let studioTaskID = "studio"

    @Published var tasks: [CodexTask] = TaskStore.initialTasks()

    func resetTasks() { tasks = Self.initialTasks() }

    func setTaskStatus(id: String, status: CodexTaskStatus) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].status = status
        tasks[index].updatedAt = Date()
        tasks[index].isUnread = status == .ready
    }

    private static func initialTasks() -> [CodexTask] {
        [
            task(mainTaskID, name: "Atlas", folder: "atlas",
                 title: "项目看板已完成", status: .ready),
            task(runtimeTaskID, name: "Atlas Graph Runtime", folder: "atlas-graph-runtime",
                 title: "实现图任务调度", status: .running),
            task(uiTaskID, name: "Atlas Graph UI", folder: "atlas-graph-ui",
                 title: "确认图节点的交互方案", status: .needsAttention),
            task(studioTaskID, name: "Studio", folder: "studio",
                 title: "完成界面预览", status: .ready)
        ]
    }

    private static func task(
        _ id: String, name: String, folder: String, title: String, status: CodexTaskStatus
    ) -> CodexTask {
        CodexTask(id: id, sessionID: "demo-" + id, turnID: "demo-turn-" + id,
                  cwd: "/demo/projects/" + folder, workspaceName: name,
                  title: title, status: status, startedAt: Date().addingTimeInterval(-90),
                  updatedAt: Date(), isUnread: status == .ready)
    }
}

@MainActor final class KnowledgeReviewStore: ObservableObject {
    let pendingCounts: [String: Int] = [:]
    func review(for task: CodexTask) -> KnowledgeVaultReview? { nil }
}

struct PanelNotice {
    let message: String
    let showsAccessibilityAction: Bool
}

enum PanelPlacement { case topLeft, topRight, bottomLeft, bottomRight }

@MainActor final class CodexBarAppModel: ObservableObject {
    let store = TaskStore()
    let activityStore = LiveTaskActivityStore()
    let knowledgeStore = KnowledgeReviewStore()
    let knowledgeLibrary = KnowledgeLibraryModel()
    @Published var panelDisplayMode = CodexBarPanelDisplayMode.scrolling
    let isRecoveringOpenTasks = false
    let hasNoOpenWindows = false
    let notice: PanelNotice? = nil
    let connectionStatusMessage = "演示连接 · 虚构数据"
    let inboxHealth = CodexInboxHealth(pendingCount: 0, discardedCount: 0)
    var onActivate: (VSCodeTaskRow) -> Void = { _ in }
    var onRefresh: () -> Void = {}
    private let workspaceLabels: [String: GitWorkspaceLabel] = [
        "/demo/projects/atlas": GitWorkspaceLabel(
            repositoryName: "Atlas", branch: "main", shortBranch: "main",
            isLinkedWorktree: false, workspaceRoot: "/demo/projects/atlas",
            repositoryID: "/demo/projects/atlas/.git"
        ),
        "/demo/projects/atlas-graph-runtime": GitWorkspaceLabel(
            repositoryName: "Atlas", branch: "graph-runtime", shortBranch: "graph-r…",
            isLinkedWorktree: true, workspaceRoot: "/demo/projects/atlas-graph-runtime",
            sourceBranch: "main", repositoryID: "/demo/projects/atlas/.git"
        ),
        "/demo/projects/atlas-graph-ui": GitWorkspaceLabel(
            repositoryName: "Atlas", branch: "graph-ui", shortBranch: "graph-ui",
            isLinkedWorktree: true, workspaceRoot: "/demo/projects/atlas-graph-ui",
            sourceBranch: "graph-runtime", repositoryID: "/demo/projects/atlas/.git"
        )
    ]
    var visibleTasks: [CodexTask] { store.tasks }
    private var taskRows: [VSCodeTaskRow] {
        store.tasks.map { task in
            VSCodeTaskRow(id: "workspace:\(task.cwd)", displayName: task.workspaceName,
                          rootPath: task.cwd, isMultiRoot: false, task: task)
        }
    }
    var visibleGroups: [GitWorkspaceGroup] {
        GitWorkspaceTree.groups(rows: taskRows, labels: workspaceLabels)
    }
    var visibleRows: [VSCodeTaskRow] { visibleGroups.flatMap { $0.rows.map(\.row) } }
    var visibleRowHeights: [CGFloat] {
        CodexBarPanelLayout.rowHeights(groups: visibleGroups)
    }

    func workspaceLabel(for row: VSCodeTaskRow) -> GitWorkspaceLabel? { workspaceLabels[row.rootPath] }
    func row(forTaskID id: String) -> VSCodeTaskRow? { visibleRows.first { $0.task?.id == id } }
    func setTaskStatus(id: String, status: CodexTaskStatus) { store.setTaskStatus(id: id, status: status) }
    func resetTasks() { store.resetTasks() }
    func activate(_ row: VSCodeTaskRow, minimizeOtherWindows: Bool = false) { onActivate(row) }
    func remove(_ task: CodexTask) {}
    func refreshOpenTasks() { onRefresh() }
    func clearRead() {}
    func clearOldUnmatchedTasks() {}
    func setPanelDisplayMode(_ mode: CodexBarPanelDisplayMode) { panelDisplayMode = mode }
    func placePanel(_ placement: PanelPlacement) {}
    func openAccessibilitySettings() {}
    func openConnectionGuide() {}
    func installTaskConnection() {}
    func requestAccessibilityPermission() {}
    func dismissNotice() {}
    func quit() {}
}

@MainActor final class KnowledgeLibraryModel: ObservableObject {
    @Published var review: KnowledgeVaultReview? = KnowledgeVaultReview(
        vault: ObsidianVault(rootPath: "/demo/knowledge", name: "Demo Knowledge"),
        notes: [], isLoading: false, message: nil
    )
    @Published var sections = ["Anthropic", "Hugging Face", "LangChain", "Simon Willison"].map {
        KnowledgeFolderSection(relativePath: $0, name: $0, noteCount: 0)
    }
    @Published var todayArticles: [KnowledgeArticle] = []
    @Published private(set) var articleRange: KnowledgeArticleRange = .today
    @Published var seen: Set<String> = []
    let message: String? = nil
    let isLoading = false
    let isChoosingVault = false
    var onSeen: () -> Void = {}
    var onArrival: () -> Void = {}
    var unseenChangeCount: Int { todayArticles.filter { !seen.contains($0.id) }.count }
    var visibleArticles: [KnowledgeArticle] { articleRange == .yesterday ? [] : todayArticles }

    init() { reset() }

    func setArticleRange(_ range: KnowledgeArticleRange) { articleRange = range }

    func reset() {
        seen = []
        articleRange = .today
        todayArticles = [
            article("Anthropic/agents.md", "设计一个可靠的 Agent 工作流",
                    summary: "把需求拆成可验证的小任务，为每一步提供明确输入和完成条件。遇到无法确认的结果时暂停检查，让自动执行始终有据可查。"),
            article("Anthropic/context.md", "让上下文更好地服务下一次创造",
                    summary: "保留目标、已做决定和下一步需要的文件，把冗长过程压缩成简短交接。新一轮任务因此能接着做，也更容易发现遗漏的约束。"),
            article("Anthropic/tools.md", "工具调用：从想法走到可用产品",
                    summary: "给工具清晰的名称、参数和返回结果，并用真实任务检查调用是否有效。先打通一条完整使用流程，再根据失败案例逐步补齐能力。"),
            article("Hugging Face/models.md", "为小型项目选择合适的开放模型",
                    summary: "从任务效果、响应速度和运行内存三方面筛选模型。用项目自己的少量样本做对照，避免只凭排行榜选择超出部署预算的方案。"),
            article("Hugging Face/evaluation.md", "给你的 AI 功能建立评测集",
                    summary: "把常见输入、边界情况和已出现的错误整理成固定样本。每次调整模型或提示词后重复评测，确认改进没有破坏原本可用的行为。"),
            article("LangChain/memory.md", "为多步骤任务设计记忆",
                    summary: "区分当前任务进度和跨任务复用的知识，只保存后续确实需要的信息。为记忆记录来源与更新时间，减少旧结论干扰新的执行。")
        ]
    }

    private func article(_ path: String, _ title: String, summary: String) -> KnowledgeArticle {
        KnowledgeArticle(path: path, title: title, collectedAt: Date(), summary: summary)
    }

    func unseenCount(in sectionID: String) -> Int {
        visibleArticles.filter { $0.path.hasPrefix(sectionID + "/") && !seen.contains($0.id) }.count
    }

    func markUpdatesSeen(in sectionID: String) {
        seen.formUnion(visibleArticles.filter { $0.path.hasPrefix(sectionID + "/") }.map(\.id))
        onSeen()
    }

    func refresh() {
        guard !todayArticles.contains(where: { $0.path == "Anthropic/later.md" }) else { return }
        todayArticles.insert(article("Anthropic/later.md", "把原型打磨成日常工具",
                                     summary: "先观察自己每天重复的操作，再把最常用的一条路径做顺。通过真实使用补齐空状态、错误提示和快捷操作，让原型逐步成为可靠的日常工具。"), at: 0)
        onArrival()
    }

    func openArticle(_ article: KnowledgeArticle) {}
}

// Demo-only material samples the synthetic content of this opaque window.
// Production VisualEffectBackground.swift uses behindWindow and is not compiled here.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
