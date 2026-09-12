import Foundation
import CryptoKit

public struct CodexRuntimeStatusUpdate: Equatable, Sendable {
    public let sessionID: String
    public let turnID: String?
    public let cwd: String?
    public let status: CodexTaskStatus

    public init(sessionID: String, turnID: String?, cwd: String?, status: CodexTaskStatus) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.cwd = cwd
        self.status = status
    }
}

public struct CodexRuntimeStatusResult: Sendable {
    /// Validated local envelope identity, including frames that leave task status unchanged.
    public var sessionID: String?
    public var update: CodexRuntimeStatusUpdate?
    public var resnapshotSessionID: String?
    public var invalidatedSessionID: String?
}

/// Projects only runtime metadata from the version 11 local conversation stream.
/// Message bodies, tool input/output, titles, and history content are never retained.
public struct CodexRuntimeStatusReducer: Sendable {
    private struct State: Sendable {
        var revision: Int
        var owner: String
        var metadata: RuntimeMetadata
        var update: CodexRuntimeStatusUpdate?
    }

    private var states: [String: State] = [:]
    private var awaitingSnapshots: Set<String> = []

    public init() {}

    public mutating func reset(sessionID: String) {
        states.removeValue(forKey: sessionID)
        awaitingSnapshots.remove(sessionID)
    }
    public mutating func reset() {
        states.removeAll()
        awaitingSnapshots.removeAll()
    }

    public mutating func consume(_ data: Data) -> CodexRuntimeStatusResult {
        guard data.count <= 64 * 1_024 * 1_024,
              let header = try? JSONDecoder().decode(RuntimeHeader.self, from: data),
              header.type == "broadcast", header.method == "thread-stream-state-changed",
              header.params.hostId == "local",
              validRuntimeIdentifier(header.params.conversationId),
              validRuntimeIdentifier(header.sourceClientId)
        else { return CodexRuntimeStatusResult() }

        let sessionID = header.params.conversationId
        guard header.version == 11 else {
            reset(sessionID: sessionID)
            return CodexRuntimeStatusResult(sessionID: sessionID, invalidatedSessionID: sessionID)
        }
        let previous = states[sessionID]
        do {
            let frame = try JSONDecoder().decode(RuntimeFrame.self, from: data)
            let change = frame.params.change
            guard change.revision >= 0 else { throw RuntimeProjectionError.invalid }
            if let previous, previous.owner == header.sourceClientId,
               change.revision <= previous.revision {
                return CodexRuntimeStatusResult(sessionID: sessionID)
            }
            var metadata: RuntimeMetadata
            switch change.type {
            case "snapshot":
                guard let snapshot = change.snapshot,
                      snapshot["id"].string == sessionID,
                      states.count < 128 || previous != nil
                else { throw RuntimeProjectionError.invalid }
                metadata = snapshot
            case "patches":
                guard let previous, previous.owner == header.sourceClientId,
                      change.baseRevision == previous.revision,
                      let patches = change.patches
                else { throw RuntimeProjectionError.invalid }
                metadata = previous.metadata
                for patch in patches where patch.shape != nil {
                    try metadata.apply(patch, path: patch.path[...])
                }
            default:
                throw RuntimeProjectionError.invalid
            }
            guard metadata["id"].string == sessionID,
                  metadata["source"].string == "vscode"
            else {
                reset(sessionID: sessionID)
                return CodexRuntimeStatusResult(sessionID: sessionID, invalidatedSessionID: sessionID)
            }
            awaitingSnapshots.remove(sessionID)
            let update = projectedUpdate(metadata, sessionID: sessionID)
            states[sessionID] = State(
                revision: change.revision, owner: header.sourceClientId,
                metadata: metadata, update: update
            )
            return CodexRuntimeStatusResult(
                sessionID: sessionID,
                update: update == previous?.update ? nil : update,
                invalidatedSessionID: update == nil && previous?.update != nil ? sessionID : nil
            )
        } catch {
            states.removeValue(forKey: sessionID)
            let shouldRequestSnapshot = header.params.changeType == "patches"
                && awaitingSnapshots.count < 128
                && !awaitingSnapshots.contains(sessionID)
            if awaitingSnapshots.count < 128 { awaitingSnapshots.insert(sessionID) }
            return CodexRuntimeStatusResult(
                sessionID: sessionID,
                resnapshotSessionID: shouldRequestSnapshot ? sessionID : nil,
                invalidatedSessionID: sessionID
            )
        }
    }

    private func projectedUpdate(
        _ metadata: RuntimeMetadata, sessionID: String
    ) -> CodexRuntimeStatusUpdate? {
        let runtime = metadata["threadRuntimeStatus"]
        guard let type = runtime["type"].string, type == "active" || type == "idle" else { return nil }
        let flags = runtime["activeFlags"].array?.compactMap(\.string)
        guard type != "active" || flags != nil else { return nil }
        guard let requests = metadata["requests"].array else { return nil }
        let needsAttention = flags?.contains("waitingOnApproval") == true
            || flags?.contains("waitingOnUserInput") == true
            || requests.contains { Self.interactiveMethods.contains($0["method"].string ?? "") }
        let status: CodexTaskStatus = needsAttention ? .needsAttention : type == "active" ? .running : .ready
        let history = metadata["turnHistory"]
        let turnID: String?
        if history["kind"].string == "canonical" {
            let canonical = history["history"]
            guard let islands = canonical["islands"].array,
                  let latest = islands.last,
                  latest["newerBoundary"]["status"].string == "exhausted"
            else { return nil }
            turnID = islands.reversed().lazy.flatMap { ($0["entries"].array ?? []).reversed() }
                .compactMap { entry in
                    entry["value"].string.flatMap { canonical["entitiesByKey"][$0]["turnId"].string }
                }.first
        } else {
            turnID = metadata["turns"].array?.reversed().compactMap { $0["turnId"].string }.first
        }
        guard let turnID, validRuntimeIdentifier(turnID),
              let rawCWD = metadata["cwd"].string,
              let cwd = PathNormalizer.normalize(rawCWD)
        else { return nil }
        return CodexRuntimeStatusUpdate(sessionID: sessionID, turnID: turnID, cwd: cwd, status: status)
    }

    private static let interactiveMethods: Set<String> = [
        "item/commandExecution/requestApproval", "item/fileChange/requestApproval",
        "item/permissions/requestApproval", "item/tool/requestUserInput",
        "item/tool/requestOptionPicker", "mcpServer/elicitation/request"
    ]
}

func validRuntimeIdentifier(_ value: String) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512
}

enum RuntimeProjectionError: Error { case invalid, limit }

struct RuntimeHeader: Decodable {
    let type: String
    let method: String
    let version: Int
    let sourceClientId: String
    let params: Parameters
    struct Parameters: Decodable {
        let conversationId: String
        let hostId: String
        let changeType: String?
        private enum CodingKeys: String, CodingKey { case conversationId, hostId, change }
        private struct Change: Decodable { let type: String }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            conversationId = try values.decode(String.self, forKey: .conversationId)
            hostId = try values.decode(String.self, forKey: .hostId)
            changeType = (try? values.decode(Change.self, forKey: .change))?.type
        }
    }
}

struct RuntimeFrame: Decodable {
    let params: Parameters
    struct Parameters: Decodable { let change: RuntimeChange }
}

struct RuntimeChange: Decodable {
    let type: String
    let revision: Int
    let baseRevision: Int?
    let snapshot: RuntimeMetadata?
    let patches: [RuntimePatch]?
    private enum CodingKeys: String, CodingKey { case type, revision, baseRevision, conversationState, patches }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        revision = try values.decode(Int.self, forKey: .revision)
        baseRevision = try values.decodeIfPresent(Int.self, forKey: .baseRevision)
        snapshot = type == "snapshot"
            ? try RuntimeMetadata.decode(values.superDecoder(forKey: .conversationState), shape: RuntimeShape.root(decoder))
            : nil
        patches = type == "patches" ? try values.decode([RuntimePatch].self, forKey: .patches) : nil
        guard patches?.count ?? 0 <= 10_000 else { throw RuntimeProjectionError.invalid }
    }
}

enum RuntimePath: Decodable, Sendable {
    case key(String)
    case index(Int)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let index = try? value.decode(Int.self), index >= 0 { self = .index(index) }
        else { self = .key(try value.decode(String.self)) }
    }
}

struct RuntimePatch: Decodable {
    let op: String
    let path: [RuntimePath]
    let shape: RuntimeShape?
    let value: RuntimeMetadata?
    private enum CodingKeys: String, CodingKey { case op, path, value }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        op = try values.decode(String.self, forKey: .op)
        path = try values.decode([RuntimePath].self, forKey: .path)
        guard path.count <= 128 else { throw RuntimeProjectionError.invalid }
        shape = path.reduce(Optional(RuntimeShape.root(decoder))) { $0?.child($1) }
        if let shape, op != "remove" {
            value = try RuntimeMetadata.decode(values.superDecoder(forKey: .value), shape: shape)
        } else { value = nil }
    }
}

/// This whitelist applies equally to full snapshots and patch values.
indirect enum RuntimeShape {
    case conversation, status, request, turn, turnHistory, history, island, entry, boundary
    case string, array(RuntimeShape), entities
    case knowledgeConversation, knowledgeTurn, knowledgeTurnHistory, knowledgeHistory, knowledgeEntities
    case knowledgeItem, fileChange, fileKind, pagination, result, bool, presence, diff

    static func root(_ decoder: Decoder) -> RuntimeShape {
        decoder.userInfo[RuntimeProjectionBudget.userInfoKey] == nil ? .conversation : .knowledgeConversation
    }

    func child(_ path: RuntimePath) -> RuntimeShape? {
        if case let .array(element) = self, case .index = path { return element }
        guard case let .key(key) = path else { return nil }
        switch self {
        case .conversation:
            switch key {
            case "id", "sessionId", "cwd", "source": return .string
            case "threadRuntimeStatus": return .status
            case "requests": return .array(.request)
            case "turns": return .array(.turn)
            case "turnHistory": return .turnHistory
            default: return nil
            }
        case .status: return key == "type" ? .string : key == "activeFlags" ? .array(.string) : nil
        case .request: return key == "method" ? .string : nil
        case .turn: return key == "turnId" ? .string : nil
        case .turnHistory: return key == "kind" ? .string : key == "history" ? .history : nil
        case .history: return key == "islands" ? .array(.island) : key == "entitiesByKey" ? .entities : nil
        case .island: return key == "entries" ? .array(.entry) : key == "newerBoundary" ? .boundary : nil
        case .entry: return key == "value" ? .string : nil
        case .boundary: return key == "status" ? .string : nil
        case .entities: return validRuntimeIdentifier(key) ? .turn : nil
        case .knowledgeConversation:
            switch key {
            case "id", "sessionId", "cwd", "source", "resumeState": return .string
            case "turns": return .array(.knowledgeTurn)
            case "turnHistory": return .knowledgeTurnHistory
            case "turnsPagination": return .pagination
            default: return nil
            }
        case .knowledgeTurn:
            switch key {
            case "turnId": return .string
            case "items": return .array(.knowledgeItem)
            case "itemsPagination": return .pagination
            default: return nil
            }
        case .knowledgeTurnHistory: return key == "kind" ? .string : key == "history" ? .knowledgeHistory : nil
        case .knowledgeHistory:
            switch key {
            case "islands": return .array(.island)
            case "entitiesByKey": return .knowledgeEntities
            case "isComplete": return .bool
            default: return nil
            }
        case .knowledgeEntities: return validRuntimeIdentifier(key) ? .knowledgeTurn : nil
        case .knowledgeItem:
            switch key {
            case "id", "type", "status": return .string
            case "changes": return .array(.fileChange)
            case "success", "isError": return .bool
            case "error": return .presence
            case "result": return .result
            default: return nil
            }
        case .fileChange:
            switch key {
            case "path": return .string
            case "kind": return .fileKind
            case "diff": return .diff
            default: return nil
            }
        case .fileKind: return key == "type" || key == "move_path" ? .string : nil
        case .pagination: return key == "hasLoadedOldest" ? .bool : key == "source" ? .string : nil
        case .result: return key == "isError" ? .bool : nil
        case .string, .array, .bool, .presence, .diff: return nil
        }
    }
}

/// A decoding budget is opt-in; the original runtime projection keeps its existing whitelist and limits.
/// Created for one synchronous decoder invocation and never shared across workers.
final class RuntimeProjectionBudget: @unchecked Sendable {
    static let userInfoKey = CodingUserInfoKey(rawValue: "CodexBarKnowledgeProjectionBudget")!
    private var remaining: Int
    var truncated = false

    init(limit: Int) { remaining = limit }

    func reserve(_ bytes: Int) throws {
        guard bytes <= remaining else { throw RuntimeProjectionError.limit }
        remaining -= bytes
    }
}

indirect enum RuntimeMetadata: Sendable {
    case null
    case string(String)
    case bool(Bool)
    case fileDiff(text: String?, fingerprint: String)
    case array([RuntimeMetadata])
    case object([String: RuntimeMetadata])

    var string: String? { if case let .string(value) = self { return value }; return nil }
    var array: [RuntimeMetadata]? { if case let .array(value) = self { return value }; return nil }
    var bool: Bool? { if case let .bool(value) = self { return value }; return nil }
    var object: [String: RuntimeMetadata]? { if case let .object(value) = self { return value }; return nil }
    var diffText: String? { if case let .fileDiff(text, _) = self { return text }; return nil }
    var diffFingerprint: String? { if case let .fileDiff(_, fingerprint) = self { return fingerprint }; return nil }
    var estimatedSize: Int {
        switch self {
        case .null, .bool: return 32
        case let .string(value): return 32 + value.utf8.count
        case let .fileDiff(text, fingerprint): return 64 + (text?.utf8.count ?? 0) + fingerprint.utf8.count
        case let .array(values): return 32 + values.reduce(0) { $0 + $1.estimatedSize }
        case let .object(values): return 32 + values.reduce(0) { $0 + 32 + $1.key.utf8.count + $1.value.estimatedSize }
        }
    }
    subscript(_ key: String) -> RuntimeMetadata {
        if case let .object(values) = self { return values[key] ?? .null }; return .null
    }

    static func decode(_ decoder: Decoder, shape: RuntimeShape) throws -> RuntimeMetadata {
        let budget = decoder.userInfo[RuntimeProjectionBudget.userInfoKey] as? RuntimeProjectionBudget
        try budget?.reserve(32)
        if try decoder.singleValueContainer().decodeNil() { return .null }
        switch shape {
        case .presence: return .bool(true)
        case .bool:
            return (try? decoder.singleValueContainer().decode(Bool.self)).map(RuntimeMetadata.bool) ?? .null
        case .diff:
            guard let text = try? decoder.singleValueContainer().decode(String.self) else { return .null }
            let fingerprint = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            try budget?.reserve(32 + fingerprint.utf8.count)
            guard text.utf8.count <= CodexKnowledgeChangesReducer.maximumDiffBytes else {
                budget?.truncated = true
                return .fileDiff(text: nil, fingerprint: fingerprint)
            }
            try budget?.reserve(text.utf8.count)
            return .fileDiff(text: text, fingerprint: fingerprint)
        case .string:
            guard let text = try? decoder.singleValueContainer().decode(String.self) else { return .null }
            guard text.utf8.count <= 4_096 else { throw RuntimeProjectionError.invalid }
            try budget?.reserve(text.utf8.count)
            return .string(text)
        case let .array(element):
            var values = try decoder.unkeyedContainer()
            var result: [RuntimeMetadata] = []
            while !values.isAtEnd {
                guard result.count < 10_000 else { throw RuntimeProjectionError.invalid }
                result.append(try decode(values.superDecoder(), shape: element))
            }
            return .array(result)
        default:
            if case .fileKind = shape, let text = try? decoder.singleValueContainer().decode(String.self) {
                guard text.utf8.count <= 4_096 else { throw RuntimeProjectionError.invalid }
                try budget?.reserve(text.utf8.count)
                return .string(text)
            }
            let values = try decoder.container(keyedBy: RuntimeKey.self)
            guard values.allKeys.count <= 10_000 else { throw RuntimeProjectionError.invalid }
            var result: [String: RuntimeMetadata] = [:]
            for key in values.allKeys {
                guard let child = shape.child(.key(key.stringValue)) else { continue }
                if case .knowledgeItem = shape,
                   !["id", "type", "status"].contains(key.stringValue),
                   let typeKey = RuntimeKey(stringValue: "type"),
                   (try? values.decode(String.self, forKey: typeKey)) != "fileChange" { continue }
                try budget?.reserve(32 + key.stringValue.utf8.count)
                result[key.stringValue] = try decode(values.superDecoder(forKey: key), shape: child)
            }
            return .object(result)
        }
    }

    mutating func apply(_ patch: RuntimePatch, path: ArraySlice<RuntimePath>) throws {
        guard let head = path.first else {
            guard patch.op == "add" || patch.op == "replace", let value = patch.value else {
                throw RuntimeProjectionError.invalid
            }
            self = value
            return
        }
        let tail = path.dropFirst()
        switch (self, head) {
        case (.object(var values), .key(let key)):
            if tail.isEmpty && patch.op == "remove" { values.removeValue(forKey: key) }
            else {
                var child = values[key] ?? .null
                try child.apply(patch, path: tail)
                values[key] = child
            }
            guard values.count <= 10_000 else { throw RuntimeProjectionError.invalid }
            self = .object(values)
        case (.array(var values), .index(let index)):
            if tail.isEmpty && patch.op == "add", let value = patch.value, index <= values.count {
                values.insert(value, at: index)
            } else {
                guard values.indices.contains(index) else { throw RuntimeProjectionError.invalid }
                if tail.isEmpty && patch.op == "remove" { values.remove(at: index) }
                else { try values[index].apply(patch, path: tail) }
            }
            guard values.count <= 10_000 else { throw RuntimeProjectionError.invalid }
            self = .array(values)
        default: throw RuntimeProjectionError.invalid
        }
    }
}

private struct RuntimeKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
