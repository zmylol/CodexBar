import AppKit
import CodexBarCore
import CodexBarWindowing
import Foundation
import os

@MainActor
final class CodexBarAppModel: NSObject, ObservableObject {
    @Published private(set) var notice: PanelNotice? {
        didSet {
            guard notice != oldValue else {
                return
            }
            notifyPresentationChanged(animated: true)
        }
    }

    let store: TaskStore
    var onPresentationChanged: ((Int, Bool, Bool) -> Void)?
    var onPanelPlacementRequested: ((PanelPlacement) -> Void)?
    var onAnnouncementRequested: ((String, Bool) -> Void)?

    private let processor: EventProcessor
    private let activator: AccessibilityWindowActivator
    private let threadSnapshotLoader: (any CodexThreadSnapshotLoading)?
    private let oldTaskCleanupWorker = OldTaskCleanupWorker()
    private var pollTimer: Timer?
    private var inboxProcessingTask: Task<Void, Never>?
    private var inboxProcessingID: UUID?
    private var oldTaskCleanupTask: Task<Void, Never>?
    private var oldTaskCleanupID: UUID?
    private var startupRecoveryTask: Task<Void, Never>?
    private var startupRecoveryID: UUID?
    private var recoveryThrottle = TaskRecoveryThrottle(interval: 5)
    private let recoveryLogger = Logger(
        subsystem: "com.codexbar.CodexBar",
        category: "AppServerReconciliation"
    )
    private var nextRecoveryErrorLogAt = Date.distantPast
    private var windowActivationTask: Task<Void, Never>?

    init(
        store: TaskStore,
        processor: EventProcessor,
        activator: AccessibilityWindowActivator,
        threadSnapshotLoader: (any CodexThreadSnapshotLoading)? = nil
    ) {
        self.store = store
        self.processor = processor
        self.activator = activator
        self.threadSnapshotLoader = threadSnapshotLoader
    }

    func start() {
        stop()
        if store.recoverySnapshotURL != nil {
            showNotice(message: "任务状态文件损坏，已隔离并重建。")
        }
        processInbox()
        reconcileAppServerTasks(force: true)
        pollTimer = Timer.scheduledTimer(
            timeInterval: 0.75,
            target: self,
            selector: #selector(pollInbox),
            userInfo: nil,
            repeats: true
        )
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    func stop() {
        cancelStartupRecovery(resetThrottle: true)
        inboxProcessingTask?.cancel()
        inboxProcessingTask = nil
        inboxProcessingID = nil
        oldTaskCleanupTask?.cancel()
        oldTaskCleanupTask = nil
        oldTaskCleanupID = nil
        windowActivationTask?.cancel()
        windowActivationTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func activate(_ task: CodexTask) {
        windowActivationTask?.cancel()
        windowActivationTask = Task { [weak self] in
            guard let self else {
                return
            }
            let result = await activator.activateWindow(forCWD: task.cwd)
            guard !Task.isCancelled else {
                return
            }
            await handleActivationResult(result, for: task)
        }
    }

    private func handleActivationResult(
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

    func requestAccessibilityPermission() {
        _ = AccessibilityAuthorization.requestIfNeeded()
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func remove(_ task: CodexTask) {
        cancelStartupRecovery()
        let store = self.store
        Task { [weak self] in
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
            let windows = await activator.discoverWindowsAsync()
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

    @objc
    private func pollInbox() {
        processInbox()
        reconcileAppServerTasks(force: false)
    }

    private func processInbox() {
        guard inboxProcessingTask == nil else {
            return
        }
        let priorUpdatedAt = Dictionary(
            store.tasks.map { ($0.id, $0.updatedAt) },
            uniquingKeysWith: { max($0, $1) }
        )
        let processingID = UUID()
        inboxProcessingID = processingID
        let processor = self.processor
        inboxProcessingTask = Task { [weak self] in
            let result: Result<Int, Error>
            do {
                result = .success(try await processor.processPending())
            } catch {
                result = .failure(error)
            }

            guard let self, inboxProcessingID == processingID else {
                return
            }
            inboxProcessingTask = nil
            inboxProcessingID = nil
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
            guard processedCount > 0 else {
                return
            }
            let shouldAnimate = store.tasks.contains { task in
                guard task.status == .needsAttention || task.status == .ready else {
                    return false
                }
                return priorUpdatedAt[task.id] != task.updatedAt
            }
            notifyPresentationChanged(animated: shouldAnimate)
            let changedTasks = store.tasks.filter { priorUpdatedAt[$0.id] != $0.updatedAt }
            if let attention = changedTasks.first(where: { $0.status == .needsAttention }) {
                onAnnouncementRequested?("\(attention.workspaceName) 需要处理", true)
            } else if let ready = changedTasks.first(where: { $0.status == .ready }) {
                onAnnouncementRequested?("\(ready.workspaceName) 可查看", false)
            }
        }
    }

    private func reconcileAppServerTasks(force: Bool) {
        guard let threadSnapshotLoader else {
            return
        }
        let activeTasks = store.tasks.filter { task in
            switch task.status {
            case .running, .needsAttention:
                true
            case .ready:
                false
            }
        }
        let activeTaskIDs = Set(activeTasks.map(\.id))
        guard recoveryThrottle.shouldStart(
            hasActiveTasks: !activeTaskIDs.isEmpty,
            isRecoveryInFlight: startupRecoveryTask != nil,
            now: Date(),
            force: force
        ) else {
            return
        }
        let recoveryID = UUID()
        startupRecoveryID = recoveryID
        let activator = self.activator

        startupRecoveryTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                if startupRecoveryID == recoveryID {
                    recoveryThrottle.didFinish(at: Date())
                    startupRecoveryTask = nil
                    startupRecoveryID = nil
                }
            }

            do {
                let reconciler = StartupTaskReconciler(store: store)
                let changedCount: Int
                if force {
                    let windows = await activator.discoverWindowsAsync()
                    guard !Task.isCancelled,
                          startupRecoveryID == recoveryID,
                          !windows.isEmpty
                    else {
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
                        return
                    }
                    guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                        return
                    }
                    let currentWindows = await activator.discoverWindowsAsync()
                    guard !Task.isCancelled,
                          startupRecoveryID == recoveryID,
                          !currentWindows.isEmpty
                    else {
                        return
                    }
                    changedCount = try await reconciler.reconcile(
                        snapshots: snapshots,
                        windows: currentWindows
                    )
                } else {
                    let snapshots: [CodexThreadSnapshot]
                    do {
                        snapshots = try await threadSnapshotLoader.loadSnapshots(
                            matchingActiveTasks: activeTasks
                        )
                    } catch {
                        guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                            return
                        }
                        logRecoveryFailureIfNeeded()
                        return
                    }
                    guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                        return
                    }
                    changedCount = try await reconciler.reconcileActiveTasks(
                        snapshots: snapshots,
                        matchingExistingTaskIDs: activeTaskIDs
                    )
                }
                guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                    return
                }
                if changedCount > 0 {
                    notifyPresentationChanged(animated: !force)
                    if !force,
                       let ready = store.tasks.first(where: {
                           activeTaskIDs.contains($0.id)
                               && $0.status == .ready
                               && $0.isUnread
                       }) {
                        onAnnouncementRequested?("\(ready.workspaceName) 可查看", false)
                    }
                }
            } catch {
                guard !Task.isCancelled, startupRecoveryID == recoveryID else {
                    return
                }
                showNotice(message: "检测到任务状态变化，但无法保存核对结果。")
            }
        }
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

    private func cancelStartupRecovery(resetThrottle: Bool = false) {
        startupRecoveryTask?.cancel()
        startupRecoveryTask = nil
        startupRecoveryID = nil
        if resetThrottle {
            recoveryThrottle.reset()
        }
    }

    private func showNotice(
        message: String,
        showsAccessibilityAction: Bool = false,
        highPriority: Bool = false
    ) {
        guard notice?.message != message else {
            return
        }
        notice = PanelNotice(
            message: message,
            showsAccessibilityAction: showsAccessibilityAction
        )
        onAnnouncementRequested?(message, highPriority)
    }

    private func notifyPresentationChanged(animated: Bool) {
        onPresentationChanged?(store.tasks.count, notice != nil, animated)
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
