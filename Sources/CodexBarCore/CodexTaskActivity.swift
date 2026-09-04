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

public enum CodexTaskPlanStepStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct CodexTaskPlanStep: Identifiable, Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let status: CodexTaskPlanStepStatus

    public init(id: Int, title: String, status: CodexTaskPlanStepStatus) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public struct CodexHookPlanSummary: Codable, Equatable, Sendable {
    static let maximumSteps = 20
    static let maximumRawTitleCharacters = 4_096
    static let maximumRawTitleBytes = 4_096
    static let maximumTitleCharacters = 160
    static let maximumTitleBytes = 640

    public let steps: [CodexTaskPlanStep]

    public init(steps: [CodexTaskPlanStep]) {
        self.steps = steps
    }
}

/// The latest whole-plan snapshot for one running task.
/// It is held only in memory and replaced by the next `update_plan` call.
public struct CodexTaskPlan: Equatable, Sendable {
    public let steps: [CodexTaskPlanStep]
    public let updatedAt: Date

    public init(steps: [CodexTaskPlanStep], updatedAt: Date) {
        self.steps = steps
        self.updatedAt = updatedAt
    }

    public var totalStepCount: Int {
        steps.count
    }

    public var completedStepCount: Int {
        steps.lazy.filter { $0.status == .completed }.count
    }

    public var isComplete: Bool {
        !steps.isEmpty && completedStepCount == steps.count
    }

    public var currentStepNumber: Int {
        guard !steps.isEmpty else {
            return 0
        }
        if let index = currentStepIndex {
            return index + 1
        }
        if let index = steps.firstIndex(where: { $0.status == .pending }) {
            return index + 1
        }
        return steps.count
    }

    public var currentStep: CodexTaskPlanStep? {
        currentStepIndex.map { steps[$0] }
    }

    public var progressFraction: Double {
        guard !steps.isEmpty else {
            return 0
        }
        return Double(completedStepCount) / Double(steps.count)
    }

    public func visibleSteps(maximumCount: Int) -> [CodexTaskPlanStep] {
        guard maximumCount > 0, steps.count > maximumCount else {
            return maximumCount > 0 ? steps : []
        }
        let currentIndex = max(0, currentStepNumber - 1)
        let centeredStart = currentIndex - maximumCount / 2
        let start = min(max(0, centeredStart), steps.count - maximumCount)
        return Array(steps[start..<(start + maximumCount)])
    }

    private var currentStepIndex: Int? {
        steps.firstIndex(where: { $0.status == .inProgress })
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

/// Keeps only the small activity trace and latest plan needed by the live hover preview.
/// Nothing in this store is encoded or restored across launches.
@MainActor
public final class LiveTaskActivityStore: ObservableObject {
    private static let maximumNodesPerTask = 3
    private static let maximumDeliveryIDs = 1_024
    private static let maximumDeliveryIDCharacters = 1_024

    @Published public private(set) var revision: UInt64 = 0

    private var nodesByTaskID: [String: [CodexTaskActivity]] = [:]
    private var planByTaskID: [String: CodexTaskPlan] = [:]
    private var latestPlanUpdateByTaskID: [String: Date] = [:]
    private var contextByTaskID: [String: TaskContext] = [:]
    private var activeTaskIDs: Set<String> = []
    private var frozenTaskIDs: Set<String> = []
    private var deliveryIDs: Set<String> = []
    private var deliveryIDOrder: [String] = []
    private var isApplyingBatch = false
    private var batchChangedVisibleState = false

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
        var removedVisibleState = false
        for taskID in replacedTaskIDs {
            removedVisibleState = nodesByTaskID.removeValue(forKey: taskID) != nil
                || removedVisibleState
            removedVisibleState = planByTaskID.removeValue(forKey: taskID) != nil
                || removedVisibleState
            latestPlanUpdateByTaskID.removeValue(forKey: taskID)
            contextByTaskID.removeValue(forKey: taskID)
            activeTaskIDs.remove(taskID)
            frozenTaskIDs.remove(taskID)
        }
        if removedVisibleState {
            publishVisibleChange()
        }
    }

    public func nodes(for task: CodexTask) -> [CodexTaskActivity] {
        nodesByTaskID[task.id] ?? []
    }

    public func plan(for task: CodexTask) -> CodexTaskPlan? {
        planByTaskID[task.id]
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
            let removedNodes = nodesByTaskID.removeValue(forKey: task.id) != nil
            let removedPlan = planByTaskID.removeValue(forKey: task.id) != nil
            latestPlanUpdateByTaskID.removeValue(forKey: task.id)
            let changed = removedNodes || removedPlan
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
            if event.plan != nil {
                return applyPlan(event, to: task)
            }
            return applyActivity(event, to: task)
        }
    }

    private func applyPlan(_ event: CodexHookEvent, to task: CodexTask) -> Bool {
        guard let plan = sanitizedPlan(event.plan),
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
        if let latestUpdate = latestPlanUpdateByTaskID[task.id],
           event.timestamp < latestUpdate {
            return false
        }
        latestPlanUpdateByTaskID[task.id] = event.timestamp

        if plan.steps.isEmpty {
            if planByTaskID.removeValue(forKey: task.id) != nil {
                publishVisibleChange()
            }
            return true
        }
        planByTaskID[task.id] = CodexTaskPlan(
            steps: plan.steps,
            updatedAt: event.timestamp
        )
        publishVisibleChange()
        return true
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

    private func sanitizedPlan(_ plan: CodexHookPlanSummary?) -> CodexHookPlanSummary? {
        guard let plan,
              plan.steps.count <= CodexHookPlanSummary.maximumSteps,
              plan.steps.filter({ $0.status == .inProgress }).count <= 1
        else {
            return nil
        }

        var steps: [CodexTaskPlanStep] = []
        steps.reserveCapacity(plan.steps.count)
        for (index, step) in plan.steps.enumerated() {
            guard step.title.utf8.count <= CodexHookPlanSummary.maximumRawTitleBytes,
                  step.title.count <= CodexHookPlanSummary.maximumRawTitleCharacters,
                  let title = PromptSanitizer.sanitize(
                      step.title,
                      maxLength: CodexHookPlanSummary.maximumTitleCharacters
                  ),
                  title.utf8.count <= CodexHookPlanSummary.maximumTitleBytes
            else {
                return nil
            }
            steps.append(CodexTaskPlanStep(id: index, title: title, status: step.status))
        }
        return CodexHookPlanSummary(steps: steps)
    }

    private func synchronizeInternal(with currentTasks: [CodexTask]) {
        pruneRemovedTasks(currentTasks)
        freezeReadyTasks(currentTasks)
    }

    private func pruneRemovedTasks(_ currentTasks: [CodexTask]) {
        let currentTaskIDs = Set(currentTasks.map(\.id))
        let previousNodeCount = nodesByTaskID.count
        let previousPlanCount = planByTaskID.count
        nodesByTaskID = nodesByTaskID.filter { currentTaskIDs.contains($0.key) }
        planByTaskID = planByTaskID.filter { currentTaskIDs.contains($0.key) }
        latestPlanUpdateByTaskID = latestPlanUpdateByTaskID.filter {
            currentTaskIDs.contains($0.key)
        }
        contextByTaskID = contextByTaskID.filter { currentTaskIDs.contains($0.key) }
        activeTaskIDs.formIntersection(currentTaskIDs)
        frozenTaskIDs.formIntersection(currentTaskIDs)
        if nodesByTaskID.count != previousNodeCount
            || planByTaskID.count != previousPlanCount {
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

        var migratedVisibleState = false
        if let nodes = nodesByTaskID.removeValue(forKey: previousTaskID) {
            nodesByTaskID[task.id] = nodes
            migratedVisibleState = true
        }
        if let plan = planByTaskID.removeValue(forKey: previousTaskID) {
            planByTaskID[task.id] = plan
            migratedVisibleState = true
        }
        if let latestUpdate = latestPlanUpdateByTaskID.removeValue(forKey: previousTaskID) {
            latestPlanUpdateByTaskID[task.id] = latestUpdate
        }
        if migratedVisibleState {
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
        batchChangedVisibleState = false
    }

    private func endBatch() {
        isApplyingBatch = false
        if batchChangedVisibleState {
            batchChangedVisibleState = false
            revision &+= 1
        }
    }

    private func publishVisibleChange() {
        if isApplyingBatch {
            batchChangedVisibleState = true
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
