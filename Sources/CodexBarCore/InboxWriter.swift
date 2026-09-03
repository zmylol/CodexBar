import Foundation

public struct InboxWriter {
    private let paths: CodexBarPaths
    private let fileManager: FileManager

    public init(paths: CodexBarPaths = CodexBarPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    public func write(_ event: CodexHookEvent) throws -> URL {
        try paths.prepareEventDirectories(fileManager: fileManager)

        let eventData = try JSONEncoder.codexBar.encode(event)
        let stem = "\(filenameTimestamp(event.timestamp))_\(UUID().uuidString.lowercased())"
        let temporaryURL = paths.inbox.appendingPathComponent(".\(stem).tmp")
        let finalURL = paths.inbox.appendingPathComponent("\(stem).json")

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: eventData,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: temporaryURL])
        }

        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporaryURL.path
        )
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        return finalURL
    }

    private func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        return formatter.string(from: date)
    }
}

public enum HookCaptureMode: Sendable {
    case probe
    case inbox
}

public struct CodexHookProbeRecord: Codable, Equatable, Sendable {
    public let sessionID: String?
    public let turnID: String?
    public let cwd: String?
    public let hookEventName: String?
    public let prompt: String?
    public let lastAssistantMessage: String?
    public let toolName: String?
    public let timestamp: Date

    public init(event: CodexHookEvent) {
        self.sessionID = event.sessionID
        self.turnID = event.turnID
        self.cwd = event.cwd
        self.hookEventName = event.name?.rawValue
        self.prompt = event.promptSummary
        self.lastAssistantMessage = event.lastAssistantMessagePresent ? "[REDACTED]" : nil
        self.toolName = event.toolName
        self.timestamp = event.timestamp
    }
}

public struct ProbeWriter {
    private let paths: CodexBarPaths
    private let fileManager: FileManager

    public init(paths: CodexBarPaths = CodexBarPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    public func write(_ record: CodexHookProbeRecord) throws -> URL {
        try paths.prepareProbeDirectory(fileManager: fileManager)
        let data = try JSONEncoder.codexBar.encode(record)
        let timestamp = Self.filenameTimestamp(record.timestamp)
        let stem = "\(timestamp)_\(UUID().uuidString.lowercased())"
        let temporaryURL = paths.probe.appendingPathComponent(".\(stem).tmp")
        let finalURL = paths.probe.appendingPathComponent("\(stem).json")

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: temporaryURL])
        }

        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: temporaryURL.path
        )
        try fileManager.moveItem(at: temporaryURL, to: finalURL)
        try paths.enforceArchiveRetention(
            in: paths.probe,
            preserving: [finalURL],
            fileManager: fileManager
        )
        return finalURL
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        return formatter.string(from: date)
    }
}

public struct HookCaptureService: Sendable {
    private let paths: CodexBarPaths
    private let parser: CodexHookEventParser

    public init(
        paths: CodexBarPaths = CodexBarPaths(),
        parser: CodexHookEventParser = CodexHookEventParser()
    ) {
        self.paths = paths
        self.parser = parser
    }

    @discardableResult
    public func capture(_ data: Data, mode: HookCaptureMode) throws -> URL {
        let event = try parser.parse(data)
        switch mode {
        case .probe:
            return try ProbeWriter(paths: paths).write(CodexHookProbeRecord(event: event))
        case .inbox:
            return try InboxWriter(paths: paths).write(event)
        }
    }
}
