import AppKit
import CodexBarCore
import CodexBarWindowing
import Foundation
import os

@MainActor
final class CodexBarAppModel: NSObject, ObservableObject {
    @Published private(set) var panelDisplayMode = CodexBarPanelDisplayMode(
        rawValue: UserDefaults.standard.string(forKey: "codexbar.panelDisplayMode") ?? ""
    ) ?? .scrolling
    @Published private var taskVisibility = VSCodeTaskVisibility()
    @Published private(set) var isRecoveringOpenTasks = false
    @Published private(set) var runtimeConnectionState = CodexRuntimeConnectionState.idle
    @Published private(set) var workspaceLabels: [String: GitWorkspaceLabel] = [:]
    @Published private(set) var inboxHealth = CodexInboxHealth(pendingCount: 0, discardedCount: 0)
    @Published private(set) var notice: PanelNotice? {
        didSet {
            guard notice != oldValue else {
                return
            }
            notifyPresentationChanged(animated: true)
        }
    }

    let store: TaskStore
    let activityStore: LiveTaskActivityStore
    let previewStore = ConversationPreviewStore()
    let knowledgeStore = KnowledgeReviewStore()
    let knowledgeLibrary: KnowledgeLibraryModel
    var visibleTasks: [CodexTask] { taskVisibility.visibleTasks(in: store.tasks) }
    var visibleGroups: [GitWorkspaceGroup] {
        GitWorkspaceTree.groups(rows: taskVisibility.visibleRows(in: store.sortedTasks), labels: workspaceLabels)
    }
    var visibleRows: [VSCodeTaskRow] { visibleGroups.flatMap { $0.rows.map(\.row) } }
    var visibleRowHeights: [CGFloat] {
        CodexBarPanelLayout.rowHeights(groups: visibleGroups)
    }
    func workspaceLabel(for row: VSCodeTaskRow) -> GitWorkspaceLabel? {
        row.isMultiRoot ? nil : workspaceLabels[row.rootPath]
    }
    private var visibleGitRoots: Set<String> {
        Set(visibleRows.filter { !$0.isMultiRoot }.map(\.rootPath))
    }
    var hasNoOpenWindows: Bool { taskVisibility.hasNoOpenWindows }
    var connectionStatusMessage: String {
        guard AccessibilityAuthorization.isTrusted else { return "需要辅助功能授权" }
        if hasNoOpenWindows { return "未打开 VS Code 窗口" }
        switch runtimeConnectionState {
        case .idle: return "等待 VS Code 中的 Codex 任务"
        case .connecting: return "正在连接 Codex…"
        case .connected: return "已连接 Codex"
        case .retrying(let attempt): return "正在重新连接 Codex（第 \(attempt) 次）…"
        case .exhausted: return "连接暂不可用，请刷新重试"
        case .incompatible: return "Codex 扩展暂不兼容实时连接"
        }
    }
    var onPresentationChanged: ((Int, Bool, Bool) -> Void)?
    var onPanelPlacementRequested: ((PanelPlacement) -> Void)?
    var onAnnouncementRequested: ((String, Bool) -> Void)?

    private let processor: EventProcessor
    private let activator: AccessibilityWindowActivator
    private let threadSnapshotLoader: (any CodexThreadSnapshotLoading)?
    private let inboxMonitor: CodexInboxMonitor
    private let windowMonitor: VSCodeWindowMonitor
    private let runtimeMonitor = CodexRuntimeStatusMonitor()
    private let workspaceMonitor = GitWorkspaceMonitor()
    private lazy var previewCoordinator = ConversationPreviewCoordinator(store: previewStore, monitor: runtimeMonitor)
    private lazy var runtimeEvents = makeRuntimeEventCoordinator()
    private var knowledgeWorker = KnowledgeReviewWorker()
    private var knowledgeSynchronizationTask: Task<Void, Never>?
    private var knowledgeSessions: [String: String] = [:]
    private var knowledgeSynchronizationID: UUID?
    private let oldTaskCleanupWorker = OldTaskCleanupWorker()
    private var isStarted = false
    private var inboxNeedsProcessing = false
    private var inboxProcessingTask: Task<Void, Never>?
    private var inboxProcessingID: UUID?
    private var oldTaskCleanupTask: Task<Void, Never>?
    private var oldTaskCleanupID: UUID?
    private var startupRecoveryTask: Task<Void, Never>?
    private var startupRecoveryID: UUID?
    private var accessibilityRecoveryTrigger = AccessibilityRecoveryTrigger()
    private let recoveryLogger = Logger(
        subsystem: "com.codexbar.CodexBar",
        category: "AppServerReconciliation"
    )
    private var nextRecoveryErrorLogAt = Date.distantPast
    private var windowActivationTask: Task<Void, Never>?
    private var windowScanTask: Task<Void, Never>?
    private var windowScanID: UUID?
    private var windowScanPending = false
    private var windowEventGeneration: UInt64 = 0
    private var needsWindowRecovery = false
    private var pendingRefreshCompletion = false
    private var reportedDiscardedEvents = 0

    init(
        store: TaskStore,
        activityStore: LiveTaskActivityStore,
        processor: EventProcessor,
        activator: AccessibilityWindowActivator,
        inboxMonitor: CodexInboxMonitor,
        windowMonitor: VSCodeWindowMonitor = VSCodeWindowMonitor(),
        threadSnapshotLoader: (any CodexThreadSnapshotLoading)? = nil,
        knowledgeLibrary: KnowledgeLibraryModel = KnowledgeLibraryModel()
    ) {
        self.store = store
        self.activityStore = activityStore
        self.processor = processor
        self.activator = activator
        self.inboxMonitor = inboxMonitor
        self.windowMonitor = windowMonitor
        self.threadSnapshotLoader = threadSnapshotLoader
        self.knowledgeLibrary = knowledgeLibrary
        super.init()
    }

    func start() {
        stop()
        isStarted = true
        knowledgeLibrary.start()
        workspaceMonitor.start(cwds: visibleGitRoots) { [weak self] labels in
            guard let self, isStarted else { return }
            workspaceLabels = labels
            notifyPresentationChanged(animated: true)
        }
        if store.recoverySnapshotURL != nil {
            showNotice(message: "任务状态文件损坏，已隔离并重建。")
        }
        startInboxMonitoring()
        runtimeEvents.start()
        runtimeMonitor.onConnectionStateChange = { [weak self] state in
            guard let self, isStarted else { return }
            runtimeConnectionState = state
            if state == .exhausted {
                showNotice(message: "Codex 连接暂不可用，请确认 VS Code 已打开，再从菜单刷新任务。")
            } else if state == .incompatible {
                showNotice(message: "Codex 扩展暂不兼容实时连接，请从菜单打开连接指南。")
            } else if state == .connected,
                      notice?.message == "Codex 连接暂不可用，请确认 VS Code 已打开，再从菜单刷新任务。"
                        || notice?.message == "Codex 扩展暂不兼容实时连接，请从菜单打开连接指南。" {
                notice = nil
            }
        }
        runtimeMonitor.start(onChange: { [weak self] data in
            guard let self else { return }
            runtimeEvents.enqueue(.frame(data, previewCoordinator.generation))
        }, onUnavailable: { [weak self] sessions in
            self?.runtimeEvents.enqueue(.unavailable(sessions))
        })
        synchronizeRuntimeSessions()
        windowMonitor.onStatusChange = { [weak self] status in
            guard let self, isStarted else { return }
            switch status {
            case .accessibilityPermissionRequired:
                accessibilityRecoveryTrigger.waitForGrant(reportCompletion: false)
                showNotice(
                    message: "需要辅助功能权限才能自动同步 VS Code 窗口。",
                    showsAccessibilityAction: true
                )
            case .failed:
                showNotice(message: "无法监听 VS Code 窗口变化，请点击刷新重试。")
            case .observing:
                if notice?.message == "无法监听 VS Code 窗口变化，请点击刷新重试。" {
                    notice = nil
                }
            case .stopped:
                break
            }
        }
        windowMonitor.start { [weak self] in
            self?.handleWindowEnvironmentChange()
        }
        processInbox()
        recoverStartupTasks(reportCompletion: false)
    }

    func stop() {
        isStarted = false
        knowledgeLibrary.stop()
        endConversationPreview()
        runtimeMonitor.onConnectionStateChange = nil
        runtimeMonitor.stop()
        workspaceMonitor.stop()
        workspaceLabels = [:]
        runtimeConnectionState = .idle
        runtimeEvents.stop()
        knowledgeSynchronizationTask?.cancel()
        knowledgeSynchronizationTask = nil
        knowledgeSynchronizationID = nil
        knowledgeSessions.removeAll()
        knowledgeWorker = KnowledgeReviewWorker()
        knowledgeStore.receive([:])
        inboxMonitor.stop()
        windowMonitor.stop()
        windowMonitor.onStatusChange = nil
        cancelStartupRecovery()
        windowScanTask?.cancel()
        windowScanTask = nil
        windowScanID = nil
        windowScanPending = false
        windowEventGeneration &+= 1
        needsWindowRecovery = false
        pendingRefreshCompletion = false
        inboxNeedsProcessing = false
        inboxProcessingTask?.cancel()
        inboxProcessingTask = nil
        inboxProcessingID = nil
        oldTaskCleanupTask?.cancel()
        oldTaskCleanupTask = nil
        oldTaskCleanupID = nil
        windowActivationTask?.cancel()
        windowActivationTask = nil
    }

    private func startInboxMonitoring() {
        do {
            try inboxMonitor.start { [weak self] in
                self?.processInbox()
            }
        } catch {
            showNotice(message: "无法监听任务事件，请点击刷新重试。")
        }
    }

    func activate(_ row: VSCodeTaskRow, minimizeOtherWindows: Bool = false) {
        let task = row.task
        windowActivationTask?.cancel()
        windowActivationTask = Task { [weak self] in
            guard let self else {
                return
            }
            let result = await activator.activateWindow(
                forCWD: task.cwd,
                workspace: row.workspace,
                promptForAccessibility: false,
                minimizeOtherWindows: minimizeOtherWindows
            )
            guard !Task.isCancelled else {
                return
            }
            await handleVSCodeActivationResult(result, for: task)
        }
    }

    private func handleVSCodeActivationResult(
        _ result: VSCodeWindowActivationResult,
        for task: CodexTask
    ) async {
        switch result {
        case .activated:
            do {
                _ = try await store.markRead(taskID: task.id)
                guard !Task.isCancelled else {
                    return
                }
                notice = nil
            } catch {
                showNotice(message: "已唤起 VS Code，但无法保存已读状态。")
            }
        case let .activatedWithUnminimizedWindows(_, windows):
            do {
                _ = try await store.markRead(taskID: task.id)
                guard !Task.isCancelled else {
                    return
                }
                showNotice(message: "已唤起目标窗口，但有 \(windows.count) 个其他 VS Code 窗口未能最小化。")
            } catch {
                showNotice(message: "已唤起 VS Code，但无法保存已读状态。")
            }
        case .accessibilityPermissionRequired:
            showNotice(
                message: "需要辅助功能权限才能唤起 VS Code 窗口。",
                showsAccessibilityAction: true,
                highPriority: true
            )
        case .applicationNotRunning:
            showNotice(message: "Visual Studio Code 当前未运行。")
        case .windowNotFound:
            showNotice(message: "未找到对应的 VS Code 窗口。")
        case .ambiguous:
            showNotice(message: "找到多个同名窗口，未进行切换。")
        case .activationFailed:
            showNotice(message: "找到了窗口，但无法将它置于前台。")
        }
    }

    func refreshOpenTasks() {
        startInboxMonitoring()
        runtimeMonitor.refresh()
        workspaceMonitor.refresh()
        synchronizeKnowledgeSessions(refresh: true)
        processInbox()
        windowMonitor.refreshObservers()
        guard AccessibilityAuthorization.isTrusted else {
            accessibilityRecoveryTrigger.waitForGrant(reportCompletion: true)
            showNotice(
                message: "需要辅助功能权限才能刷新 VS Code 任务。",
                showsAccessibilityAction: true,
                highPriority: true
            )
            return
        }
        recoverStartupTasks(reportCompletion: true)
    }

    func requestAccessibilityPermission() {
        _ = AccessibilityAuthorization.requestIfNeeded()
        openAccessibilitySettings()
    }

    func setPanelDisplayMode(_ mode: CodexBarPanelDisplayMode) {
        guard panelDisplayMode != mode else {
            return
        }
        panelDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "codexbar.panelDisplayMode")
        notifyPresentationChanged(animated: true)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        if !AccessibilityAuthorization.isTrusted {
            accessibilityRecoveryTrigger.waitForGrant(reportCompletion: false)
        }
        NSWorkspace.shared.open(url)
    }

    func openConnectionGuide() {
        guard let url = URL(string: "https://github.com/zmylol/CodexBar/blob/main/docs/USER_GUIDE.md#连接状态与排查") else { return }
        if !NSWorkspace.shared.open(url) { showNotice(message: "无法打开连接指南，请在项目 README 查看使用指南。") }
    }

    func installTaskConnection() {
        guard let command = Bundle.main.resourceURL?.appendingPathComponent("HookSetup/Install.command"),
              FileManager.default.isExecutableFile(atPath: command.path) else {
            showNotice(message: "当前运行方式没有安装助手，请使用已安装的 CodexBar.app 或按连接指南安装。")
            return
        }
        if !NSWorkspace.shared.open(command) {
            showNotice(message: "无法打开安装助手，请查看连接指南。")
        }
    }

    func remove(_ task: CodexTask) {
        cancelStartupRecovery()
        let store = self.store
        Task { [weak self] in
            defer { self?.performPendingWindowRecovery() }
            do {
                _ = try await store.remove(taskID: task.id)
                guard let self else {
                    return
                }
                notifyPresentationChanged(animated: true)
            } catch {
                self?.showNotice(message: "无法保存任务删除操作。")
            }
        }
    }

    func clearRead() {
        cancelStartupRecovery()
        let store = self.store
        Task { [weak self] in
            defer { self?.performPendingWindowRecovery() }
            do {
                _ = try await store.clearRead()
                guard let self else {
                    return
                }
                notifyPresentationChanged(animated: true)
            } catch {
                self?.showNotice(message: "无法保存清除已读操作。")
            }
        }
    }

    func clearOldUnmatchedTasks() {
        guard AccessibilityAuthorization.isTrusted else {
            showNotice(
                message: "需要辅助功能权限才能检查 VS Code 窗口。",
                showsAccessibilityAction: true,
                highPriority: true
            )
            return
        }

        guard oldTaskCleanupTask == nil else {
            return
        }
        let cleanupID = UUID()
        oldTaskCleanupID = cleanupID
        let activator = self.activator
        oldTaskCleanupTask = Task { [weak self] in
            let windowSnapshot = await activator.discoverWindowSnapshotAsync()
            guard let self, oldTaskCleanupID == cleanupID else {
                return
            }
            defer {
                if oldTaskCleanupID == cleanupID {
                    oldTaskCleanupTask = nil
                    oldTaskCleanupID = nil
                }
            }
            guard !Task.isCancelled else {
                return
            }
            guard let windows = windowSnapshot else {
                showNotice(message: "无法读取 VS Code 窗口，未清理任何任务。")
                return
            }

            let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
            let taskSnapshot = store.tasks
            let staleCandidates = await oldTaskCleanupWorker.staleTasks(
                tasks: taskSnapshot,
                windows: windows,
                cutoff: cutoff
            )
            guard !Task.isCancelled, oldTaskCleanupID == cleanupID else {
                return
            }
            do {
                let removedCount = try await store.removeUnchangedTasks(
                    staleCandidates,
                    olderThan: cutoff
                )
                guard !Task.isCancelled, oldTaskCleanupID == cleanupID else {
                    return
                }
                showNotice(message: removedCount == 0
                    ? "没有可清理的旧任务。"
                    : "已清理 \(removedCount) 条不可匹配的旧任务。")
            } catch {
                guard !Task.isCancelled, oldTaskCleanupID == cleanupID else {
                    return
                }
                showNotice(message: "无法保存旧任务清理操作。")
                return
            }
            notifyPresentationChanged(animated: true)
        }
    }

    func placePanel(_ placement: PanelPlacement) {
        onPanelPlacementRequested?(placement)
    }

    func dismissNotice() {
        notice = nil
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func handleWindowEnvironmentChange() {
        guard isStarted else { return }
        runtimeMonitor.retryDiscovery()
        workspaceMonitor.refresh()
        windowEventGeneration &+= 1
        if startupRecoveryTask == nil,
           accessibilityRecoveryTrigger.isWaitingForGrant,
           let recoveryRequest = accessibilityRecoveryTrigger.consumeGrant(
               isTrusted: AccessibilityAuthorization.isTrusted
           ) {
            recoverStartupTasks(
                reportCompletion: recoveryRequest.reportCompletion
            )
        }
        scanOpenWindows()
    }

    private func scanOpenWindows() {
        guard isStarted, AccessibilityAuthorization.isTrusted else {
            return
        }
        windowScanPending = true
        guard windowScanTask == nil else {
            return
        }
        let scanID = UUID()
        windowScanID = scanID
        windowScanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if windowScanID == scanID {
                    windowScanTask = nil
                    windowScanID = nil
                    performPendingWindowRecovery()
                }
            }
            while windowScanPending {
                windowScanPending = false
                let generation = windowEventGeneration
                let windows = await activator.discoverWindowSnapshotAsync()
                guard !Task.isCancelled, windowScanID == scanID else { return }
                guard generation == windowEventGeneration else {
                    windowScanPending = true
                    continue
                }
                guard let windows else { return }
                updateOpenWindows(windows)
            }
        }
    }

    private func performPendingWindowRecovery() {
        guard isStarted, needsWindowRecovery, startupRecoveryTask == nil,
              windowScanTask == nil else { return }
        let reportCompletion = pendingRefreshCompletion
        pendingRefreshCompletion = false
        recoverStartupTasks(reportCompletion: reportCompletion)
    }

    private func updateOpenWindows(
        _ windows: [VSCodeWindowDescriptor],
        requestsRecovery: Bool = true
    ) {
        let previousWorkspaces = Set(visibleTasks.map(\.cwd))
        guard taskVisibility.update(windows: windows) else { return }
        if windows.isEmpty {
            needsWindowRecovery = pendingRefreshCompletion
        } else if requestsRecovery {
            let matcher = VSCodeWindowMatcher()
            let hasUnknownWindow = windows.contains { window in
                !store.tasks.contains { task in
                    if case .notFound = matcher.match(normalizedCWD: task.cwd, windows: [window]) {
                        return false
                    }
                    return true
                }
            }
            if hasUnknownWindow || visibleTasks.contains(where: { !previousWorkspaces.contains($0.cwd) }) {
                needsWindowRecovery = true
            }
        }
        // Window activation errors are obsolete once the set of windows changes.
        if notice?.message == "未找到对应的 VS Code 窗口。"
            || notice?.message == "Visual Studio Code 当前未运行。" {
            notice = nil
        }
        notifyPresentationChanged(animated: false)
    }

    private func synchronizeRuntimeSessions() {
        guard isStarted else { return }
        if let target = previewCoordinator.target,
           !visibleTasks.contains(where: { $0.sessionID == target.sessionID && $0.cwd == target.cwd }) {
            endConversationPreview()
        }
        runtimeMonitor.setSessions(Set(visibleTasks.map(\.sessionID)))
        workspaceMonitor.setCWDs(visibleGitRoots)
        synchronizeKnowledgeSessions()
    }

    private func synchronizeKnowledgeSessions(refresh: Bool = false) {
        let tasks = visibleTasks
        let sessions = Dictionary(tasks.map { ($0.sessionID, $0.cwd) }, uniquingKeysWith: { _, latest in latest })
        guard refresh || sessions != knowledgeSessions else { return }
        knowledgeSessions = sessions
        knowledgeSynchronizationTask?.cancel()
        let synchronizationID = UUID()
        knowledgeSynchronizationID = synchronizationID
        let worker = knowledgeWorker
        knowledgeSynchronizationTask = Task { [weak self] in
            let update = await worker.synchronize(tasks: tasks, refresh: refresh)
            guard let self, isStarted, !Task.isCancelled,
                  knowledgeSynchronizationID == synchronizationID, knowledgeWorker === worker else { return }
            applyKnowledgeReview(update)
            // A missing owner must not leave an endless loading indicator.
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            let expired = await worker.expireLoading()
            guard !Task.isCancelled, knowledgeSynchronizationID == synchronizationID else { return }
            applyKnowledgeReview(expired)
        }
    }

    private func applyKnowledgeReview(_ update: KnowledgeReviewUpdate) {
        knowledgeStore.receive(update.reviews, revision: update.revision)
        for sessionID in update.requestedSnapshots { runtimeMonitor.requestSnapshot(sessionID: sessionID) }
    }

    func toggleKnowledgeReview(_ note: KnowledgeNoteChange, for task: CodexTask) {
        let worker = knowledgeWorker
        Task { [weak self] in
            let update = await worker.toggleReview(noteID: note.id, sessionID: task.sessionID, expectedVersion: note.version)
            guard let self, isStarted, knowledgeWorker === worker else { return }
            applyKnowledgeReview(update)
        }
    }

    func openObsidianNote(_ note: KnowledgeNoteChange, for task: CodexTask) {
        let worker = knowledgeWorker
        Task { [weak self] in
            let url = await worker.openURL(noteID: note.id, sessionID: task.sessionID)
            guard let self, isStarted, knowledgeWorker === worker else { return }
            guard let url else {
                showNotice(message: "这篇笔记已移动、删除或不在当前知识库中，无法打开。")
                return
            }
            if !NSWorkspace.shared.open(url) {
                showNotice(message: "无法打开 Obsidian，请确认已安装并打开过这个知识库。")
            }
        }
    }

    func beginConversationPreview(_ task: CodexTask) {
        guard isStarted else { return }
        previewCoordinator.begin(sessionID: task.sessionID, cwd: task.cwd)
    }

    func endConversationPreview() {
        previewCoordinator.end()
    }

    func refreshConversationPreview() {
        previewCoordinator.refresh()
    }

    func loadConversationHistory() {
        previewCoordinator.loadHistory()
    }

    private func makeRuntimeEventCoordinator() -> RuntimeEventCoordinator {
        let coordinator = RuntimeEventCoordinator()
        coordinator.onSnapshotNeeded = { [weak self] session in
            self?.runtimeMonitor.requestSnapshot(sessionID: session)
        }
        coordinator.onUpdates = { [weak self] updates in
            guard let self else { return }
            for update in updates where visibleTasks.contains(where: { $0.sessionID == update.sessionID }) {
                guard let turnID = update.turnID, let cwd = update.cwd else { continue }
                do {
                    let changed = try await store.applyRuntimeStatus(
                        sessionID: update.sessionID, turnID: turnID, cwd: cwd, status: update.status
                    )
                    guard !Task.isCancelled, isStarted else { return }
                    if changed { notifyPresentationChanged(animated: true) }
                } catch {
                    guard !Task.isCancelled, isStarted else { return }
                    showNotice(message: "无法保存实时任务状态，请点击刷新重试。")
                }
            }
        }
        coordinator.onFrame = { [weak self] data, session, generation in
            guard let self else { return }
            if let session, knowledgeStore.reviews[session] != nil {
                let worker = knowledgeWorker
                let update = await worker.consume(data)
                guard !Task.isCancelled, isStarted else { return }
                if knowledgeWorker === worker { applyKnowledgeReview(update) }
            }
            await previewCoordinator.consume(data, sessionID: session, generation: generation)
        }
        coordinator.onUnavailable = { [weak self] reasons in
            guard let self else { return }
            let worker = knowledgeWorker
            let update = await worker.unavailable(Set(reasons.keys))
            guard !Task.isCancelled, isStarted else { return }
            if knowledgeWorker === worker { applyKnowledgeReview(update) }
            if let target = previewCoordinator.target, let reason = reasons[target.sessionID] {
                previewCoordinator.invalidate(reason: reason)
            }
        }
        coordinator.onOverflow = { [weak self] in
            guard let self else { return }
            previewCoordinator.invalidate()
            // Serialize invalidation ahead of the replacement snapshots.
            runtimeEvents.enqueue(.unavailable(Dictionary(
                knowledgeSessions.keys.map { ($0, CodexRuntimeUnavailableReason.connectionUnavailable) },
                uniquingKeysWith: { first, _ in first }
            )))
            runtimeMonitor.refresh()
        }
        return coordinator
    }

    private func processInbox() {
        guard isStarted else { return }
        inboxNeedsProcessing = true
        guard inboxProcessingTask == nil else {
            return
        }
        let priorTasks = store.tasks
        let priorUpdatedAt = Dictionary(
            store.tasks.map { ($0.id, $0.updatedAt) },
            uniquingKeysWith: { max($0, $1) }
        )
        let processingID = UUID()
        inboxProcessingID = processingID
        let processor = self.processor
        inboxProcessingTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<Int, Error>
            do {
                var processedCount = 0
                repeat {
                    inboxNeedsProcessing = false
                    let count = try await processor.processPending()
                    guard !Task.isCancelled, inboxProcessingID == processingID else { return }
                    let health = try await processor.inboxHealth()
                    guard !Task.isCancelled, inboxProcessingID == processingID else { return }
                    if inboxHealth != health { inboxHealth = health }
                    processedCount += count
                    if count > 0 {
                        inboxNeedsProcessing = true
                    }
                } while inboxNeedsProcessing
                result = .success(processedCount)
            } catch {
                result = .failure(error)
            }

            guard inboxProcessingID == processingID else {
                return
            }
            inboxProcessingTask = nil
            inboxProcessingID = nil
            let hasQueuedEvent = inboxNeedsProcessing
            inboxNeedsProcessing = false
            defer {
                if hasQueuedEvent, isStarted, !Task.isCancelled {
                    processInbox()
                }
            }
            guard !Task.isCancelled else {
                return
            }

            let processedCount: Int
            switch result {
            case let .success(count):
                processedCount = count
            case .failure:
                showNotice(message: "事件 Inbox 处理失败；文件已保留以便重试。")
                return
            }
            synchronizeRuntimeSessions()
            runtimeMonitor.retryDiscovery()
            runtimeEvents.enqueue(.reconcile)
            if inboxHealth.discardedCount > reportedDiscardedEvents {
                reportedDiscardedEvents = inboxHealth.discardedCount
                showNotice(message: "积压事件已按保留期限和容量裁剪；正在重新核对当前任务，旧进展可能不完整。")
                recoverStartupTasks(reportCompletion: false)
            }
            guard processedCount > 0 else {
                return
            }
            guard store.tasks != priorTasks else {
                return
            }
            let shouldAnimate = store.tasks.contains { task in
                guard task.status == .needsAttention || task.status == .ready else {
                    return false
                }
                return priorUpdatedAt[task.id] != task.updatedAt
            }
            notifyPresentationChanged(animated: shouldAnimate)
            let changedTasks = visibleTasks.filter { priorUpdatedAt[$0.id] != $0.updatedAt }
            if let attention = changedTasks.first(where: { $0.status == .needsAttention }) {
                onAnnouncementRequested?("\(attention.workspaceName) 需要处理", true)
            } else if let ready = changedTasks.first(where: { $0.status == .ready }) {
                onAnnouncementRequested?("\(ready.workspaceName) 可查看", false)
            }
        }
    }

    private func recoverStartupTasks(reportCompletion: Bool) {
        guard isStarted else { return }
        guard AccessibilityAuthorization.isTrusted else {
            accessibilityRecoveryTrigger.waitForGrant(
                reportCompletion: reportCompletion
            )
            return
        }
        accessibilityRecoveryTrigger.prepareForAuthorizedRecovery()
        dismissAccessibilityNotice()
        guard startupRecoveryTask == nil else {
            needsWindowRecovery = true
            pendingRefreshCompletion = pendingRefreshCompletion || reportCompletion
            return
        }
        needsWindowRecovery = false
        let priorVisibleTasks = visibleTasks
        isRecoveringOpenTasks = true
        let recoveryID = UUID()
        startupRecoveryID = recoveryID
        let activator = self.activator

        startupRecoveryTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if startupRecoveryID == recoveryID {
                    startupRecoveryTask = nil
                    startupRecoveryID = nil
                    isRecoveringOpenTasks = false
                    performPendingWindowRecovery()
                }
            }

            do {
                let reconciler = StartupTaskReconciler(store: store)
                let initialGeneration = windowEventGeneration
                let windowSnapshot = await activator.discoverWindowSnapshotAsync()
                guard !Task.isCancelled,
                      startupRecoveryID == recoveryID
                else {
                    return
                }
                guard initialGeneration == windowEventGeneration else {
                    needsWindowRecovery = true
                    pendingRefreshCompletion = pendingRefreshCompletion || reportCompletion
                    return
                }
                guard let windows = windowSnapshot else {
                    showRefreshFeedback(.failed, reportCompletion: reportCompletion)
                    return
                }
                updateOpenWindows(windows, requestsRecovery: false)
                guard !windows.isEmpty else {
                    showRefreshFeedback(.noOpenWindows, reportCompletion: reportCompletion)
                    return
                }
                guard let threadSnapshotLoader else {
                    showRefreshFeedback(.failed, reportCompletion: reportCompletion)
                    return
                }
                let snapshots: [CodexThreadSnapshot]
                do {
                    snapshots = try await threadSnapshotLoader.loadSnapshots(
                        matching: windows
                    )
                } catch {
                    guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                        return
                    }
                    logRecoveryFailureIfNeeded()
                    showRefreshFeedback(.failed, reportCompletion: reportCompletion)
                    return
                }
                guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                    return
                }
                let currentGeneration = windowEventGeneration
                let currentWindowSnapshot = await activator.discoverWindowSnapshotAsync()
                guard !Task.isCancelled,
                      startupRecoveryID == recoveryID
                else {
                    return
                }
                guard currentGeneration == windowEventGeneration else {
                    needsWindowRecovery = true
                    pendingRefreshCompletion = pendingRefreshCompletion || reportCompletion
                    return
                }
                guard let currentWindows = currentWindowSnapshot else {
                    showRefreshFeedback(.failed, reportCompletion: reportCompletion)
                    return
                }
                updateOpenWindows(currentWindows)
                guard !currentWindows.isEmpty else {
                    showRefreshFeedback(.noOpenWindows, reportCompletion: reportCompletion)
                    return
                }
                _ = try await reconciler.reconcile(
                    snapshots: snapshots,
                    windows: currentWindows
                )
                guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                    return
                }
                synchronizeRuntimeSessions()
                runtimeEvents.enqueue(.reconcile)
                let currentTasks = visibleTasks
                let changedCount = Set(
                    priorVisibleTasks.filter { !currentTasks.contains($0) }.map(\.id)
                        + currentTasks.filter { !priorVisibleTasks.contains($0) }.map(\.id)
                ).count
                if changedCount > 0 && !reportCompletion {
                    notifyPresentationChanged(animated: false)
                }
                showRefreshFeedback(
                    .completed(
                        currentWorkspaceCount: visibleRows.count,
                        changedCount: changedCount
                    ),
                    reportCompletion: reportCompletion
                )
            } catch {
                guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                    return
                }
                if reportCompletion {
                    showRefreshFeedback(.persistenceFailed, reportCompletion: true)
                } else {
                    showNotice(message: "检测到任务状态变化，但无法保存核对结果。")
                }
            }
        }
    }

    private func showRefreshFeedback(
        _ outcome: CodexTaskRefreshOutcome,
        reportCompletion: Bool
    ) {
        guard let message = CodexTaskRefreshFeedback.message(
            for: outcome,
            reportCompletion: reportCompletion
        ) else {
            return
        }
        showNotice(message: message, announceRepeated: true)
    }

    private func logRecoveryFailureIfNeeded(now: Date = Date()) {
        guard now >= nextRecoveryErrorLogAt else {
            return
        }
        recoveryLogger.error(
            "App Server reconciliation failed; Hook state remains authoritative."
        )
        nextRecoveryErrorLogAt = now.addingTimeInterval(60)
    }

    private func cancelStartupRecovery() {
        startupRecoveryTask?.cancel()
        startupRecoveryTask = nil
        startupRecoveryID = nil
        isRecoveringOpenTasks = false
    }

    private func dismissAccessibilityNotice() {
        guard notice?.showsAccessibilityAction == true else {
            return
        }
        notice = nil
    }

    private func showNotice(
        message: String,
        showsAccessibilityAction: Bool = false,
        highPriority: Bool = false,
        announceRepeated: Bool = false
    ) {
        guard announceRepeated || notice?.message != message else {
            return
        }
        notice = PanelNotice(
            message: message,
            showsAccessibilityAction: showsAccessibilityAction
        )
        onAnnouncementRequested?(message, highPriority)
    }

    private func notifyPresentationChanged(animated: Bool) {
        synchronizeRuntimeSessions()
        activityStore.synchronize(with: store.tasks)
        onPresentationChanged?(visibleRows.count, notice != nil, animated)
    }
}

struct PanelNotice: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var showsAccessibilityAction = false
}

private actor OldTaskCleanupWorker {
    private let matcher = VSCodeWindowMatcher()

    func staleTasks(
        tasks: [CodexTask],
        windows: [VSCodeWindowDescriptor],
        cutoff: Date
    ) -> [CodexTask] {
        var staleTasks: [CodexTask] = []
        for task in tasks {
            guard !Task.isCancelled else {
                return []
            }
            guard task.updatedAt < cutoff else {
                continue
            }
            if case .matched = matcher.match(cwd: task.cwd, windows: windows) {
                continue
            }
            staleTasks.append(task)
        }
        return staleTasks
    }
}
