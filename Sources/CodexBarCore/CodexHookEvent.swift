import CryptoKit
import Foundation

public enum CodexHookEventName: String, Codable, Equatable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case permissionRequest = "PermissionRequest"
    case stop = "Stop"
}

public struct CodexHookToolExecution: Codable, Equatable, Sendable {
    public let invocationID: String?
    public let inputFingerprint: String

    public init(invocationID: String?, inputFingerprint: String) {
        self.invocationID = invocationID
        self.inputFingerprint = inputFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case invocationID
        case inputFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        invocationID = try container.decodeIfPresent(String.self, forKey: .invocationID)
        inputFingerprint = try container.decode(String.self, forKey: .inputFingerprint)
        guard isValid else {
            throw CodexHookEventCodingError.inconsistentTransientPayload
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw CodexHookEventCodingError.inconsistentTransientPayload
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(invocationID, forKey: .invocationID)
        try container.encode(inputFingerprint, forKey: .inputFingerprint)
    }

    fileprivate var isValid: Bool {
        Self.isSHA256(inputFingerprint) && (invocationID.map(Self.isSHA256) ?? true)
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public struct CodexHookEvent: Codable, Equatable, Sendable {
    public let id: String
    public let sessionID: String?
    public let turnID: String?
    public let cwd: String?
    public let name: CodexHookEventName?
    public let promptSummary: String?
    public let toolName: String?
    public let activity: CodexHookActivitySummary?
    public let plan: CodexHookPlanSummary?
    public let toolExecution: CodexHookToolExecution?
    public let timestamp: Date
    public let lastAssistantMessagePresent: Bool
    public let source: CodexHookSource

    public init(
        id: String,
        sessionID: String?,
        turnID: String?,
        cwd: String?,
        name: CodexHookEventName?,
        promptSummary: String?,
        toolName: String?,
        timestamp: Date,
        lastAssistantMessagePresent: Bool,
        activity: CodexHookActivitySummary? = nil,
        plan: CodexHookPlanSummary? = nil,
        toolExecution: CodexHookToolExecution? = nil,
        source: CodexHookSource
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.name = name
        self.promptSummary = promptSummary
        self.toolName = toolName
        self.activity = activity
        self.plan = plan
        self.toolExecution = toolExecution
        self.timestamp = timestamp
        self.lastAssistantMessagePresent = lastAssistantMessagePresent
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case turnID
        case cwd
        case name
        case promptSummary
        case toolName
        case activity
        case plan
        case toolExecution
        case timestamp
        case lastAssistantMessagePresent
        case source
        case destination
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasActivityPayload: Bool
        let hasPlanPayload: Bool
        let hasToolExecutionPayload: Bool
        do {
            hasActivityPayload = container.contains(.activity)
                ? try !container.decodeNil(forKey: .activity)
                : false
            hasPlanPayload = container.contains(.plan)
                ? try !container.decodeNil(forKey: .plan)
                : false
            hasToolExecutionPayload = container.contains(.toolExecution)
                ? try !container.decodeNil(forKey: .toolExecution)
                : false
        } catch {
            throw CodexHookEventCodingError.inconsistentTransientPayload
        }
        let rawSource: String?
        if container.contains(.source) {
            rawSource = try? container.decode(String.self, forKey: .source)
        } else {
            rawSource = try? container.decode(String.self, forKey: .destination)
        }
        guard let rawSource,
              let decodedSource = CodexHookSource(rawValue: rawSource)
        else {
            throw CodexHookEventCodingError.unsupportedOrMissingSource
        }

        do {
            let decodedID = try container.decode(String.self, forKey: .id)
            let decodedSessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            let decodedTurnID = try container.decodeIfPresent(String.self, forKey: .turnID)
            let decodedCWD = try container.decodeIfPresent(String.self, forKey: .cwd)
            let decodedName = try container.decodeIfPresent(
                CodexHookEventName.self,
                forKey: .name
            )
            let decodedPromptSummary = try container.decodeIfPresent(
                String.self,
                forKey: .promptSummary
            )
            let decodedToolName = try container.decodeIfPresent(String.self, forKey: .toolName)
            let decodedToolExecution = try container.decodeIfPresent(
                CodexHookToolExecution.self,
                forKey: .toolExecution
            )
            guard Self.hasConsistentTransientPayload(
                name: decodedName,
                toolName: decodedToolName,
                hasActivity: hasActivityPayload,
                hasPlan: hasPlanPayload,
                toolExecution: decodedToolExecution
            ) else {
                throw CodexHookEventCodingError.inconsistentTransientPayload
            }
            let decodedActivity = try container.decodeIfPresent(
                CodexHookActivitySummary.self,
                forKey: .activity
            )
            let decodedPlan = try container.decodeIfPresent(
                CodexHookPlanSummary.self,
                forKey: .plan
            )
            let decodedTimestamp = try container.decode(Date.self, forKey: .timestamp)
            let decodedLastAssistantMessagePresent = try container.decode(
                Bool.self,
                forKey: .lastAssistantMessagePresent
            )

            id = decodedID
            sessionID = decodedSessionID
            turnID = decodedTurnID
            cwd = decodedCWD
            name = decodedName
            promptSummary = decodedPromptSummary
            toolName = decodedToolName
            activity = decodedActivity
            plan = decodedPlan
            toolExecution = decodedToolExecution
            timestamp = decodedTimestamp
            lastAssistantMessagePresent = decodedLastAssistantMessagePresent
            source = decodedSource
        } catch let error as CodexHookEventCodingError {
            throw error
        } catch {
            if hasActivityPayload || hasPlanPayload || hasToolExecutionPayload {
                throw CodexHookEventCodingError.inconsistentTransientPayload
            }
            throw error
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard toolExecution == nil || hasConsistentTransientPayload else {
            throw CodexHookEventCodingError.inconsistentTransientPayload
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(promptSummary, forKey: .promptSummary)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encodeIfPresent(toolExecution, forKey: .toolExecution)
        try container.encode(timestamp.timeIntervalSince1970, forKey: .timestamp)
        try container.encode(lastAssistantMessagePresent, forKey: .lastAssistantMessagePresent)
        try container.encode(source, forKey: .source)
    }

    var hasConsistentTransientPayload: Bool {
        Self.hasConsistentTransientPayload(
            name: name,
            toolName: toolName,
            hasActivity: activity != nil,
            hasPlan: plan != nil,
            toolExecution: toolExecution
        )
    }

    private static func hasConsistentTransientPayload(
        name: CodexHookEventName?,
        toolName: String?,
        hasActivity: Bool,
        hasPlan: Bool,
        toolExecution: CodexHookToolExecution?
    ) -> Bool {
        let normalizedToolName = toolName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let toolExecution {
            guard toolExecution.isValid,
                  HookToolExecutionSummarizer.supports(normalizedToolName),
                  name == .preToolUse || name == .postToolUse || name == .permissionRequest,
                  name != .permissionRequest || toolExecution.invocationID == nil,
                  !hasPlan
            else {
                return false
            }
        }
        if hasPlan {
            return name == .preToolUse
                && normalizedToolName == "update_plan"
                && !hasActivity
        }
        if hasActivity {
            return name == .preToolUse && normalizedToolName != "update_plan"
        }
        return true
    }
}

enum CodexHookEventCodingError: Error {
    case unsupportedOrMissingSource
    case inconsistentTransientPayload
}

public struct CodexHookEventParser: Sendable {
    private let now: @Sendable () -> Date
    private let source: CodexHookSource

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        source: CodexHookSource
    ) {
        self.now = now
        self.source = source
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
        let toolUseID = bounded(payload.toolUseID, maximumCharacters: 512)
        let isPlanUpdate = name == .preToolUse
            && toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == "update_plan"
        let activity = name == .preToolUse && !isPlanUpdate
            ? HookActivitySummarizer.summarize(
                toolName: toolName,
                toolInput: payload.toolInput,
                cwd: cwd
            )
            : nil
        let plan = isPlanUpdate
            ? HookPlanSummarizer.summarize(toolInput: payload.toolInput)
            : nil
        let toolExecution = HookToolExecutionSummarizer.summarize(
            name: name,
            toolName: toolName,
            toolUseID: toolUseID,
            toolInput: payload.toolInput,
            mcpArguments: payload.mcpArguments
        )
        let suppliedTimestamp = validatedTimestamp(payload.timestamp?.date, receivedAt: receivedAt)
        let eventTimestamp = isPlanUpdate || toolExecution != nil
            ? receivedAt
            : (suppliedTimestamp ?? receivedAt)
        let eventID = name == .permissionRequest
            ? "event-\(UUID().uuidString.lowercased())"
            : StableEventID.make(from: StableEventIdentity(
                sessionID: sessionID,
                turnID: turnID,
                cwd: cwd,
                name: name,
                promptSummary: promptSummary,
                toolName: toolName,
                toolUseID: toolUseID,
                activity: activity,
                plan: plan,
                toolExecution: toolExecution,
                suppliedTimestamp: suppliedTimestamp,
                lastAssistantMessagePresent: payload.lastAssistantMessagePresent
            ))

        return CodexHookEvent(
            id: eventID,
            sessionID: sessionID,
            turnID: turnID,
            cwd: cwd,
            name: name,
            promptSummary: promptSummary,
            toolName: toolName,
            timestamp: eventTimestamp,
            lastAssistantMessagePresent: payload.lastAssistantMessagePresent,
            activity: activity,
            plan: plan,
            toolExecution: toolExecution,
            source: source
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
    let toolUseID: String?
    let toolInput: HookToolInput?
    let mcpArguments: [String: HookJSONValue]?
    let timestamp: HookTimestamp?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case cwd
        case hookEventName = "hook_event_name"
        case prompt
        case lastAssistantMessage = "last_assistant_message"
        case toolName = "tool_name"
        case toolUseID = "tool_use_id"
        case toolInput = "tool_input"
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
        toolUseID = try container.decodeIfPresent(String.self, forKey: .toolUseID)
        toolInput = try? container.decode(HookToolInput.self, forKey: .toolInput)
        if toolName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("mcp__") == true {
            mcpArguments = try? container.decode([String: HookJSONValue].self, forKey: .toolInput)
        } else {
            mcpArguments = nil
        }
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
    let toolUseID: String?
    let activity: CodexHookActivitySummary?
    let plan: CodexHookPlanSummary?
    let toolExecution: CodexHookToolExecution?
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
            identity.toolUseID,
            identity.activity?.kind.rawValue,
            identity.activity?.safeSubject,
            planIdentity(identity.plan),
            identity.toolExecution?.inputFingerprint,
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

    private static func planIdentity(_ plan: CodexHookPlanSummary?) -> String? {
        plan?.steps.map { step in
            "\(step.status.rawValue):\(step.title)"
        }.joined(separator: "\u{1F}")
    }
}

private enum HookToolExecutionSummarizer {
    static func supports(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        return toolName == "bash" || toolName == "apply_patch"
            || toolName.range(of: "^mcp__.+__.+$", options: .regularExpression) != nil
    }

    static func summarize(
        name: CodexHookEventName?,
        toolName: String?,
        toolUseID: String?,
        toolInput: HookToolInput?,
        mcpArguments: [String: HookJSONValue]?
    ) -> CodexHookToolExecution? {
        guard name == .preToolUse || name == .postToolUse || name == .permissionRequest,
              let toolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              supports(toolName.lowercased())
        else {
            return nil
        }

        let normalizedToolName = toolName.lowercased()
        let input: HookJSONValue
        if normalizedToolName == "bash" || normalizedToolName == "apply_patch" {
            guard let command = toolInput?.command ?? toolInput?.patch else {
                return nil
            }
            input = .string(command)
        } else {
            guard var arguments = mcpArguments else {
                return nil
            }
            // PermissionRequest adds this presentation field outside the tool's arguments.
            arguments.removeValue(forKey: "description")
            input = .object(arguments)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let identityToolName = normalizedToolName.hasPrefix("mcp__")
            ? toolName
            : normalizedToolName
        guard let canonicalInput = try? encoder.encode([
            "tool": HookJSONValue.string(identityToolName), "input": input
        ]) else {
            return nil
        }
        return CodexHookToolExecution(
            invocationID: name == .permissionRequest ? nil : toolUseID.map {
                sha256(Data($0.utf8))
            },
            inputFingerprint: sha256(canonicalInput)
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum HookJSONValue: Codable {
    case null
    case bool(Bool)
    case string(String)
    case number(Decimal)
    case array([HookJSONValue])
    case object([String: HookJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .number(value)
        } else if let value = try? container.decode([HookJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: HookJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

private struct HookToolInput: Decodable {
    let command: String?
    let patch: String?
    let path: String?
    let filePath: String?
    let plan: [HookPlanItem]?

    private enum CodingKeys: String, CodingKey {
        case command
        case patch
        case path
        case filePath = "file_path"
        case plan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try? container.decode(String.self, forKey: .command)
        patch = try? container.decode(String.self, forKey: .patch)
        path = try? container.decode(String.self, forKey: .path)
        filePath = try? container.decode(String.self, forKey: .filePath)
        plan = try? container.decode([HookPlanItem].self, forKey: .plan)
    }
}

private struct HookPlanItem: Decodable {
    let step: String
    let status: CodexTaskPlanStepStatus
}

private enum HookPlanSummarizer {
    static func summarize(toolInput: HookToolInput?) -> CodexHookPlanSummary? {
        guard let rawSteps = toolInput?.plan,
              rawSteps.count <= CodexHookPlanSummary.maximumSteps,
              rawSteps.filter({ $0.status == .inProgress }).count <= 1
        else {
            return nil
        }

        var steps: [CodexTaskPlanStep] = []
        steps.reserveCapacity(rawSteps.count)
        for (index, item) in rawSteps.enumerated() {
            guard item.step.utf8.count <= CodexHookPlanSummary.maximumRawTitleBytes,
                  item.step.count <= CodexHookPlanSummary.maximumRawTitleCharacters,
                  let title = PromptSanitizer.sanitize(
                      item.step,
                      maxLength: CodexHookPlanSummary.maximumTitleCharacters
                  ),
                  title.utf8.count <= CodexHookPlanSummary.maximumTitleBytes
            else {
                return nil
            }
            steps.append(CodexTaskPlanStep(id: index, title: title, status: item.status))
        }
        return CodexHookPlanSummary(steps: steps)
    }
}

private enum HookActivitySummarizer {
    static func summarize(
        toolName: String?,
        toolInput: HookToolInput?,
        cwd: String?
    ) -> CodexHookActivitySummary? {
        guard let toolName = toolName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !toolName.isEmpty
        else {
            return nil
        }

        switch toolName {
        case "read", "read_file", "view_image":
            return CodexHookActivitySummary(
                kind: .read,
                safeSubject: safePath(toolInput?.filePath ?? toolInput?.path, cwd: cwd)
            )
        case "grep", "glob", "rg", "search", "web_search":
            return CodexHookActivitySummary(
                kind: .search,
                safeSubject: safePath(toolInput?.path, cwd: cwd)
            )
        case "apply_patch", "edit", "multiedit", "write":
            let patchPath = (toolInput?.command ?? toolInput?.patch).flatMap(pathFromPatch)
            return CodexHookActivitySummary(
                kind: .edit,
                safeSubject: safePath(
                    patchPath ?? toolInput?.filePath ?? toolInput?.path,
                    cwd: cwd
                )
            )
        case "bash", "shell", "shell_command", "exec_command":
            return commandSummary(toolInput?.command)
        case "spawn_agent", "send_input", "send_message", "wait_agent", "resume_agent", "close_agent", "followup_task", "interrupt_agent":
            return CodexHookActivitySummary(kind: .agent, safeSubject: nil)
        default:
            return CodexHookActivitySummary(kind: .command, safeSubject: nil)
        }
    }

    private static func commandSummary(_ command: String?) -> CodexHookActivitySummary {
        guard let command else {
            return CodexHookActivitySummary(kind: .command, safeSubject: nil)
        }
        let words = command
            .prefix(1_024)
            .split(whereSeparator: \Character.isWhitespace)
            .prefix(32)
            .map { executableName(String($0)).lowercased() }

        guard let executable = words.first else {
            return CodexHookActivitySummary(kind: .command, safeSubject: nil)
        }

        let testSubject: String?
        if ["python", "python3"].contains(executable),
           words.dropFirst().prefix(2).elementsEqual(["-m", "pytest"]) {
            return CodexHookActivitySummary(kind: .test, safeSubject: "Python")
        }
        if ["npm", "pnpm", "yarn", "bun", "deno"].contains(executable),
           isJavaScriptTest(words) {
            return CodexHookActivitySummary(kind: .test, safeSubject: "JavaScript")
        }
        if ["mvn", "mvnw", "gradle", "gradlew"].contains(executable),
           words.contains("test") {
            return CodexHookActivitySummary(kind: .test, safeSubject: "Java")
        }
        switch executable {
        case "swift" where words.dropFirst().first == "test":
            testSubject = "Swift"
        case "xcodebuild" where words.contains("test"):
            testSubject = "Xcode"
        case "pytest":
            testSubject = "Python"
        case "go" where words.dropFirst().first == "test":
            testSubject = "Go"
        case "cargo" where words.dropFirst().first == "test":
            testSubject = "Rust"
        case "dotnet" where words.dropFirst().first == "test":
            testSubject = ".NET"
        default:
            testSubject = nil
        }

        if let testSubject {
            return CodexHookActivitySummary(kind: .test, safeSubject: testSubject)
        }

        if ["rg", "ripgrep", "grep", "egrep", "fgrep", "find", "fd", "fdfind", "ag"]
            .contains(executable) {
            return CodexHookActivitySummary(kind: .search, safeSubject: nil)
        }
        if ["cat", "head", "tail", "less", "more", "wc", "ls", "tree", "pwd", "stat"]
            .contains(executable) {
            return CodexHookActivitySummary(kind: .read, safeSubject: nil)
        }
        if executable == "sed", !words.dropFirst().contains(where: { $0.hasPrefix("-i") }) {
            return CodexHookActivitySummary(kind: .read, safeSubject: nil)
        }
        return CodexHookActivitySummary(kind: .command, safeSubject: nil)
    }

    private static func isJavaScriptTest(_ words: [String]) -> Bool {
        guard words.count > 1 else {
            return false
        }
        if words[1] == "test" {
            return true
        }
        return words.count > 2 && words[1] == "run" && words[2] == "test"
    }

    private static func executableName(_ word: String) -> String {
        let unquoted = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return (unquoted as NSString).lastPathComponent
    }

    private static func pathFromPatch(_ patch: String) -> String? {
        let prefixes = [
            "*** Update File: ",
            "*** Add File: ",
            "*** Delete File: ",
            "*** Move to: "
        ]
        for line in patch.prefix(64 * 1_024).split(separator: "\n", omittingEmptySubsequences: false) {
            for prefix in prefixes where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
        }
        return nil
    }

    private static func safePath(_ value: String?, cwd: String?) -> String? {
        guard var value = value?.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.count <= 4_096
        else {
            return nil
        }

        if value.count >= 2,
           (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        value = value.replacingOccurrences(of: "\\", with: "/")

        let isAbsolute = value.hasPrefix("/")
            || value.hasPrefix("~/")
            || value.range(of: #"^[A-Za-z]:/"#, options: .regularExpression) != nil
        let standardized = (value as NSString).standardizingPath
        let candidate: String
        if isAbsolute {
            if let cwd,
               let normalizedCWD = standardizedAbsolutePath(cwd),
               standardized.hasPrefix(normalizedCWD + "/") {
                candidate = String(standardized.dropFirst(normalizedCWD.count + 1))
            } else {
                candidate = (standardized as NSString).lastPathComponent
            }
        } else if standardized == ".." || standardized.hasPrefix("../") {
            candidate = (standardized as NSString).lastPathComponent
        } else {
            candidate = standardized.hasPrefix("./")
                ? String(standardized.dropFirst(2))
                : standardized
        }

        return PromptSanitizer.sanitize(candidate, maxLength: 160)
    }

    private static func standardizedAbsolutePath(_ value: String) -> String? {
        let standardized = (value as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized != "/" else {
            return nil
        }
        return standardized
    }
}
