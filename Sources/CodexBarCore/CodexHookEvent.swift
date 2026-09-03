import Foundation

public enum CodexHookEventName: String, Codable, Equatable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
}

public struct CodexHookEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String?
    public let turnID: String?
    public let cwd: String?
    public let name: CodexHookEventName?
    public let promptSummary: String?
    public let toolName: String?
    public let timestamp: Date
    public let lastAssistantMessagePresent: Bool

    public init(
        id: String,
        sessionID: String?,
        turnID: String?,
        cwd: String?,
        name: CodexHookEventName?,
        promptSummary: String?,
        toolName: String?,
        timestamp: Date,
        lastAssistantMessagePresent: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.name = name
        self.promptSummary = promptSummary
        self.toolName = toolName
        self.timestamp = timestamp
        self.lastAssistantMessagePresent = lastAssistantMessagePresent
    }
}

public struct CodexHookEventParser: Sendable {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    public func parse(_ data: Data) throws -> CodexHookEvent {
        let payload = try JSONDecoder().decode(HookPayload.self, from: data)
        let receivedAt = now()
        let sessionID = bounded(payload.sessionID, maximumCharacters: 512)
        let turnID = bounded(payload.turnID, maximumCharacters: 512)
        let cwd = bounded(payload.cwd, maximumCharacters: 4_096)
        let name = payload.hookEventName.flatMap(CodexHookEventName.init(rawValue:))
        let promptSummary = PromptSanitizer.sanitize(payload.prompt)
        let toolName = bounded(payload.toolName, maximumCharacters: 256)
        let suppliedTimestamp = validatedTimestamp(payload.timestamp?.date, receivedAt: receivedAt)

        return CodexHookEvent(
            id: StableEventID.make(from: StableEventIdentity(
                sessionID: sessionID,
                turnID: turnID,
                cwd: cwd,
                name: name,
                promptSummary: promptSummary,
                toolName: toolName,
                suppliedTimestamp: suppliedTimestamp,
                lastAssistantMessagePresent: payload.lastAssistantMessagePresent
            )),
            sessionID: sessionID,
            turnID: turnID,
            cwd: cwd,
            name: name,
            promptSummary: promptSummary,
            toolName: toolName,
            timestamp: suppliedTimestamp ?? receivedAt,
            lastAssistantMessagePresent: payload.lastAssistantMessagePresent
        )
    }

    private func bounded(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value, value.count <= maximumCharacters else {
            return nil
        }
        return value
    }

    private func validatedTimestamp(_ timestamp: Date?, receivedAt: Date) -> Date? {
        guard let timestamp,
              timestamp.timeIntervalSince1970.isFinite,
              abs(timestamp.timeIntervalSince(receivedAt)) <= 7 * 24 * 60 * 60
        else {
            return nil
        }
        return timestamp
    }
}

public extension JSONDecoder {
    static var codexBar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            guard let date = HookTimestamp.parse(value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid CodexBar timestamp"
                )
            }
            return date
        }
        return decoder
    }
}

public extension JSONEncoder {
    static var codexBar: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(HookTimestamp.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct HookPayload: Decodable {
    let sessionID: String?
    let turnID: String?
    let cwd: String?
    let hookEventName: String?
    let prompt: String?
    let lastAssistantMessagePresent: Bool
    let toolName: String?
    let timestamp: HookTimestamp?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case cwd
        case hookEventName = "hook_event_name"
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case toolName = "tool_name"
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        hookEventName = try container.decodeIfPresent(String.self, forKey: .hookEventName)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        timestamp = try container.decodeIfPresent(HookTimestamp.self, forKey: .timestamp)
        if container.contains(.lastAssistantMessage) {
            lastAssistantMessagePresent = try !container.decodeNil(forKey: .lastAssistantMessage)
        } else {
            lastAssistantMessagePresent = false
        }
    }
}

private struct HookTimestamp: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            date = nil
        } else if let seconds = try? container.decode(Double.self) {
            let divisor: Double = seconds >= 10_000_000_000 ? 1_000 : 1
            date = Date(timeIntervalSince1970: seconds / divisor)
        } else if let value = try? container.decode(String.self) {
            date = Self.parse(value)
        } else {
            date = nil
        }
    }

    static func parse(_ value: String) -> Date? {
        if let seconds = Double(value) {
            guard seconds.isFinite else {
                return nil
            }
            let divisor: Double = seconds >= 10_000_000_000 ? 1_000 : 1
            return Date(timeIntervalSince1970: seconds / divisor)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct StableEventIdentity {
    let sessionID: String?
    let turnID: String?
    let cwd: String?
    let name: CodexHookEventName?
    let promptSummary: String?
    let toolName: String?
    let suppliedTimestamp: Date?
    let lastAssistantMessagePresent: Bool
}

private enum StableEventID {
    static func make(from identity: StableEventIdentity) -> String {
        let timestampBits = identity.suppliedTimestamp.map {
            String($0.timeIntervalSince1970.bitPattern, radix: 16)
        }
        let fields = [
            identity.sessionID,
            identity.turnID,
            identity.cwd,
            identity.name?.rawValue,
            identity.promptSummary,
            identity.toolName,
            timestampBits,
            identity.lastAssistantMessagePresent ? "1" : "0"
        ]
        var canonicalData = Data()
        for field in fields {
            guard let bytes = field?.data(using: .utf8) else {
                canonicalData.append(0)
                continue
            }
            canonicalData.append(1)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { canonicalData.append(contentsOf: $0) }
            canonicalData.append(bytes)
        }

        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in canonicalData {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }

        let hexadecimal = String(hash, radix: 16)
        return "event-" + String(repeating: "0", count: 16 - hexadecimal.count) + hexadecimal
    }
}
