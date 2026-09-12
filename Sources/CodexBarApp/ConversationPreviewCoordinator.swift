import CodexBarCore
import Foundation

@MainActor
protocol ConversationPreviewMonitoring: AnyObject {
    func unavailableReason(for sessionID: String) -> CodexRuntimeUnavailableReason?
    func requestSnapshot(sessionID: String, retryIncompatible: Bool)
    func requestCompleteHistory(sessionID: String, completion: @escaping @MainActor @Sendable (Int?) -> Void)
}

extension CodexRuntimeStatusMonitor: ConversationPreviewMonitoring {}

/// Owns the selected conversation's in-memory state and asynchronous request lifetime.
@MainActor
final class ConversationPreviewCoordinator {
    let store: ConversationPreviewStore
    private(set) var target: (sessionID: String, cwd: String)?
    private(set) var generation: UUID?
    private let monitor: any ConversationPreviewMonitoring
    private let makeWorker: @MainActor (String, String) -> any ConversationPreviewConsuming
    private let snapshotTimeout: Duration
    private var worker: (any ConversationPreviewConsuming)?
    private var waitTask: Task<Void, Never>?
    private var historyExpectedRevision: Int?
    private var unavailableReason: CodexRuntimeUnavailableReason?

    init(
        store: ConversationPreviewStore,
        monitor: any ConversationPreviewMonitoring,
        makeWorker: @escaping @MainActor (String, String) -> any ConversationPreviewConsuming = {
            ConversationPreviewWorker(sessionID: $0, cwd: $1)
        },
        snapshotTimeout: Duration = .seconds(8)
    ) {
        self.store = store
        self.monitor = monitor
        self.makeWorker = makeWorker
        self.snapshotTimeout = snapshotTimeout
    }

    func begin(sessionID: String, cwd: String) {
        if target?.sessionID == sessionID && target?.cwd == cwd { return }
        end()
        target = (sessionID, cwd)
        generation = UUID()
        worker = makeWorker(sessionID, cwd)
        if let reason = monitor.unavailableReason(for: sessionID), case .unsupportedProtocol = reason {
            invalidate(reason: reason)
        } else {
            requestSnapshot(retryIncompatible: false)
        }
    }

    func end() {
        generation = nil
        target = nil
        worker = nil
        waitTask?.cancel()
        waitTask = nil
        historyExpectedRevision = nil
        unavailableReason = nil
        store.clear()
    }

    func refresh() {
        guard let target else { return }
        if store.state == .unavailable {
            worker = makeWorker(target.sessionID, target.cwd)
            historyExpectedRevision = nil
            store.isLoadingHistory = false
        }
        requestSnapshot(retryIncompatible: true)
    }

    private func requestSnapshot(retryIncompatible: Bool) {
        guard let target else { return }
        if let reason = currentProtocolFailure() {
            store.state = .unavailable
            store.message = message(for: reason)
        } else {
            if store.preview == nil { store.state = .loading }
            store.message = nil
        }
        monitor.requestSnapshot(sessionID: target.sessionID, retryIncompatible: retryIncompatible)
        waitForSnapshot()
    }

    func loadHistory() {
        guard let target, let generation, let worker, !store.isLoadingHistory else { return }
        if let reason = currentProtocolFailure() { invalidate(reason: reason); return }
        store.isLoadingHistory = true
        store.message = nil
        monitor.requestCompleteHistory(sessionID: target.sessionID) { [weak self] revision in
            guard let self, self.generation == generation, self.worker === worker else { return }
            if let reason = currentProtocolFailure() { invalidate(reason: reason); return }
            guard let revision else {
                store.isLoadingHistory = false
                store.message = "暂时无法加载较早内容，可以重试或返回会话查看。"
                return
            }
            if let receivedRevision = store.latestRevision, receivedRevision >= revision {
                store.isLoadingHistory = false
            } else {
                historyExpectedRevision = revision
                monitor.requestSnapshot(sessionID: target.sessionID, retryIncompatible: false)
                waitForSnapshot()
            }
        }
    }

    func consume(_ data: Data, sessionID: String?, generation: UUID?) async {
        guard !Task.isCancelled, let generation, self.generation == generation,
              sessionID == target?.sessionID, let worker else { return }
        let result = await worker.consume(data)
        guard !Task.isCancelled, self.generation == generation, self.worker === worker else { return }
        apply(result)
    }

    func invalidate(reason: CodexRuntimeUnavailableReason = .connectionUnavailable) {
        guard let target else { return }
        waitTask?.cancel()
        waitTask = nil
        worker = makeWorker(target.sessionID, target.cwd)
        historyExpectedRevision = nil
        store.isLoadingHistory = false
        if case .unsupportedProtocol = reason { unavailableReason = reason }
        else { unavailableReason = currentProtocolFailure() ?? reason }
        store.state = .unavailable
        store.message = message(for: unavailableReason ?? reason)
    }

    private func waitForSnapshot() {
        waitTask?.cancel()
        guard let generation, let worker else { return }
        let timeout = snapshotTimeout
        waitTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !Task.isCancelled, self.generation == generation, self.worker === worker else { return }
            waitTask = nil
            if let reason = currentProtocolFailure() {
                invalidate(reason: reason)
                return
            }
            store.state = .unavailable
            store.isLoadingHistory = false
            historyExpectedRevision = nil
            store.message = "暂时无法读取最新会话，可以重试或返回会话查看。"
        }
    }

    private func apply(_ result: CodexConversationPreviewResult) {
        guard let target else { return }
        if result.invalidated {
            store.state = .unavailable
            store.isLoadingHistory = false
            historyExpectedRevision = nil
            store.message = currentProtocolFailure().map(message(for:))
                ?? "无法读取这份会话内容，可以重试或返回会话查看。"
        }
        if result.needsSnapshot {
            monitor.requestSnapshot(sessionID: target.sessionID, retryIncompatible: false)
            waitForSnapshot()
        }
        if let preview = result.preview, preview.sessionID == target.sessionID, preview.cwd == target.cwd {
            if historyExpectedRevision.map({ preview.revision >= $0 }) ?? true {
                waitTask?.cancel()
                waitTask = nil
            }
            unavailableReason = nil
            store.receive(preview)
            if store.state != .ready {
                store.message = nil
                store.state = .ready
            }
            if let expected = historyExpectedRevision, preview.revision >= expected {
                historyExpectedRevision = nil
                store.isLoadingHistory = false
            }
        }
    }

    private func currentProtocolFailure() -> CodexRuntimeUnavailableReason? {
        if let target, let reason = monitor.unavailableReason(for: target.sessionID), case .unsupportedProtocol = reason {
            return reason
        }
        if let unavailableReason, case .unsupportedProtocol = unavailableReason { return unavailableReason }
        return nil
    }

    private func message(for reason: CodexRuntimeUnavailableReason) -> String {
        switch reason {
        case .connectionUnavailable:
            return store.preview == nil ? "会话连接暂不可用，可以重试或返回会话查看。" : "连接已中断，当前显示上次读取的内容。"
        case .unsupportedProtocol:
            return "当前 Codex 扩展版本暂不兼容，无法更新会话内容。请更新 CodexBar 后重试，或返回会话查看。"
        }
    }
}
