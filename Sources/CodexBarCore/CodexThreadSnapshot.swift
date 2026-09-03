import Foundation

public enum CodexThreadSource: String, Equatable, Sendable {
    case vscode
    case cli
}

public enum CodexThreadTurnStatus: String, Equatable, Sendable {
    case inProgress
    case completed
    case interrupted
    case failed
}

/// The latest persisted turn for one Codex thread.
///
/// Startup recovery intentionally keeps only this small metadata surface. It
/// never retains the full Codex transcript or assistant output.
public struct CodexThreadSnapshot: Equatable, Sendable {
    public let sessionID: String
    public let turnID: String
    public let cwd: String
    public let title: String
    public let source: CodexThreadSource
    public let status: CodexThreadTurnStatus
    public let startedAt: Date
    public let updatedAt: Date

    public init(
        sessionID: String,
        turnID: String,
        cwd: String,
        title: String,
        source: CodexThreadSource,
        status: CodexThreadTurnStatus,
        startedAt: Date,
        updatedAt: Date
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.title = title
        self.source = source
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

public protocol CodexThreadSnapshotLoading: Sendable {
    func loadSnapshots(
        matching windows: [VSCodeWindowDescriptor]
    ) async throws -> [CodexThreadSnapshot]

    func loadSnapshots(
        matchingActiveTasks tasks: [CodexTask]
    ) async throws -> [CodexThreadSnapshot]
}
