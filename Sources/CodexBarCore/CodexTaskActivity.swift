import Combine
import Foundation

public enum CodexTaskActivityKind: String, Codable, Equatable, Sendable {
    case read
    case search
    case edit
    case test
    case command
}

public struct CodexHookActivitySummary: Codable, Equatable, Sendable {
    public let kind: CodexTaskActivityKind
    public let safeSubject: String?

    public init(kind: CodexTaskActivityKind, safeSubject: String?) {
        self.kind = kind
        self.safeSubject = safeSubject
    }
}

/// A short-lived, display-only node for the task that is currently running.
public struct CodexTaskActivity: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: CodexTaskActivityKind
    public let summary: String
    public let occurredAt: Date

    public init(
        id: String,
        kind: CodexTaskActivityKind,
        summary: String,
        occurredAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.occurredAt = occurredAt
    }
}

/// Keeps only the small activity trace needed by the live hover preview.
/// Nothing in this store is encoded or restored across launches.
@MainActor
public final class LiveTaskActivityStore: ObservableObject {
    private static let maximumNodesPerTask = 3
    private static let maximumDeliveryIDs = 1_024
    private static let maximumDeliveryIDCharacters = 1_024

    @Published public private(set) var revision: UInt64 = 0

    private var nodesByTaskID: [String: [CodexTaskActivity]] = [:]
    private var contextByTaskID: [String: TaskContext] = [:]
    private var activeTaskIDs: Set<String> = []
    private var frozenTaskIDs: Set<String> = []
    private var deliveryIDs: Set<String> = []
    private var deliveryIDOrder: [String] = []
    private var isApplyingBatch = false
    private var batchChangedVisibleNodes = false

    public init() {}

    @discardableResult
    public func apply(
        _ event: CodexHookEvent,
        deliveryID: String,
        currentTasks: [CodexTask],
        normalizedCWD: String? = nil
    ) -> Bool {
        guard recordDeliveryID(deliveryID),
              let name = event.name,
              let task = matchingTask(
                  for: event,
                  normalizedCWD: normalizedCWD,
                  tasksByCWD: tasksByCWD(currentTasks)
              )
        else {
            synchronizeInternal(with: currentTasks)
            return false
        }

        if name == .stop {
            migrateContinuedTurnIfNeeded(to: task)
        }
        pruneRemovedTasks(currentTasks)
        if name == .preToolUse {
            freezeReadyTasks(currentTasks)
        }
        contextByTaskID[task.id] = TaskContext(task: task)
        return applyMatched(event, name: name, to: task)
    }

    func applyBatch(
        _ pendingEvents: [PendingCodexEvent],
        initialTasks: [CodexTask],
        appliedLifecycleEvents: [TaskStoreAppliedEvent],
        finalTasks: [CodexTask]
    ) {
        guard !pendingEvents.isEmpty else {
            synchronize(with: finalTasks)
            return
        }

        beginBatch()
        defer { endBatch() }

        synchronizeInternal(with: initialTasks)
        var projectedTasksByCWD = tasksByCWD(initialTasks)
        var lifecycleTasksByEventID = Dictionary(
            appliedLifecycleEvents.map { ($0.eventID, $0.task) },
            uniquingKeysWith: { first, _ in first }
        )

        for pendingEvent in pendingEvents {
            guard let name = pendingEvent.event.name else {
                continue
            }

            let task: CodexTask?
            if name == .preToolUse {
                task = matchingTask(
                    for: pendingEvent.event,
                    normalizedCWD: pendingEvent.normalizedCWD,
                    tasksByCWD: projectedTasksByCWD
                )
            } else if let appliedTask = lifecycleTasksByEventID.removeValue(
                forKey: pendingEvent.event.id
            ) {
                projectedTasksByCWD[appliedTask.cwd] = appliedTask
                task = appliedTask
            } else {
                task = nil
            }

            guard recordDeliveryID(pendingEvent.sourceURL.lastPathComponent),
                  let task
            else {
                continue
            }
            if name == .userPromptSubmit {
                removeReplacedTaskContexts(for: task)
            }
            if name == .stop {
                migrateContinuedTurnIfNeeded(to: task)
            }
            contextByTaskID[task.id] = TaskContext(task: task)
            _ = applyMatched(pendingEvent.event, name: name, to: task)
        }

        synchronizeInternal(with: finalTasks)
    }

    private func removeReplacedTaskContexts(for task: CodexTask) {
        let replacedTaskIDs = contextByTaskID.compactMap { taskID, context in
            context.cwd == task.cwd && taskID != task.id ? taskID : nil
        }
        var removedVisibleNodes = false
        for taskID in replacedTaskIDs {
            removedVisibleNodes = nodesByTaskID.removeValue(forKey: taskID) != nil
                || removedVisibleNodes
            contextByTaskID.removeValue(forKey: taskID)
            activeTaskIDs.remove(taskID)
            frozenTaskIDs.remove(taskID)
        }
        if removedVisibleNodes {
            publishVisibleChange()
        }
    }

    public func nodes(for task: CodexTask) -> [CodexTaskActivity] {
        nodesByTaskID[task.id] ?? []
    }

    /// Drops traces whose task rows were removed by UI or recovery actions.
    public func synchronize(with currentTasks: [CodexTask]) {
        synchronizeInternal(with: currentTasks)
    }

    private func applyMatched(
        _ event: CodexHookEvent,
        name: CodexHookEventName,
        to task: CodexTask
    ) -> Bool {
        switch name {
        case .userPromptSubmit:
            guard task.status != .ready else {
                activeTaskIDs.remove(task.id)
                frozenTaskIDs.insert(task.id)
                return true
            }
            let changed = nodesByTaskID.removeValue(forKey: task.id) != nil
            activeTaskIDs.insert(task.id)
            frozenTaskIDs.remove(task.id)
            if changed {
                publishVisibleChange()
            }
            return true

        case .permissionRequest:
            return true

        case .stop:
            activeTaskIDs.remove(task.id)
            frozenTaskIDs.insert(task.id)
            return true

        case .preToolUse:
            return applyActivity(event, to: task)
        }
    }

    private func applyActivity(_ event: CodexHookEvent, to task: CodexTask) -> Bool {
        guard let activity = sanitizedActivity(event.activity),
              let nodeID = nonempty(event.id, maximumCharacters: 128),
              !frozenTaskIDs.contains(task.id),
              event.timestamp >= task.startedAt
        else {
            return false
        }

        if !activeTaskIDs.contains(task.id) {
            guard task.status != .ready else {
                return false
            }
            activeTaskIDs.insert(task.id)
        }

        let node = CodexTaskActivity(
            id: nodeID,
            kind: activity.kind,
            summary: displaySummary(for: activity),
            occurredAt: event.timestamp
        )
        var nodes = nodesByTaskID[task.id] ?? []

        if let last = nodes.last, event.timestamp < last.occurredAt {
            return false
        }
        if nodes.last?.kind == node.kind {
            nodes[nodes.count - 1] = node
        } else {
            nodes.append(node)
            if nodes.count > Self.maximumNodesPerTask {
                nodes.removeFirst(nodes.count - Self.maximumNodesPerTask)
            }
        }

        nodesByTaskID[task.id] = nodes
        publishVisibleChange()
        return true
    }

    private func sanitizedActivity(
        _ activity: CodexHookActivitySummary?
    ) -> CodexHookActivitySummary? {
        guard let activity else {
            return nil
        }
        let safeSubject = activity.safeSubject.flatMap { value -> String? in
            guard value.count <= 4_096 else {
                return nil
            }
            return PromptSanitizer.sanitize(value, maxLength: 160)
        }
        return CodexHookActivitySummary(kind: activity.kind, safeSubject: safeSubject)
    }

    private func synchronizeInternal(with currentTasks: [CodexTask]) {
        pruneRemovedTasks(currentTasks)
        freezeReadyTasks(currentTasks)
    }

    private func pruneRemovedTasks(_ currentTasks: [CodexTask]) {
        let currentTaskIDs = Set(currentTasks.map(\.id))
        let previousNodeCount = nodesByTaskID.count
        nodesByTaskID = nodesByTaskID.filter { currentTaskIDs.contains($0.key) }
        contextByTaskID = contextByTaskID.filter { currentTaskIDs.contains($0.key) }
        activeTaskIDs.formIntersection(currentTaskIDs)
        frozenTaskIDs.formIntersection(currentTaskIDs)
        if nodesByTaskID.count != previousNodeCount {
            publishVisibleChange()
        }
    }

    private func freezeReadyTasks(_ currentTasks: [CodexTask]) {
        let readyTaskIDs = Set(currentTasks.lazy.filter { $0.status == .ready }.map(\.id))
        activeTaskIDs.subtract(readyTaskIDs)
        frozenTaskIDs.formUnion(readyTaskIDs)
    }

    private func migrateContinuedTurnIfNeeded(to task: CodexTask) {
        let context = TaskContext(task: task)
        guard task.status == .ready,
              let previousTaskID = contextByTaskID.first(where: {
                  $0.key != task.id
                      && $0.value == context
                      && activeTaskIDs.contains($0.key)
              })?.key
        else {
            return
        }

        if let nodes = nodesByTaskID.removeValue(forKey: previousTaskID) {
            nodesByTaskID[task.id] = nodes
            publishVisibleChange()
        }
        contextByTaskID.removeValue(forKey: previousTaskID)
        activeTaskIDs.remove(previousTaskID)
        activeTaskIDs.insert(task.id)
        frozenTaskIDs.remove(previousTaskID)
    }

    private func matchingTask(
        for event: CodexHookEvent,
        normalizedCWD: String?,
        tasksByCWD: [String: CodexTask]
    ) -> CodexTask? {
        guard let sessionID = nonempty(event.sessionID, maximumCharacters: 512),
              let turnID = nonempty(event.turnID, maximumCharacters: 512),
              let cwd = canonicalCWD(normalizedCWD ?? event.cwd),
              let task = tasksByCWD[cwd]
        else {
            return nil
        }
        return task.sessionID == sessionID && task.turnID == turnID ? task : nil
    }

    private func tasksByCWD(_ tasks: [CodexTask]) -> [String: CodexTask] {
        Dictionary(tasks.map { ($0.cwd, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func canonicalCWD(_ value: String?) -> String? {
        guard let value = nonempty(value, maximumCharacters: 4_096),
              (value as NSString).isAbsolutePath
        else {
            return nil
        }
        let cwd = (value as NSString).standardizingPath
        return cwd == "/" ? nil : cwd
    }

    private func beginBatch() {
        precondition(!isApplyingBatch)
        isApplyingBatch = true
        batchChangedVisibleNodes = false
    }

    private func endBatch() {
        isApplyingBatch = false
        if batchChangedVisibleNodes {
            batchChangedVisibleNodes = false
            revision &+= 1
        }
    }

    private func publishVisibleChange() {
        if isApplyingBatch {
            batchChangedVisibleNodes = true
        } else {
            revision &+= 1
        }
    }

    private func recordDeliveryID(_ value: String) -> Bool {
        guard let deliveryID = nonempty(
            value,
            maximumCharacters: Self.maximumDeliveryIDCharacters
        ), !deliveryIDs.contains(deliveryID) else {
            return false
        }

        deliveryIDs.insert(deliveryID)
        deliveryIDOrder.append(deliveryID)
        if deliveryIDOrder.count > Self.maximumDeliveryIDs {
            let overflow = deliveryIDOrder.count - Self.maximumDeliveryIDs
            for expiredID in deliveryIDOrder.prefix(overflow) {
                deliveryIDs.remove(expiredID)
            }
            deliveryIDOrder.removeFirst(overflow)
        }
        return true
    }

    private func nonempty(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= maximumCharacters
        else {
            return nil
        }
        return value
    }

    private func displaySummary(for activity: CodexHookActivitySummary) -> String {
        switch activity.kind {
        case .read:
            return activity.safeSubject.map { "读取 \($0)" } ?? "读取文件"
        case .search:
            return activity.safeSubject.map { "搜索 \($0)" } ?? "搜索代码"
        case .edit:
            return activity.safeSubject.map { "修改 \($0)" } ?? "修改代码"
        case .test:
            return activity.safeSubject.map { "运行 \($0) 测试" } ?? "运行测试"
        case .command:
            return "执行命令"
        }
    }
}

private struct TaskContext: Equatable {
    let sessionID: String
    let cwd: String

    init(task: CodexTask) {
        sessionID = task.sessionID
        cwd = task.cwd
    }
}
