import Foundation

public enum CodexTaskStatus: String, Codable, Equatable, Sendable {
    case running
    case needsAttention
    case ready
}

public struct CodexTask: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let turnID: String
    public let cwd: String
    public let workspaceName: String
    public let title: String
    public var status: CodexTaskStatus
    public let startedAt: Date
    public var updatedAt: Date
    public var isUnread: Bool

    public init(
        id: String,
        sessionID: String,
        turnID: String,
        cwd: String,
        workspaceName: String,
        title: String,
        status: CodexTaskStatus,
        startedAt: Date,
        updatedAt: Date,
        isUnread: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.workspaceName = workspaceName
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.isUnread = isUnread
    }
}
