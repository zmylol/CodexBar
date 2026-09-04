import Foundation

public struct InboxWriter {
    private static let maximumPendingActivityEvents = 12
    private static let maximumActivityEventBytes = 4 * 1_024 * 1_024

    private let paths: CodexBarPaths
    private let fileManager: FileManager

    public init(paths: CodexBarPaths = CodexBarPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    public func write(_ event: CodexHookEvent) throws -> URL {
        guard event.hasConsistentTransientPayload else {
            throw CodexHookEventCodingError.inconsistentTransientPayload
        }
        try paths.prepareEventDirectories(fileManager: fileManager)
        if event.name == .userPromptSubmit {
            removeQueuedActivity(forCWD: event.cwd)
        }

        let eventData = try JSONEncoder.codexBar.encode(event)
        let planMarker = event.plan == nil ? "" : ".plan"
        let stem = try filenameTimestamp(event.timestamp)
            + "_\(UUID().uuidString.lowercased())\(planMarker)"
        let destination = event.name == .preToolUse ? paths.activity : paths.inbox
        let temporaryURL = destination.appendingPathComponent(".\(stem).tmp")
        let finalURL = destination.appendingPathComponent("\(stem).json")

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
        if event.name == .preToolUse {
            trimPendingActivity(preserving: finalURL)
        }
        return finalURL
    }

    private func removeQueuedActivity(forCWD cwd: String?) {
        guard let cwd = canonicalCWD(cwd),
              let urls = try? fileManager.contentsOfDirectory(
                  at: paths.activity,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else {
            return
        }
        for url in urls where url.pathExtension.lowercased() == "json" {
            guard let resourceValues = try? url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            ),
                  resourceValues.isRegularFile == true,
                  (resourceValues.fileSize ?? Int.max) <= Self.maximumActivityEventBytes,
                  let data = try? Data(contentsOf: url),
                  let event = try? JSONDecoder.codexBar.decode(CodexHookEvent.self, from: data),
                  let eventCWD = canonicalCWD(event.cwd)
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
            if eventCWD == cwd {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func trimPendingActivity(preserving finalURL: URL) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: paths.activity,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let files = urls.filter { $0.pathExtension.lowercased() == "json" }
        let evictionOrder = files.sorted { lhs, rhs in
            let lhsIsPlan = isPlanActivityFile(lhs)
            let rhsIsPlan = isPlanActivityFile(rhs)
            if lhsIsPlan != rhsIsPlan {
                return !lhsIsPlan
            }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
        var excess = max(0, files.count - Self.maximumPendingActivityEvents)
        for url in evictionOrder where excess > 0 {
            if url == finalURL && isPlanActivityFile(url) {
                continue
            }
            if (try? fileManager.removeItem(at: url)) != nil {
                excess -= 1
            }
        }
    }

    private func isPlanActivityFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(".plan.json")
    }

    private func canonicalCWD(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 4_096,
              (value as NSString).isAbsolutePath
        else {
            return nil
        }
        return (value as NSString).standardizingPath
    }

    private func filenameTimestamp(_ date: Date) throws -> String {
        let roundedValue = (date.timeIntervalSince1970 * 1_000_000).rounded()
        guard let roundedMicroseconds = Int64(exactly: roundedValue) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let division = roundedMicroseconds.quotientAndRemainder(dividingBy: 1_000_000)
        var wholeSeconds = division.quotient
        var fractionalMicroseconds = division.remainder
        if fractionalMicroseconds < 0 {
            wholeSeconds -= 1
            fractionalMicroseconds += 1_000_000
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let wholeSecondDate = Date(timeIntervalSince1970: TimeInterval(wholeSeconds))
        let fraction = String(fractionalMicroseconds)
        let paddedFraction = String(repeating: "0", count: 6 - fraction.count) + fraction
        return "\(formatter.string(from: wholeSecondDate)).\(paddedFraction)Z"
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
    public let activityKind: CodexTaskActivityKind?
    public let activitySubject: String?
    public let timestamp: Date
    public let source: CodexHookSource

    public init(event: CodexHookEvent) {
        self.sessionID = event.sessionID
        self.turnID = event.turnID
        self.cwd = event.cwd
        self.hookEventName = event.name?.rawValue
        self.prompt = event.promptSummary
        self.lastAssistantMessage = event.lastAssistantMessagePresent ? "[REDACTED]" : nil
        self.toolName = event.toolName
        self.activityKind = event.activity?.kind
        self.activitySubject = event.activity?.safeSubject
        self.timestamp = event.timestamp
        self.source = event.source
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
        parser: CodexHookEventParser = CodexHookEventParser(source: .visualStudioCode)
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
