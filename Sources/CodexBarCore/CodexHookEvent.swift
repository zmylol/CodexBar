import Foundation

public enum CodexHookEventName: String, Codable, Equatable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
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
    public let activity: CodexHookActivitySummary?
    public let timestamp: Date
    public let lastAssistantMessagePresent: Bool
    public let destination: CodexTaskDestination?

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
        destination: CodexTaskDestination? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.name = name
        self.promptSummary = promptSummary
        self.toolName = toolName
        self.activity = activity
        self.timestamp = timestamp
        self.lastAssistantMessagePresent = lastAssistantMessagePresent
        self.destination = destination
    }
}

public struct CodexHookEventParser: Sendable {
    private let now: @Sendable () -> Date
    private let destination: CodexTaskDestination?

    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        destination: CodexTaskDestination? = nil
    ) {
        self.now = now
        self.destination = destination
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
        let activity = name == .preToolUse
            ? HookActivitySummarizer.summarize(
                toolName: toolName,
                toolInput: payload.toolInput,
                cwd: cwd
            )
            : nil
        let suppliedTimestamp = validatedTimestamp(payload.timestamp?.date, receivedAt: receivedAt)

        return CodexHookEvent(
            id: StableEventID.make(from: StableEventIdentity(
                sessionID: sessionID,
                turnID: turnID,
                cwd: cwd,
                name: name,
                promptSummary: promptSummary,
                toolName: toolName,
                toolUseID: toolUseID,
                activity: activity,
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
            lastAssistantMessagePresent: payload.lastAssistantMessagePresent,
            activity: activity,
            destination: destination
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

private struct HookToolInput: Decodable {
    let command: String?
    let patch: String?
    let path: String?
    let filePath: String?

    private enum CodingKeys: String, CodingKey {
        case command
        case patch
        case path
        case filePath = "file_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        command = try? container.decode(String.self, forKey: .command)
        patch = try? container.decode(String.self, forKey: .patch)
        path = try? container.decode(String.self, forKey: .path)
        filePath = try? container.decode(String.self, forKey: .filePath)
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
