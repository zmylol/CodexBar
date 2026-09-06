import CoreFoundation
import Foundation

public enum CodexConversationItemKind: Equatable, Sendable {
    case user, assistant, tool, information
}

public struct CodexConversationItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: CodexConversationItemKind
    public let title: String
    public let text: String
    public let detail: String?
    public let isError: Bool
    public let isRunning: Bool

    public init(id: String, kind: CodexConversationItemKind, title: String, text: String,
                detail: String? = nil, isError: Bool = false, isRunning: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.detail = detail
        self.isError = isError
        self.isRunning = isRunning
    }
}

public struct CodexConversationPreview: Equatable, Sendable {
    public let sessionID: String
    public let cwd: String
    public let items: [CodexConversationItem]
    public let historyComplete: Bool
    public let revision: Int

    public init(sessionID: String, cwd: String, items: [CodexConversationItem], historyComplete: Bool, revision: Int) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.items = items
        self.historyComplete = historyComplete
        self.revision = revision
    }
}

public struct CodexConversationPreviewResult: Sendable {
    public var preview: CodexConversationPreview?
    public var needsSnapshot: Bool
    public var invalidated: Bool

    public init(preview: CodexConversationPreview? = nil, needsSnapshot: Bool = false, invalidated: Bool = false) {
        self.preview = preview
        self.needsSnapshot = needsSnapshot
        self.invalidated = invalidated
    }
}

/// Holds only the selected conversation in memory. Reset when its preview is dismissed.
public struct CodexConversationPreviewReducer: Sendable {
    private let sessionID: String
    private let cwd: String?
    private var state: PreviewValue?
    private var revision: Int?
    private var owner: String?
    private var retiredOwners: Set<String> = []
    private var awaitingSnapshot = false
    private var exceededLimit = false

    public init(sessionID: String, cwd: String) {
        self.sessionID = sessionID
        self.cwd = PathNormalizer.normalize(cwd)
    }

    public mutating func reset() {
        state = nil
        revision = nil
        owner = nil
        retiredOwners.removeAll()
        awaitingSnapshot = false
        exceededLimit = false
    }

    public mutating func consume(_ data: Data) -> CodexConversationPreviewResult {
        guard !exceededLimit else { return CodexConversationPreviewResult() }
        if data.count > PreviewValue.maximumSize {
            // The transport bounds frames to 64 MiB. A larger unrelated conversation
            // must not exhaust this selection's smaller content budget.
            guard data.count <= 64 * 1_024 * 1_024,
                  let header = try? JSONDecoder().decode(PreviewIdentityHeader.self, from: data),
                  header.type == "broadcast", header.method == "thread-stream-state-changed",
                  header.params.conversationId == sessionID, header.params.hostId == "local"
            else { return CodexConversationPreviewResult() }
            return invalidate(requestSnapshot: false, limit: true)
        }
        guard let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              frame["type"] as? String == "broadcast",
              frame["method"] as? String == "thread-stream-state-changed",
              let params = frame["params"] as? [String: Any],
              params["conversationId"] as? String == sessionID,
              params["hostId"] as? String == "local",
              let sourceOwner = frame["sourceClientId"] as? String,
              !sourceOwner.isEmpty, sourceOwner.utf8.count <= 512,
              !retiredOwners.contains(sourceOwner)
        else { return CodexConversationPreviewResult() }
        guard previewInteger(frame["version"]) == 11, cwd != nil else {
            return invalidate(requestSnapshot: false)
        }
        let change = params["change"] as? [String: Any]
        let isPatch = change?["type"] as? String == "patches"
        do {
            guard let change, let nextRevision = previewInteger(change["revision"]), nextRevision >= 0 else {
                throw PreviewError.invalid
            }
            if owner != sourceOwner {
                if let owner {
                    guard retiredOwners.count < 32 else { throw PreviewError.limit }
                    retiredOwners.insert(owner)
                }
                owner = sourceOwner
                state = nil
                revision = nil
                awaitingSnapshot = false
            }
            if let revision, nextRevision < revision || (isPatch && nextRevision == revision) {
                return CodexConversationPreviewResult()
            }
            var next: PreviewValue
            switch change["type"] as? String {
            case "snapshot":
                guard let snapshot = change["conversationState"] as? [String: Any] else { throw PreviewError.invalid }
                next = try PreviewValue(snapshot)
            case "patches":
                guard let state, let revision, previewInteger(change["baseRevision"]) == revision,
                      let patches = change["patches"] as? [[String: Any]], patches.count <= 10_000
                else { throw PreviewError.invalid }
                next = state
                for patch in patches { try next.apply(patch) }
            default:
                throw PreviewError.invalid
            }
            guard next["id"].string == sessionID,
                  next["sessionId"].string == nil || next["sessionId"].string == sessionID,
                  next["source"].string == "vscode",
                  let snapshotCWD = next["cwd"].string,
                  PathNormalizer.normalize(snapshotCWD) == cwd
            else { return invalidate(requestSnapshot: false) }
            let preview = try project(next, revision: nextRevision)
            state = next
            revision = nextRevision
            awaitingSnapshot = false
            return CodexConversationPreviewResult(preview: preview)
        } catch {
            return invalidate(requestSnapshot: isPatch, limit: error as? PreviewError == .limit)
        }
    }

    private mutating func invalidate(requestSnapshot: Bool, limit: Bool = false) -> CodexConversationPreviewResult {
        state = nil
        let needsSnapshot = requestSnapshot && !awaitingSnapshot && !limit
        awaitingSnapshot = true
        exceededLimit = limit
        return CodexConversationPreviewResult(needsSnapshot: needsSnapshot, invalidated: true)
    }

    private func project(_ state: PreviewValue, revision: Int) throws -> CodexConversationPreview {
        let live = state["turns"].array ?? []
        var turns = live
        let canonical = state["turnHistory"]["kind"].string == "canonical"
        var complete = state["resumeState"].string == "resumed"
            && (state["turnsPagination"]["hasLoadedOldest"].bool ?? !canonical)
        if canonical {
            let history = state["turnHistory"]["history"]
            guard let islands = history["islands"].array, history["entitiesByKey"].object != nil else {
                throw PreviewError.invalid
            }
            turns = try islands.flatMap { island in
                guard let entries = island["entries"].array else { throw PreviewError.invalid }
                return try entries.map { entry in
                    guard let key = entry["value"].string,
                          !history["entitiesByKey"][key].isNull else { throw PreviewError.invalid }
                    return history["entitiesByKey"][key]
                }
            }
            complete = complete || (history["isComplete"].bool == true && islands.count == 1)
            turns = try mergeOrdered(turns, live, identity: { $0["turnId"].string }) { old, new in
                var merged = new.object ?? [:]
                if merged["params"] == nil { merged["params"] = old["params"] }
                merged["items"] = try PreviewValue.arrayValue(mergeOrdered(old["items"].array ?? [], new["items"].array ?? [],
                    identity: { $0["id"].string }, merge: { previous, latest in
                        let terminal = ["completed", "failed", "declined", "denied", "interrupted"]
                        let active = ["inProgress", "in_progress", "running"]
                        if terminal.contains(previous["status"].string ?? ""), active.contains(latest["status"].string ?? "") {
                            return previous
                        }
                        return latest
                    }))
                if old["itemsPagination"]["hasLoadedOldest"].bool == false {
                    merged["itemsPagination"] = old["itemsPagination"]
                }
                return try PreviewValue.objectValue(merged)
            }
        }
        complete = complete && state["turnsPagination"]["source"].string != "compact"
            && turns.allSatisfy { $0["itemsPagination"]["hasLoadedOldest"].bool != false }
        var items: [CodexConversationItem] = []
        var seen: Set<String> = []
        for (turnIndex, turn) in turns.enumerated() {
            let turnID = turn["turnId"].string ?? "turn-\(turnIndex)"
            let turnItems = turn["items"].array ?? []
            let input = contentText(turn["params"]["input"])
            if !input.isEmpty, !turnItems.contains(where: { $0["type"].string == "userMessage" }) {
                items.append(CodexConversationItem(id: "input:\(turnID)", kind: .user, title: "你", text: input))
            }
            for (itemIndex, item) in turnItems.enumerated() {
                let localID = item["id"].string ?? "item-\(itemIndex)"
                let id = "\(turnID.utf8.count):\(turnID)\(localID)"
                guard seen.insert(id).inserted else { continue }
                if let projected = projectItem(item, id: id) { items.append(projected) }
            }
        }
        return CodexConversationPreview(sessionID: sessionID, cwd: cwd ?? "", items: items, historyComplete: complete, revision: revision)
    }
}

/// Merge by the order of each list, placing new entries before their next shared anchor.
private func mergeOrdered(
    _ history: [PreviewValue], _ live: [PreviewValue], identity: (PreviewValue) -> String?,
    merge: (PreviewValue, PreviewValue) throws -> PreviewValue
) rethrows -> [PreviewValue] {
    let liveByID = Dictionary(live.compactMap { value in identity(value).map { ($0, value) } }, uniquingKeysWith: { _, new in new })
    let historyIDs = Set(history.compactMap(identity))
    var result = try history.map { old in
        guard let id = identity(old), let new = liveByID[id] else { return old }
        return try merge(old, new)
    }
    var pending: [PreviewValue] = []
    for value in live {
        if let id = identity(value), historyIDs.contains(id) {
            if !pending.isEmpty, let index = result.firstIndex(where: { identity($0) == id }) {
                result.insert(contentsOf: pending, at: index)
                pending.removeAll(keepingCapacity: true)
            }
        } else { pending.append(value) }
    }
    return result + pending
}

private func projectItem(_ item: PreviewValue, id: String) -> CodexConversationItem? {
    let status = item["status"].string
    let running = status == "inProgress" || status == "in_progress" || status == "running"
    let error = status == "failed" || status == "declined" || status == "denied"
        || item["success"].bool == false || item["result"]["isError"].bool == true || !item["error"].isNull
    let suffix = running ? " · 进行中" : error ? " · 失败" : status == "completed" ? " · 已完成" : ""
    func make(_ kind: CodexConversationItemKind, _ title: String, _ text: String, detail: String? = nil,
              isError: Bool? = nil) -> CodexConversationItem {
        CodexConversationItem(id: id, kind: kind, title: title, text: text, detail: detail,
                              isError: isError ?? error, isRunning: running)
    }
    switch item["type"].string {
    case "userMessage":
        return make(.user, "你", contentText(item["content"]))
    case "steeringUserMessage":
        return make(.user, "你", contentText(item["input"]))
    case "agentMessage":
        return make(.assistant, "Codex", item["text"].string ?? "")
    case "commandExecution":
        let exitCode = item["exitCode"].integer
        let failed = error || (exitCode != nil && exitCode != 0)
        let command = item["command"].string ?? item["command"].array?.compactMap(\.string).joined(separator: " ")
        let firstLine = command?.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { !$0.isEmpty }) ?? "命令"
        let name = firstLine.count > 100 ? String(firstLine.prefix(99)) + "…" : firstLine
        let title = name + (running ? " · 进行中" : failed ? " · 失败" : status == "completed" ? " · 已完成" : "")
        return make(.tool, title + (exitCode.map { " · 退出码 \($0)" } ?? ""), item["aggregatedOutput"].string ?? "",
                    detail: command, isError: failed)
    case "dynamicToolCall":
        return make(.tool, (item["tool"].string ?? "工具调用") + suffix, contentText(item["contentItems"]),
                    detail: item["arguments"].isNull ? nil : "输入参数\n" + item["arguments"].displayJSON)
    case "functionCallOutput":
        let output = item["output"]
        return make(.tool, item["name"].string ?? "工具结果", output.isNull ? "" : output.displayJSON,
                    detail: item["namespace"].string)
    case "mcpToolCall":
        let result = item["result"]
        var parts = [contentText(result["content"])]
        if !result["structuredContent"].isNull { parts.append(result["structuredContent"].displayJSON) }
        if !item["error"].isNull { parts.append(item["error"]["message"].string ?? item["error"].string ?? "工具返回错误") }
        let name = item["tool"].string ?? item["toolName"].string ?? "MCP 工具"
        let context = [item["server"].string, item["arguments"].isNull ? nil : "输入参数\n" + item["arguments"].displayJSON]
            .compactMap { $0 }.joined(separator: "\n")
        return make(.tool, name + suffix, parts.filter { !$0.isEmpty }.joined(separator: "\n\n"), detail: context.isEmpty ? nil : context)
    case "fileChange":
        let changes = (item["changes"].array ?? []).map { change in
            [change["path"].string, change["kind"]["type"].string ?? change["kind"].string, change["diff"].string]
                .compactMap { $0 }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return make(.tool, "文件修改" + suffix, changes)
    case "webSearch":
        let action = item["action"]
        let query = action["query"].string ?? item["query"].string
        let urls = action["urls"].array?.compactMap(\.string) ?? item["urls"].array?.compactMap(\.string) ?? []
        let details = [action["type"].string, query, action["url"].string, action["pattern"].string]
            .compactMap { $0 } + urls
        return make(.tool, "网页检索" + suffix, details.joined(separator: "\n"))
    case "collabAgentToolCall", "subAgentActivity":
        let label = item["tool"].string ?? "子代理"
        return make(.information, "协作" + suffix, [label, status].compactMap { $0 }.joined(separator: " · "))
    case "reasoning":
        let summary = summaryText(item["summary"])
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return make(.information, "思考摘要", summary)
    default:
        return make(.information, "会话事件" + suffix, "此类内容请在会话中查看。")
    }
}

private func contentText(_ value: PreviewValue) -> String {
    if let text = value.string { return text }
    return (value.array ?? []).map { content in
        switch content["type"].string {
        case "text", "inputText": return content["text"].string ?? ""
        case "image", "inputImage", "localImage": return "[图片，请在会话中查看]"
        case "audio", "inputAudio": return "[音频，请在会话中查看]"
        case "resource", "resource_link": return "[附件，请在会话中查看]"
        default: return "[其他内容，请在会话中查看]"
        }
    }.joined(separator: "\n")
}

private func summaryText(_ value: PreviewValue) -> String {
    value.string ?? (value.array ?? []).compactMap { $0.string ?? $0["text"].string }.joined(separator: "\n")
}

private enum PreviewError: Error { case invalid, limit }

private struct PreviewIdentityHeader: Decodable {
    let type: String
    let method: String
    let params: Parameters
    struct Parameters: Decodable {
        let conversationId: String
        let hostId: String
    }
}

private func previewInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return Int(exactly: number.doubleValue)
}

/// The cached size bounds accumulated patches as well as individual wire frames.
private struct PreviewValue: Sendable {
    static let maximumSize = 32 * 1_024 * 1_024
    private indirect enum Storage: Sendable {
        case null, string(String), number(Double), bool(Bool), array([PreviewValue]), object([String: PreviewValue])
    }
    private var storage: Storage
    private var size: Int
    private static let null = PreviewValue(storage: .null, size: 64)

    private init(storage: Storage, size: Int) {
        self.storage = storage
        self.size = size
    }

    init(_ value: Any, depth: Int = 0) throws {
        var remaining = Self.maximumSize
        self = try Self.decode(value, depth: depth, remaining: &remaining)
    }

    private static func decode(_ value: Any, depth: Int, remaining: inout Int) throws -> PreviewValue {
        guard depth <= 96 else { throw PreviewError.limit }
        remaining -= 64
        guard remaining >= 0 else { throw PreviewError.limit }
        switch value {
        case let text as String:
            remaining -= text.utf8.count
            guard remaining >= 0 else { throw PreviewError.limit }
            return PreviewValue(storage: .string(text), size: 64 + text.utf8.count)
        case let number as NSNumber:
            return PreviewValue(storage: CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue), size: 64)
        case let values as [Any]:
            guard values.count <= 20_000 else { throw PreviewError.limit }
            return try Self.arrayValue(values.map { try decode($0, depth: depth + 1, remaining: &remaining) })
        case let values as [String: Any]:
            guard values.count <= 20_000 else { throw PreviewError.limit }
            remaining -= values.keys.reduce(0) { $0 + $1.utf8.count }
            guard remaining >= 0 else { throw PreviewError.limit }
            return try Self.objectValue(values.mapValues { try decode($0, depth: depth + 1, remaining: &remaining) })
        case is NSNull:
            return .null
        default:
            throw PreviewError.invalid
        }
    }

    static func arrayValue(_ values: [PreviewValue]) throws -> PreviewValue {
        try bounded(.array(values), count: values.count, size: 64 + values.reduce(0) { $0 + $1.size })
    }

    static func objectValue(_ values: [String: PreviewValue]) throws -> PreviewValue {
        try bounded(.object(values), count: values.count, size: 64 + values.reduce(0) { $0 + $1.key.utf8.count + $1.value.size })
    }

    private static func bounded(_ storage: Storage, count: Int, size: Int) throws -> PreviewValue {
        guard count <= 20_000, size <= maximumSize else { throw PreviewError.limit }
        return PreviewValue(storage: storage, size: size)
    }

    var string: String? { if case let .string(value) = storage { return value }; return nil }
    var bool: Bool? { if case let .bool(value) = storage { return value }; return nil }
    var integer: Int? { if case let .number(value) = storage { return Int(exactly: value) }; return nil }
    var array: [PreviewValue]? { if case let .array(value) = storage { return value }; return nil }
    var object: [String: PreviewValue]? { if case let .object(value) = storage { return value }; return nil }
    var isNull: Bool { if case .null = storage { return true }; return false }
    subscript(_ key: String) -> PreviewValue { object?[key] ?? .null }

    var displayJSON: String {
        if let string { return string }
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private var foundationValue: Any {
        switch storage {
        case .null: return NSNull()
        case let .string(value): return value
        case let .number(value): return value
        case let .bool(value): return value
        case let .array(value): return value.map(\.foundationValue)
        case let .object(value): return value.mapValues(\.foundationValue)
        }
    }

    mutating func apply(_ patch: [String: Any]) throws {
        guard let op = patch["op"] as? String, ["add", "replace", "remove"].contains(op),
              let path = patch["path"] as? [Any], path.count <= 96 else { throw PreviewError.invalid }
        let value: PreviewValue?
        if op == "remove" { value = nil }
        else {
            guard let raw = patch["value"] else { throw PreviewError.invalid }
            value = try PreviewValue(raw, depth: path.count)
        }
        try apply(op: op, path: path[...], value: value)
    }

    private mutating func apply(op: String, path: ArraySlice<Any>, value: PreviewValue?) throws {
        guard let head = path.first else {
            guard op != "remove", let value else { throw PreviewError.invalid }
            self = value
            return
        }
        let tail = path.dropFirst()
        switch storage {
        case .object(var values):
            guard let key = head as? String else { throw PreviewError.invalid }
            if tail.isEmpty {
                guard op == "add" || values[key] != nil else { throw PreviewError.invalid }
                if op == "remove" { values.removeValue(forKey: key) }
                else { values[key] = value }
            } else {
                guard var child = values[key] else { throw PreviewError.invalid }
                try child.apply(op: op, path: tail, value: value)
                values[key] = child
            }
            self = try Self.objectValue(values)
        case .array(var values):
            guard let index = previewInteger(head), index >= 0 else { throw PreviewError.invalid }
            if tail.isEmpty && op == "add", let value, index <= values.count { values.insert(value, at: index) }
            else {
                guard values.indices.contains(index) else { throw PreviewError.invalid }
                if tail.isEmpty && op == "remove" { values.remove(at: index) }
                else { try values[index].apply(op: op, path: tail, value: value) }
            }
            self = try Self.arrayValue(values)
        default: throw PreviewError.invalid
        }
    }
}
