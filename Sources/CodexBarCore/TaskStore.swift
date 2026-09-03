import Combine
import Foundation

public enum TaskStorePersistenceError: Error, Equatable {
    case persistenceUnavailable
    case invalidSnapshot
}

@MainActor
public final class TaskStore: ObservableObject {
    @Published public private(set) var tasks: [CodexTask] = []
    public private(set) var sortedTasks: [CodexTask] = []
    public private(set) var recoverySnapshotURL: URL?

    private let storage: TaskStoreStorage
    private var publishedRevision: UInt64 = 0

    public init(persistenceURL: URL? = nil) {
        self.storage = TaskStoreStorage(persistenceURL: persistenceURL)
    }

    /// Loads and validates the durable snapshot without blocking the main actor.
    public func load() async {
        publish(await storage.load())
    }

    @discardableResult
    public func apply(_ event: CodexHookEvent) async throws -> Bool {
        let operation = try await storage.apply(event)
        publish(operation.state)
        return operation.value
    }

    @discardableResult
    public func apply(_ events: [CodexHookEvent]) async throws -> Int {
        guard !events.isEmpty else {
            return 0
        }
        let operation = try await storage.apply(events)
        publish(operation.state)
        return operation.value
    }

    @discardableResult
    func mergeRecoveredTasks(
        _ recoveredTasks: [CodexTask],
        matchingExistingTaskIDs: Set<String>? = nil,
        markTerminalChangesUnread: Bool = false
    ) async throws -> Int {
        let operation = try await storage.mergeRecoveredTasks(
            recoveredTasks,
            matchingExistingTaskIDs: matchingExistingTaskIDs,
            markTerminalChangesUnread: markTerminalChangesUnread
        )
        publish(operation.state)
        return operation.value
    }

    @discardableResult
    public func markRead(taskID: String) async throws -> Bool {
        let operation = try await storage.markRead(taskID: taskID)
        publish(operation.state)
        return operation.value
    }

    @discardableResult
    public func remove(taskID: String) async throws -> Bool {
        let operation = try await storage.remove(taskID: taskID)
        publish(operation.state)
        return operation.value
    }

    @discardableResult
    package func removeUnchangedTasks(
        _ candidates: [CodexTask],
        olderThan cutoff: Date
    ) async throws -> Int {
        let operation = try await storage.removeUnchangedTasks(
            candidates,
            olderThan: cutoff
        )
        publish(operation.state)
        return operation.value
    }

    @discardableResult
    public func clearRead() async throws -> Int {
        let operation = try await storage.clearRead()
        publish(operation.state)
        return operation.value
    }

    private func publish(_ state: TaskStoreViewState) {
        guard state.revision > publishedRevision else {
            return
        }
        publishedRevision = state.revision
        sortedTasks = state.sortedTasks
        tasks = state.tasks
        recoverySnapshotURL = state.recoverySnapshotURL
    }
}

private struct TaskStoreViewState: Sendable {
    let revision: UInt64
    let tasks: [CodexTask]
    let sortedTasks: [CodexTask]
    let recoverySnapshotURL: URL?
}

private struct TaskStoreOperation<Value: Sendable>: Sendable {
    let value: Value
    let state: TaskStoreViewState
}

private actor TaskStoreStorage {
    private static let maximumDeletedTaskTombstones = 10_000

    private var tasks: [CodexTask] = []
    private var appliedEventIDs: Set<String> = []
    private var deletedTaskTombstones: [DeletedTaskTombstone] = []
    private var recoverySnapshotURL: URL?
    private let persistenceURL: URL?
    private var persistenceIsAvailable = true
    private var hasLoaded: Bool
    private var revision: UInt64 = 0

    init(persistenceURL: URL?) {
        self.persistenceURL = persistenceURL
        self.hasLoaded = persistenceURL == nil
    }

    func load() -> TaskStoreViewState {
        ensureLoaded()
        return viewState()
    }

    func apply(_ event: CodexHookEvent) throws -> TaskStoreOperation<Bool> {
        ensureLoaded()
        let previousTasks = tasks
        let previousEventIDs = appliedEventIDs
        guard applyInMemory(event) else {
            return operation(false)
        }
        do {
            try persist(
                tasks: tasks,
                appliedEventIDs: appliedEventIDs,
                deletedTaskTombstones: deletedTaskTombstones
            )
        } catch {
            tasks = previousTasks
            appliedEventIDs = previousEventIDs
            throw error
        }
        revision &+= 1
        return operation(true)
    }

    private func applyInMemory(_ event: CodexHookEvent) -> Bool {
        guard
            let eventID = nonempty(event.id, maximumCharacters: 128),
            !appliedEventIDs.contains(eventID),
            let sessionID = nonempty(event.sessionID, maximumCharacters: 512),
            let turnID = nonempty(event.turnID, maximumCharacters: 512),
            let cwd = nonempty(event.cwd),
            let normalizedCWD = PathNormalizer.normalize(cwd),
            let eventName = event.name
        else {
            return false
        }

        let taskID = "\(sessionID):\(turnID)"
        guard !deletedTaskTombstones.contains(where: { $0.taskID == taskID }) else {
            return false
        }
        let workspaceComponent = URL(fileURLWithPath: normalizedCWD).lastPathComponent
        guard let workspaceName = PromptSanitizer.sanitizeDisplayText(
            workspaceComponent,
            maxLength: 160
        ) else {
            return false
        }

        var nextTasks = Self.collapsingOlderTurns(tasks)
        if let index = nextTasks.firstIndex(where: { $0.id == taskID }) {
            var task = nextTasks[index]
            let nextStatus = status(for: eventName)
            let advancesState = eventIsNotStale(
                timestamp: event.timestamp,
                status: nextStatus,
                comparedWith: task
            )

            if advancesState {
                task.status = nextStatus
                task.updatedAt = event.timestamp
                task.isUnread = eventName != .userPromptSubmit

                if eventName == .userPromptSubmit,
                   let title = normalizedTitle(event.promptSummary) {
                    task = CodexTask(
                        id: task.id,
                        sessionID: task.sessionID,
                        turnID: task.turnID,
                        cwd: normalizedCWD,
                        workspaceName: workspaceName,
                        title: title,
                        status: task.status,
                        startedAt: task.startedAt,
                        updatedAt: task.updatedAt,
                        isUnread: task.isUnread
                    )
                }
            } else {
                guard eventName == .userPromptSubmit,
                      let title = normalizedTitle(event.promptSummary)
                else {
                    return false
                }
                let startedAt = min(task.startedAt, event.timestamp)
                guard title != task.title
                        || startedAt != task.startedAt
                        || normalizedCWD != task.cwd
                else {
                    return false
                }
                task = CodexTask(
                    id: task.id,
                    sessionID: task.sessionID,
                    turnID: task.turnID,
                    cwd: normalizedCWD,
                    workspaceName: workspaceName,
                    title: title,
                    status: task.status,
                    startedAt: startedAt,
                    updatedAt: task.updatedAt,
                    isUnread: task.isUnread
                )
            }

            nextTasks[index] = task
        } else {
            let currentCWDIndex = nextTasks.firstIndex { $0.cwd == normalizedCWD }
            let newTask: CodexTask
            if let currentCWDIndex,
               eventName == .stop,
               nextTasks[currentCWDIndex].sessionID == sessionID,
               nextTasks[currentCWDIndex].status != .ready,
               eventIsNotStale(
                   timestamp: event.timestamp,
                   status: .ready,
                   comparedWith: nextTasks[currentCWDIndex]
               ) {
                let currentTask = nextTasks[currentCWDIndex]
                newTask = CodexTask(
                    id: taskID,
                    sessionID: sessionID,
                    turnID: turnID,
                    cwd: normalizedCWD,
                    workspaceName: workspaceName,
                    title: currentTask.title,
                    status: .ready,
                    startedAt: currentTask.startedAt,
                    updatedAt: event.timestamp,
                    isUnread: true
                )
            } else {
                if let currentCWDIndex {
                    guard eventName == .userPromptSubmit,
                          eventStartsNewerTurn(
                              timestamp: event.timestamp,
                              taskID: taskID,
                              comparedWith: nextTasks[currentCWDIndex]
                          )
                    else {
                        return false
                    }
                }
                newTask = CodexTask(
                    id: taskID,
                    sessionID: sessionID,
                    turnID: turnID,
                    cwd: normalizedCWD,
                    workspaceName: workspaceName,
                    title: normalizedTitle(event.promptSummary) ?? workspaceName,
                    status: status(for: eventName),
                    startedAt: event.timestamp,
                    updatedAt: event.timestamp,
                    isUnread: eventName != .userPromptSubmit
                )
            }

            if let currentCWDIndex {
                nextTasks[currentCWDIndex] = newTask
            } else {
                nextTasks.append(newTask)
            }
        }

        var nextEventIDs = appliedEventIDs
        nextEventIDs.insert(eventID)
        if nextEventIDs.count > 100_000,
           let identifierToDiscard = nextEventIDs.min() {
            nextEventIDs.remove(identifierToDiscard)
        }
        tasks = nextTasks
        appliedEventIDs = nextEventIDs
        return true
    }

    func apply(_ events: [CodexHookEvent]) throws -> TaskStoreOperation<Int> {
        ensureLoaded()
        guard !events.isEmpty else {
            return operation(0)
        }

        let previousTasks = tasks
        let previousEventIDs = appliedEventIDs
        var appliedCount = 0
        for event in events where applyInMemory(event) {
            appliedCount += 1
        }
        guard appliedCount > 0 else {
            return operation(0)
        }

        do {
            try persist(
                tasks: tasks,
                appliedEventIDs: appliedEventIDs,
                deletedTaskTombstones: deletedTaskTombstones
            )
        } catch {
            tasks = previousTasks
            appliedEventIDs = previousEventIDs
            throw error
        }
        revision &+= 1
        return operation(appliedCount)
    }

    func mergeRecoveredTasks(
        _ recoveredTasks: [CodexTask],
        matchingExistingTaskIDs: Set<String>?,
        markTerminalChangesUnread: Bool
    ) throws -> TaskStoreOperation<Int> {
        ensureLoaded()
        var nextTasks = tasks
        var changedCount = 0

        for task in recoveredTasks {
            guard !deletedTaskTombstones.contains(where: { $0.taskID == task.id }) else {
                continue
            }
            let existingIndex = nextTasks.firstIndex(where: { $0.cwd == task.cwd })
            if let matchingExistingTaskIDs {
                guard matchingExistingTaskIDs.contains(task.id),
                      let existingIndex,
                      nextTasks[existingIndex].id == task.id,
                      (nextTasks[existingIndex].status == .running
                        || nextTasks[existingIndex].status == .needsAttention),
                      let merged = mergeSameRecoveredTurn(
                          task,
                          with: nextTasks[existingIndex],
                          markTerminalChangeUnread: markTerminalChangesUnread
                      )
                else {
                    continue
                }
                nextTasks[existingIndex] = merged
                changedCount += 1
                continue
            }

            guard let index = existingIndex else {
                nextTasks.append(task)
                changedCount += 1
                continue
            }

            let current = nextTasks[index]
            if current.id == task.id {
                guard let merged = mergeSameRecoveredTurn(
                    task,
                    with: current,
                    markTerminalChangeUnread: markTerminalChangesUnread
                ) else {
                    continue
                }
                nextTasks[index] = merged
            } else {
                guard recoveredTurnIsNewer(task, than: current) else {
                    continue
                }
                nextTasks[index] = CodexTask(
                    id: task.id,
                    sessionID: task.sessionID,
                    turnID: task.turnID,
                    cwd: task.cwd,
                    workspaceName: task.workspaceName,
                    title: task.title,
                    status: task.status,
                    startedAt: task.startedAt,
                    updatedAt: task.updatedAt,
                    isUnread: task.isUnread
                )
            }
            changedCount += 1
        }

        guard changedCount > 0 else {
            return operation(0)
        }
        try persist(
            tasks: nextTasks,
            appliedEventIDs: appliedEventIDs,
            deletedTaskTombstones: deletedTaskTombstones
        )
        tasks = nextTasks
        revision &+= 1
        return operation(changedCount)
    }

    private func mergeSameRecoveredTurn(
        _ recovered: CodexTask,
        with current: CodexTask,
        markTerminalChangeUnread: Bool
    ) -> CodexTask? {
        let currentOrder = lifecycleOrder(of: current.status)
        let recoveredOrder = lifecycleOrder(of: recovered.status)
        guard recoveredOrder >= currentOrder else {
            return nil
        }
        if recoveredOrder == currentOrder {
            guard recovered.updatedAt > current.updatedAt else {
                return nil
            }
        } else {
            // App Server timestamps are whole seconds, while Hook timestamps
            // include fractions. Permit only that rounding difference; an
            // actually older recovery snapshot must not stop a live Hook turn.
            guard wholeSecond(recovered.updatedAt) >= wholeSecond(current.updatedAt) else {
                return nil
            }
        }

        return CodexTask(
            id: current.id,
            sessionID: current.sessionID,
            turnID: current.turnID,
            cwd: recovered.cwd,
            workspaceName: recovered.workspaceName,
            title: current.title,
            status: recovered.status,
            startedAt: min(current.startedAt, recovered.startedAt),
            updatedAt: max(current.updatedAt, recovered.updatedAt),
            isUnread: markTerminalChangeUnread
                && recovered.status == .ready
                && current.status != .ready
                ? true
                : current.isUnread
        )
    }

    private func recoveredTurnIsNewer(
        _ candidate: CodexTask,
        than current: CodexTask
    ) -> Bool {
        let candidateStartedAt = wholeSecond(candidate.startedAt)
        let currentStartedAt = wholeSecond(current.startedAt)
        if candidateStartedAt != currentStartedAt {
            return candidateStartedAt > currentStartedAt
        }

        let candidateUpdatedAt = wholeSecond(candidate.updatedAt)
        let currentUpdatedAt = wholeSecond(current.updatedAt)
        if candidateUpdatedAt != currentUpdatedAt {
            return candidateUpdatedAt > currentUpdatedAt
        }
        return candidate.id > current.id
    }

    private func wholeSecond(_ date: Date) -> TimeInterval {
        floor(date.timeIntervalSince1970)
    }

    func markRead(taskID: String) throws -> TaskStoreOperation<Bool> {
        ensureLoaded()
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].isUnread else {
            return operation(false)
        }
        var nextTasks = tasks
        nextTasks[index].isUnread = false
        try persist(
            tasks: nextTasks,
            appliedEventIDs: appliedEventIDs,
            deletedTaskTombstones: deletedTaskTombstones
        )
        tasks = nextTasks
        revision &+= 1
        return operation(true)
    }

    func remove(taskID: String) throws -> TaskStoreOperation<Bool> {
        ensureLoaded()
        let nextTasks = tasks.filter { $0.id != taskID }
        guard nextTasks.count != tasks.count else {
            return operation(false)
        }
        let nextTombstones = addingDeletionTombstones(
            for: [taskID],
            to: deletedTaskTombstones
        )
        try persist(
            tasks: nextTasks,
            appliedEventIDs: appliedEventIDs,
            deletedTaskTombstones: nextTombstones
        )
        tasks = nextTasks
        deletedTaskTombstones = nextTombstones
        revision &+= 1
        return operation(true)
    }

    func removeUnchangedTasks(
        _ candidates: [CodexTask],
        olderThan cutoff: Date
    ) throws -> TaskStoreOperation<Int> {
        ensureLoaded()
        guard cutoff.timeIntervalSince1970.isFinite else {
            return operation(0)
        }
        let expectedByID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let nextTasks = tasks.filter { current in
            guard current.updatedAt < cutoff,
                  expectedByID[current.id] == current
            else {
                return true
            }
            return false
        }
        let nextTaskIDs = Set(nextTasks.map(\.id))
        let removedTasks = tasks.filter { !nextTaskIDs.contains($0.id) }
        let removedCount = removedTasks.count
        guard removedCount > 0 else {
            return operation(0)
        }
        let nextTombstones = addingDeletionTombstones(
            for: removedTasks.map(\.id),
            to: deletedTaskTombstones
        )
        try persist(
            tasks: nextTasks,
            appliedEventIDs: appliedEventIDs,
            deletedTaskTombstones: nextTombstones
        )
        tasks = nextTasks
        deletedTaskTombstones = nextTombstones
        revision &+= 1
        return operation(removedCount)
    }

    func clearRead() throws -> TaskStoreOperation<Int> {
        ensureLoaded()
        let nextTasks = tasks.filter { $0.status != .ready || $0.isUnread }
        let removedTasks = tasks.filter { $0.status == .ready && !$0.isUnread }
        let removedCount = removedTasks.count
        guard removedCount > 0 else {
            return operation(0)
        }
        let nextTombstones = addingDeletionTombstones(
            for: removedTasks.map(\.id),
            to: deletedTaskTombstones
        )
        try persist(
            tasks: nextTasks,
            appliedEventIDs: appliedEventIDs,
            deletedTaskTombstones: nextTombstones
        )
        tasks = nextTasks
        deletedTaskTombstones = nextTombstones
        revision &+= 1
        return operation(removedCount)
    }

    private func ensureLoaded() {
        guard !hasLoaded else {
            return
        }
        hasLoaded = true
        guard let persistenceURL else {
            return
        }

        switch Self.persistenceItemState(at: persistenceURL) {
        case .missing:
            break
        case .unsafe:
            persistenceIsAvailable = false
        case .regularFile:
            do {
                let snapshot = try Self.loadSnapshot(from: persistenceURL)
                tasks = Self.collapsingOlderTurns(snapshot.tasks)
                appliedEventIDs = Set(snapshot.appliedEventIDs)
                deletedTaskTombstones = snapshot.deletedTaskTombstones
            } catch {
                if let recoveryURL = try? Self.quarantineSnapshot(at: persistenceURL) {
                    recoverySnapshotURL = recoveryURL
                } else {
                    persistenceIsAvailable = false
                }
            }
        }
        revision &+= 1
    }

    private func operation<Value: Sendable>(_ value: Value) -> TaskStoreOperation<Value> {
        TaskStoreOperation(value: value, state: viewState())
    }

    private func viewState() -> TaskStoreViewState {
        TaskStoreViewState(
            revision: revision,
            tasks: tasks,
            sortedTasks: tasks.sorted { lhs, rhs in
                let lhsPriority = priority(of: lhs)
                let rhsPriority = priority(of: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            },
            recoverySnapshotURL: recoverySnapshotURL
        )
    }

    private func nonempty(_ value: String?, maximumCharacters: Int? = nil) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if let maximumCharacters, value.count > maximumCharacters {
            return nil
        }
        return value
    }

    private func addingDeletionTombstones(
        for taskIDs: [String],
        to current: [DeletedTaskTombstone],
        deletedAt: Date = Date()
    ) -> [DeletedTaskTombstone] {
        var byTaskID = Dictionary(
            current.map { ($0.taskID, $0) },
            uniquingKeysWith: { _, newer in newer }
        )
        for taskID in taskIDs {
            byTaskID[taskID] = DeletedTaskTombstone(
                taskID: taskID,
                deletedAt: deletedAt
            )
        }
        let sorted = byTaskID.values.sorted(by: Self.tombstoneIsOlder)
        return Array(sorted.suffix(Self.maximumDeletedTaskTombstones))
    }

    private func normalizedTitle(_ title: String?) -> String? {
        PromptSanitizer.sanitize(title, maxLength: 80)
    }

    private func status(for eventName: CodexHookEventName) -> CodexTaskStatus {
        switch eventName {
        case .userPromptSubmit:
            return .running
        case .permissionRequest:
            return .needsAttention
        case .stop:
            return .ready
        }
    }

    private func priority(of task: CodexTask) -> Int {
        switch (task.status, task.isUnread) {
        case (.needsAttention, _):
            return 0
        case (.ready, true):
            return 1
        case (.running, _):
            return 2
        case (.ready, false):
            return 3
        }
    }

    private func eventIsNotStale(
        timestamp: Date,
        status: CodexTaskStatus,
        comparedWith task: CodexTask
    ) -> Bool {
        if timestamp != task.updatedAt {
            return timestamp > task.updatedAt
        }
        return lifecycleOrder(of: status) >= lifecycleOrder(of: task.status)
    }

    private func eventStartsNewerTurn(
        timestamp: Date,
        taskID: String,
        comparedWith task: CodexTask
    ) -> Bool {
        if timestamp != task.startedAt {
            return timestamp > task.startedAt
        }
        return taskID > task.id
    }

    private func lifecycleOrder(of status: CodexTaskStatus) -> Int {
        switch status {
        case .running:
            return 0
        case .needsAttention:
            return 1
        case .ready:
            return 2
        }
    }

    private func persist(
        tasks: [CodexTask],
        appliedEventIDs: Set<String>,
        deletedTaskTombstones: [DeletedTaskTombstone]
    ) throws {
        guard let persistenceURL else {
            return
        }
        guard persistenceIsAvailable else {
            throw TaskStorePersistenceError.persistenceUnavailable
        }

        let parent = persistenceURL.deletingLastPathComponent()
        do {
            let paths = CodexBarPaths(rootDirectory: parent)
            if FileManager.default.fileExists(atPath: parent.path) {
                try paths.validateStorageDirectory()
            } else {
                try paths.prepareStorageDirectory()
            }
        } catch {
            throw TaskStorePersistenceError.persistenceUnavailable
        }
        guard Self.persistenceItemState(at: persistenceURL) != .unsafe else {
            throw TaskStorePersistenceError.persistenceUnavailable
        }

        let snapshot = TaskStoreSnapshot(
            tasks: tasks,
            appliedEventIDs: appliedEventIDs.sorted(),
            deletedTaskTombstones: deletedTaskTombstones.sorted(
                by: Self.tombstoneIsOlder
            )
        )
        let data = try JSONEncoder.codexBar.encode(snapshot)
        guard tasks.count <= 10_000,
              appliedEventIDs.count <= 100_000,
              deletedTaskTombstones.count <= Self.maximumDeletedTaskTombstones,
              data.count <= 8 * 1_024 * 1_024
        else {
            throw TaskStorePersistenceError.invalidSnapshot
        }
        let temporaryURL = parent.appendingPathComponent(
            ".tasks-\(UUID().uuidString.lowercased()).tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: temporaryURL])
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        if Self.persistenceItemState(at: persistenceURL) == .regularFile {
            _ = try FileManager.default.replaceItemAt(
                persistenceURL,
                withItemAt: temporaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: persistenceURL)
        }
    }

    private static func loadSnapshot(from url: URL) throws -> TaskStoreSnapshot {
        let resourceValues = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey
        ])
        guard resourceValues.isRegularFile == true,
              resourceValues.isSymbolicLink != true,
              (resourceValues.fileSize ?? 0) <= 8 * 1_024 * 1_024
        else {
            throw TaskStorePersistenceError.invalidSnapshot
        }

        let snapshot = try JSONDecoder.codexBar.decode(
            TaskStoreSnapshot.self,
            from: Data(contentsOf: url)
        )
        try validate(snapshot)
        return snapshot
    }

    private static func validate(_ snapshot: TaskStoreSnapshot) throws {
        guard snapshot.tasks.count <= 10_000,
              snapshot.appliedEventIDs.count <= 100_000,
              snapshot.deletedTaskTombstones.count <= maximumDeletedTaskTombstones,
              Set(snapshot.appliedEventIDs).count == snapshot.appliedEventIDs.count,
              snapshot.appliedEventIDs.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
              Set(snapshot.deletedTaskTombstones.map(\.taskID)).count
                == snapshot.deletedTaskTombstones.count,
              snapshot.deletedTaskTombstones.allSatisfy({ tombstone in
                  !tombstone.taskID.isEmpty
                      && tombstone.taskID.count <= 1_025
                      && tombstone.deletedAt.timeIntervalSince1970.isFinite
                      && tombstone.deletedAt.timeIntervalSince1970 >= 0
              })
        else {
            throw TaskStorePersistenceError.invalidSnapshot
        }

        var taskIDs = Set<String>()
        for task in snapshot.tasks {
            guard taskIDs.insert(task.id).inserted,
                  task.id == "\(task.sessionID):\(task.turnID)",
                  !task.sessionID.isEmpty,
                  task.sessionID.count <= 512,
                  !task.turnID.isEmpty,
                  task.turnID.count <= 512,
                  let normalizedCWD = PathNormalizer.normalize(task.cwd),
                  normalizedCWD == task.cwd,
                  PromptSanitizer.sanitizeDisplayText(
                      URL(fileURLWithPath: normalizedCWD).lastPathComponent,
                      maxLength: 160
                  ) == task.workspaceName,
                  !task.title.isEmpty,
                  task.title.count <= 80,
                  task.startedAt.timeIntervalSince1970.isFinite,
                  task.updatedAt.timeIntervalSince1970.isFinite
            else {
                throw TaskStorePersistenceError.invalidSnapshot
            }
        }
        guard taskIDs.isDisjoint(
            with: Set(snapshot.deletedTaskTombstones.map(\.taskID))
        ) else {
            throw TaskStorePersistenceError.invalidSnapshot
        }
    }

    private static func tombstoneIsOlder(
        _ lhs: DeletedTaskTombstone,
        _ rhs: DeletedTaskTombstone
    ) -> Bool {
        if lhs.deletedAt != rhs.deletedAt {
            return lhs.deletedAt < rhs.deletedAt
        }
        return lhs.taskID < rhs.taskID
    }

    private static func collapsingOlderTurns(_ tasks: [CodexTask]) -> [CodexTask] {
        var result: [CodexTask] = []
        var indexByCWD: [String: Int] = [:]

        for task in tasks {
            guard let existingIndex = indexByCWD[task.cwd] else {
                indexByCWD[task.cwd] = result.count
                result.append(task)
                continue
            }

            if taskIsNewer(task, than: result[existingIndex]) {
                result[existingIndex] = task
            }
        }
        return result
    }

    private static func taskIsNewer(_ candidate: CodexTask, than current: CodexTask) -> Bool {
        if candidate.startedAt != current.startedAt {
            return candidate.startedAt > current.startedAt
        }
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        return candidate.id > current.id
    }

    private static func quarantineSnapshot(at url: URL) throws -> URL {
        guard persistenceItemState(at: url) == .regularFile else {
            throw TaskStorePersistenceError.persistenceUnavailable
        }
        let directory = url.deletingLastPathComponent()
        let basename = url.deletingPathExtension().lastPathComponent
        let destination = directory.appendingPathComponent(
            "\(basename).corrupt-\(UUID().uuidString.lowercased()).json"
        )
        try FileManager.default.moveItem(at: url, to: destination)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
        return destination
    }

    private static func persistenceItemState(at url: URL) -> PersistenceItemState {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                return .unsafe
            }
            return values.isRegularFile == true ? .regularFile : .unsafe
        } catch {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return .unsafe
            }
            return FileManager.default.fileExists(atPath: url.path) ? .unsafe : .missing
        }
    }
}

private enum PersistenceItemState {
    case missing
    case regularFile
    case unsafe
}

private struct DeletedTaskTombstone: Codable, Equatable {
    let taskID: String
    let deletedAt: Date
}

private struct TaskStoreSnapshot: Codable {
    let tasks: [CodexTask]
    let appliedEventIDs: [String]
    let deletedTaskTombstones: [DeletedTaskTombstone]

    private enum CodingKeys: String, CodingKey {
        case tasks
        case appliedEventIDs
        case deletedTaskTombstones
    }

    init(
        tasks: [CodexTask],
        appliedEventIDs: [String],
        deletedTaskTombstones: [DeletedTaskTombstone]
    ) {
        self.tasks = tasks
        self.appliedEventIDs = appliedEventIDs
        self.deletedTaskTombstones = deletedTaskTombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode([CodexTask].self, forKey: .tasks)
        appliedEventIDs = try container.decode([String].self, forKey: .appliedEventIDs)
        if container.contains(.deletedTaskTombstones) {
            deletedTaskTombstones = try container.decode(
                [DeletedTaskTombstone].self,
                forKey: .deletedTaskTombstones
            )
        } else {
            deletedTaskTombstones = []
        }
    }
}
