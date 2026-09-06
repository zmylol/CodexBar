import Foundation

/// Correlates approvals without retaining tool input or writing execution history to disk.
struct CodexApprovalTracker: Sendable {
    private static let maximumTrackedTurns = 128
    private static let maximumEntriesPerTurn = 1_024

    private struct Identity: Hashable, Sendable {
        let sessionID: String
        let turnID: String
        let cwd: String

        init(_ task: CodexTask) {
            sessionID = task.sessionID
            turnID = task.turnID
            cwd = task.cwd
        }
    }

    private struct Invocation: Sendable {
        let fingerprint: String
        let startedAt: Date
        var completedAt: Date?
    }

    private struct Approval: Sendable {
        let invocationID: String?
        let requestedAt: Date
        var isResolved = false
    }

    private struct Turn: Sendable {
        var invocations: [String: Invocation] = [:]
        var approvals: [String: Approval] = [:]
        // Missing pre-restart history and capacity overflow must never imply approval.
        var isIncomplete: Bool

        var hasCapacity: Bool {
            invocations.count + approvals.count < maximumEntriesPerTurn
        }
    }

    private var turns: [Identity: Turn] = [:]

    mutating func recordInvocation(_ event: CodexHookEvent, task: CodexTask) {
        guard event.hasConsistentTransientPayload,
              let execution = event.toolExecution,
              let invocationID = execution.invocationID,
              var turn = trackingState(for: task)
        else {
            return
        }
        let identity = Identity(task)
        guard turn.invocations[invocationID] == nil else {
            return
        }
        guard turn.hasCapacity else {
            turn.isIncomplete = true
            turns[identity] = turn
            return
        }
        turn.invocations[invocationID] = Invocation(
            fingerprint: execution.inputFingerprint,
            startedAt: event.timestamp
        )
        turns[identity] = turn
    }

    /// Returns whether this approval still needs a completion, including unknown correlations.
    @discardableResult
    mutating func recordApproval(_ event: CodexHookEvent, task: CodexTask) -> Bool {
        guard var turn = trackingState(for: task) else {
            return true
        }
        let identity = Identity(task)
        if let existing = turn.approvals[event.id] {
            return !existing.isResolved
        }
        guard turn.hasCapacity else {
            turn.isIncomplete = true
            turns[identity] = turn
            return true
        }
        let candidates = turn.invocations.filter { _, invocation in
            event.hasConsistentTransientPayload
                && invocation.startedAt <= event.timestamp
                && (invocation.completedAt.map { event.timestamp <= $0 } ?? true)
                && invocation.fingerprint == event.toolExecution?.inputFingerprint
        }
        let matchingInvocation = candidates.count == 1 ? candidates.first : nil
        let isResolved = matchingInvocation?.value.completedAt != nil
        turn.approvals[event.id] = Approval(
            invocationID: matchingInvocation?.key,
            requestedAt: event.timestamp,
            isResolved: isResolved
        )
        turns[identity] = turn
        return !isResolved
    }

    /// A completion releases only approvals that were already bound to that invocation.
    mutating func resolveApproval(_ event: CodexHookEvent, task: CodexTask) -> Bool {
        let identity = Identity(task)
        guard event.hasConsistentTransientPayload,
              let execution = event.toolExecution,
              let invocationID = execution.invocationID,
              var turn = turns[identity],
              var invocation = turn.invocations[invocationID],
              invocation.completedAt == nil,
              invocation.startedAt <= event.timestamp,
              invocation.fingerprint == execution.inputFingerprint
        else {
            return false
        }
        invocation.completedAt = event.timestamp
        turn.invocations[invocationID] = invocation
        var resolvedApproval = false
        for (eventID, var approval) in turn.approvals
        where !approval.isResolved
                && approval.invocationID == invocationID
                && approval.requestedAt <= event.timestamp {
            approval.isResolved = true
            turn.approvals[eventID] = approval
            resolvedApproval = true
        }
        turns[identity] = turn
        return resolvedApproval
            && !turn.isIncomplete
            && turn.approvals.values.allSatisfy(\.isResolved)
    }

    mutating func reset(task: CodexTask) {
        turns.removeValue(forKey: Identity(task))
    }

    mutating func acknowledgeRunning(task: CodexTask) {
        let identity = Identity(task)
        guard var turn = turns[identity] else { return }
        turn.approvals.removeAll()
        turn.isIncomplete = false
        turn.invocations = turn.invocations.filter { $0.value.completedAt == nil }
        turns[identity] = turn
    }

    mutating func retainTasks(_ tasks: [CodexTask]) {
        let activeIdentities = Set(tasks.filter { $0.status != .ready }.map(Identity.init))
        turns = turns.filter { activeIdentities.contains($0.key) }
    }

    private func trackingState(for task: CodexTask) -> Turn? {
        if let existing = turns[Identity(task)] {
            return existing
        }
        guard turns.count < Self.maximumTrackedTurns else {
            return nil
        }
        return Turn(isIncomplete: task.status == .needsAttention)
    }
}
