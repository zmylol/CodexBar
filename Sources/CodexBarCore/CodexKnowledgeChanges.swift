import Foundation

public struct CodexRecordedFileChange: Identifiable, Equatable, Sendable {
    public let id: String
    public let turnID: String
    public let itemID: String
    public let path: String
    public let kind: String
    public let movePath: String?
    public let diff: String?
    public let status: String
    /// Content identity remains available when a large diff body is omitted.
    public let diffFingerprint: String?

    public init(id: String, turnID: String, itemID: String, path: String, kind: String,
                movePath: String?, diff: String?, status: String, diffFingerprint: String? = nil) {
        self.id = id
        self.turnID = turnID
        self.itemID = itemID
        self.path = path
        self.kind = kind
        self.movePath = movePath
        self.diff = diff
        self.status = status
        self.diffFingerprint = diffFingerprint
    }
}

public struct CodexKnowledgeChangesSnapshot: Equatable, Sendable {
    public let sessionID: String
    public let cwd: String
    public let changes: [CodexRecordedFileChange]
    public let revision: Int
    public let historyComplete: Bool
    public let isTruncated: Bool

    public init(sessionID: String, cwd: String, changes: [CodexRecordedFileChange], revision: Int,
                historyComplete: Bool, isTruncated: Bool) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.changes = changes
        self.revision = revision
        self.historyComplete = historyComplete
        self.isTruncated = isTruncated
    }
}

public struct CodexKnowledgeChangesResult: Sendable {
    public var snapshot: CodexKnowledgeChangesSnapshot?
    public var resnapshotSessionID: String?
    public var invalidatedSessionID: String?

    public init(snapshot: CodexKnowledgeChangesSnapshot? = nil, resnapshotSessionID: String? = nil,
                invalidatedSessionID: String? = nil) {
        self.snapshot = snapshot
        self.resnapshotSessionID = resnapshotSessionID
        self.invalidatedSessionID = invalidatedSessionID
    }
}

/// Extracts recorded edits for registered vault sessions, independently of runtime task status.
/// Conversation text, tool input/output, and error bodies are excluded at the decoder boundary.
public struct CodexKnowledgeChangesReducer: Sendable {
    public static let maximumDiffBytes = 128 * 1_024
    /// Conservative budget for projected structures and emitted changes across all sessions.
    public static let maximumRetainedBytes = 8 * 1_024 * 1_024

    private struct State: Sendable {
        let cwd: String
        var owner: String?
        var retiredOwners: Set<String> = []
        var revision: Int?
        var metadata: RuntimeMetadata?
        var snapshot: CodexKnowledgeChangesSnapshot?
        var awaitingSnapshot = false
        var exceededLimit = false
        var truncated = false

        var estimatedSize: Int {
            var size = 1_024 + cwd.utf8.count + (owner?.utf8.count ?? 0)
            size += retiredOwners.reduce(0) { $0 + 64 + $1.utf8.count }
            size += metadata?.estimatedSize ?? 0
            for change in snapshot?.changes ?? [] {
                size += 256 + change.id.utf8.count + change.turnID.utf8.count + change.itemID.utf8.count
                size += change.path.utf8.count + change.kind.utf8.count
                size += (change.movePath?.utf8.count ?? 0) + (change.diff?.utf8.count ?? 0)
                size += change.diffFingerprint?.utf8.count ?? 0
            }
            return size
        }
    }

    private var states: [String: State] = [:]

    public init() {}

    /// The caller discovers and validates vaults before registration; raw edit paths are validated separately.
    public mutating func setSessions(_ sessions: [String: String]) {
        var next: [String: State] = [:]
        for sessionID in sessions.keys.sorted().prefix(128) {
            guard validRuntimeIdentifier(sessionID), let rawCWD = sessions[sessionID],
                  rawCWD.utf8.count <= 4_096, let cwd = PathNormalizer.normalize(rawCWD)
            else { continue }
            next[sessionID] = states[sessionID].flatMap { $0.cwd == cwd ? $0 : nil } ?? State(cwd: cwd)
        }
        states = next
    }

    public mutating func reset(sessionID: String) {
        guard let state = states[sessionID] else { return }
        states[sessionID] = State(cwd: state.cwd)
    }

    public mutating func consume(_ data: Data) -> CodexKnowledgeChangesResult {
        guard data.count <= 64 * 1_024 * 1_024,
              let header = try? JSONDecoder().decode(RuntimeHeader.self, from: data),
              header.type == "broadcast", header.method == "thread-stream-state-changed",
              header.params.hostId == "local", validRuntimeIdentifier(header.sourceClientId),
              var state = states[header.params.conversationId], !state.exceededLimit,
              !state.retiredOwners.contains(header.sourceClientId)
        else { return CodexKnowledgeChangesResult() }
        let sessionID = header.params.conversationId
        guard header.version == 11 else {
            return invalidate(sessionID, state: state, requestSnapshot: false)
        }
        let isPatch = header.params.changeType == "patches"
        do {
            if state.owner != header.sourceClientId {
                if let owner = state.owner {
                    guard state.retiredOwners.count < 32 else { throw RuntimeProjectionError.limit }
                    state.retiredOwners.insert(owner)
                }
                state.owner = header.sourceClientId
                state.metadata = nil
                state.snapshot = nil
                state.revision = nil
                state.awaitingSnapshot = false
                state.truncated = false
            }
            let budget = RuntimeProjectionBudget(limit: Self.maximumRetainedBytes)
            let decoder = JSONDecoder()
            decoder.userInfo[RuntimeProjectionBudget.userInfoKey] = budget
            let change = try decoder.decode(RuntimeFrame.self, from: data).params.change
            guard change.revision >= 0 else { throw RuntimeProjectionError.invalid }
            if let revision = state.revision,
               change.revision < revision || (isPatch && change.revision == revision) {
                return CodexKnowledgeChangesResult()
            }
            var metadata: RuntimeMetadata
            switch change.type {
            case "snapshot":
                guard let snapshot = change.snapshot else { throw RuntimeProjectionError.invalid }
                metadata = snapshot
            case "patches":
                guard let existing = state.metadata, change.baseRevision == state.revision,
                      let patches = change.patches else { throw RuntimeProjectionError.invalid }
                if patches.allSatisfy({ $0.shape == nil }) {
                    state.revision = change.revision
                    states[sessionID] = state
                    return CodexKnowledgeChangesResult()
                }
                metadata = existing
                for patch in patches where patch.shape != nil {
                    try metadata.apply(patch, path: patch.path[...])
                }
            default: throw RuntimeProjectionError.invalid
            }
            guard metadata["id"].string == sessionID,
                  metadata["sessionId"].string == nil || metadata["sessionId"].string == sessionID,
                  metadata["source"].string == "vscode", let cwd = metadata["cwd"].string,
                  PathNormalizer.normalize(cwd) == state.cwd
            else { return invalidate(sessionID, state: state, requestSnapshot: false) }
            state.truncated = (isPatch && state.truncated) || budget.truncated
            let snapshot = try project(metadata, sessionID: sessionID, state: state, revision: change.revision)
            state.metadata = metadata
            state.snapshot = snapshot
            state.revision = change.revision
            state.awaitingSnapshot = false
            let total = states.reduce(state.estimatedSize) { size, entry in
                size + (entry.key == sessionID ? 0 : entry.value.estimatedSize)
            }
            guard total <= Self.maximumRetainedBytes else { throw RuntimeProjectionError.limit }
            states[sessionID] = state
            return CodexKnowledgeChangesResult(snapshot: snapshot)
        } catch {
            return invalidate(sessionID, state: state, requestSnapshot: isPatch,
                              limit: error as? RuntimeProjectionError == .limit)
        }
    }

    private mutating func invalidate(_ sessionID: String, state: State, requestSnapshot: Bool,
                                     limit: Bool = false) -> CodexKnowledgeChangesResult {
        var next = state
        next.metadata = nil
        next.snapshot = nil
        next.exceededLimit = limit
        next.awaitingSnapshot = true
        states[sessionID] = next
        let snapshot = limit ? CodexKnowledgeChangesSnapshot(
            sessionID: sessionID, cwd: state.cwd, changes: [], revision: state.revision ?? 0,
            historyComplete: false, isTruncated: true
        ) : nil
        return CodexKnowledgeChangesResult(
            snapshot: snapshot,
            resnapshotSessionID: requestSnapshot && !state.awaitingSnapshot && !limit ? sessionID : nil,
            invalidatedSessionID: sessionID
        )
    }

    private func project(_ metadata: RuntimeMetadata, sessionID: String, state: State,
                         revision: Int) throws -> CodexKnowledgeChangesSnapshot {
        var turns: [RuntimeMetadata] = []
        let canonical = metadata["turnHistory"]["kind"].string == "canonical"
        var complete = metadata["resumeState"].string == "resumed"
            && (metadata["turnsPagination"]["hasLoadedOldest"].bool ?? !canonical)
        if canonical {
            let history = metadata["turnHistory"]["history"]
            guard let islands = history["islands"].array, let entities = history["entitiesByKey"].object
            else { throw RuntimeProjectionError.invalid }
            for island in islands {
                guard let entries = island["entries"].array else { throw RuntimeProjectionError.invalid }
                for entry in entries {
                    guard let key = entry["value"].string, let turn = entities[key]
                    else { throw RuntimeProjectionError.invalid }
                    turns.append(turn)
                }
            }
            complete = complete || (history["isComplete"].bool == true && islands.count == 1)
        }
        turns = knowledgeMergeOrdered(turns, metadata["turns"].array ?? [], identity: "turnId") { old, new in
            var merged = new.object ?? [:]
            merged["items"] = .array(knowledgeMergeOrdered(old["items"].array ?? [], new["items"].array ?? [], identity: "id") {
                Self.isTerminal($0) && Self.isRunning($1) ? $0 : $1
            })
            if old["itemsPagination"]["hasLoadedOldest"].bool == false { merged["itemsPagination"] = old["itemsPagination"] }
            return .object(merged)
        }
        complete = complete && metadata["turnsPagination"]["source"].string != "compact"
            && turns.allSatisfy { $0["itemsPagination"]["hasLoadedOldest"].bool != false }

        var orderedIDs: [String] = []
        var items: [String: (turnID: String, item: RuntimeMetadata)] = [:]
        for turn in turns {
            guard let turnID = turn["turnId"].string, validRuntimeIdentifier(turnID) else {
                complete = false
                continue
            }
            for item in turn["items"].array ?? [] where item["type"].string == "fileChange" {
                guard let itemID = item["id"].string, validRuntimeIdentifier(itemID) else {
                    complete = false
                    continue
                }
                let key = "\(turnID.utf8.count):\(turnID)\(itemID)"
                if let previous = items[key], Self.isTerminal(previous.item), Self.isRunning(item) { continue }
                if items[key] == nil { orderedIDs.append(key) }
                items[key] = (turnID, item)
            }
        }
        let previous = Dictionary(grouping: state.snapshot?.changes ?? []) {
            "\($0.turnID.utf8.count):\($0.turnID)\($0.itemID)"
        }
        var changes: [CodexRecordedFileChange] = []
        for key in orderedIDs {
            guard let (turnID, item) = items[key], let itemID = item["id"].string else { continue }
            if Self.isRunning(item), let completed = previous[key] {
                changes.append(contentsOf: completed)
                continue
            }
            guard item["status"].string == "completed", item["success"].bool != false,
                  item["error"].bool != true, item["isError"].bool != true,
                  item["result"]["isError"].bool != true else { continue }
            guard let files = item["changes"].array else { complete = false; continue }
            for (index, file) in files.enumerated() {
                guard let path = file["path"].string, !path.isEmpty,
                      let kind = file["kind"].string ?? file["kind"]["type"].string else {
                    complete = false
                    continue
                }
                changes.append(CodexRecordedFileChange(
                    id: "\(key.utf8.count):\(key):\(index)", turnID: turnID, itemID: itemID,
                    path: path, kind: kind, movePath: file["kind"]["move_path"].string,
                    diff: file["diff"].diffText, status: "completed", diffFingerprint: file["diff"].diffFingerprint
                ))
            }
        }
        return CodexKnowledgeChangesSnapshot(sessionID: sessionID, cwd: state.cwd, changes: changes,
                                             revision: revision, historyComplete: complete, isTruncated: state.truncated)
    }

    private static func isRunning(_ item: RuntimeMetadata) -> Bool {
        ["inProgress", "in_progress", "running"].contains(item["status"].string ?? "")
    }

    private static func isTerminal(_ item: RuntimeMetadata) -> Bool {
        ["completed", "failed", "declined", "denied", "interrupted", "cancelled"].contains(item["status"].string ?? "")
    }
}

/// Fill live history gaps before the next shared anchor, preserving chronological edit order.
private func knowledgeMergeOrdered(
    _ history: [RuntimeMetadata], _ live: [RuntimeMetadata], identity: String,
    merge: (RuntimeMetadata, RuntimeMetadata) -> RuntimeMetadata
) -> [RuntimeMetadata] {
    let liveByID = Dictionary(live.compactMap { item in item[identity].string.map { ($0, item) } },
                              uniquingKeysWith: { _, new in new })
    let historyIDs = Set(history.compactMap { $0[identity].string })
    var result = history.map { old in
        guard let id = old[identity].string, let new = liveByID[id] else { return old }
        return merge(old, new)
    }
    var pending: [RuntimeMetadata] = []
    for item in live {
        if let id = item[identity].string, historyIDs.contains(id) {
            if !pending.isEmpty, let index = result.firstIndex(where: { $0[identity].string == id }) {
                result.insert(contentsOf: pending, at: index)
                pending.removeAll(keepingCapacity: true)
            }
        } else { pending.append(item) }
    }
    return result + pending
}
