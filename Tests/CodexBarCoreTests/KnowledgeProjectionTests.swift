import Foundation
import CodexBarCore

func knowledgeProjectionTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "knowledge changes only consume registered local VS Code sessions") {
            for overrides: [String: Any] in [
                ["session": "unregistered"], ["cwd": "/tmp/other"], ["source": "cli"],
                ["host": "remote"], ["version": 12], ["sessionId": "another-session"]
            ] {
                var reducer = knowledgeReducer()
                let result = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()], overrides: overrides))
                try expect(result.snapshot == nil, "unrelated file changes were accepted: \(overrides)")
                try expect(result.resnapshotSessionID == nil, "unsupported snapshot requested a retry")
            }
            var reducer = knowledgeReducer()
            reducer.setSessions([:])
            try expect(reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()])).snapshot == nil,
                       "unregistered session remained enabled")
        },
        CodexBarTestCase(name: "knowledge changes preserve paths kinds moves and completed diffs") {
            var reducer = knowledgeReducer()
            let item = knowledgeFile(changes: [
                ["path": "资料 / 项目.md", "kind": ["type": "add"], "diff": "+新笔记"],
                ["path": "Inbox/旧.md", "kind": ["type": "update", "move_path": "Notes/新.md"], "diff": "-old\n+new"],
                ["path": "过期.md", "kind": "delete"]
            ])
            let snapshot = try require(reducer.consume(try knowledgeSnapshot(items: [item])).snapshot, "missing snapshot")
            try expect(snapshot.sessionID == "knowledge-session" && snapshot.cwd == "/tmp/knowledge-vault", "identity lost")
            try expect(snapshot.changes.map(\.path) == ["资料 / 项目.md", "Inbox/旧.md", "过期.md"], "paths altered")
            try expect(snapshot.changes.map(\.kind) == ["add", "update", "delete"], "file kinds lost")
            try expect(snapshot.changes[1].movePath == "Notes/新.md", "move destination lost")
            try expect(snapshot.changes[1].diff == "-old\n+new", "diff altered")
            try expect(snapshot.changes.allSatisfy { $0.turnID == "turn-1" && $0.itemID == "file-1" && $0.status == "completed" }, "item provenance lost")
            try expect(Set(snapshot.changes.map(\.id)).count == 3, "file IDs collide")
            try expect(snapshot.historyComplete && !snapshot.isTruncated, "complete data marked partial")
        },
        CodexBarTestCase(name: "knowledge changes wait for success and preserve running items for status patches") {
            var reducer = knowledgeReducer()
            let initial = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile(status: "inProgress")]))
            try expect(initial.snapshot?.changes.isEmpty == true, "running edit claimed success")
            let result = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "completed"]
            ]))
            try expect(result.snapshot?.changes.first?.path == "Notes/笔记.md", "status-only completion lost original change")
            try expect(result.snapshot?.revision == 2, "revision lost")
        },
        CodexBarTestCase(name: "knowledge changes exclude failed denied cancelled and error-bearing edits") {
            var reducer = knowledgeReducer()
            var items = ["failed", "declined", "cancelled", "inProgress"].enumerated().map { index, status in
                knowledgeFile(id: "status-\(index)", status: status)
            }
            for (index, extra): (Int, [String: Any]) in [
                ["success": false], ["error": "failed"], ["error": ["message": "failed"]],
                ["isError": true], ["result": ["isError": true, "content": "PRIVATE_ERROR_BODY"]]
            ].enumerated() {
                var item = knowledgeFile(id: "error-\(index)")
                item.merge(extra) { _, new in new }
                items.append(item)
            }
            items.append(knowledgeFile(id: "success"))
            let snapshot = try require(reducer.consume(try knowledgeSnapshot(items: items)).snapshot, "missing snapshot")
            try expect(snapshot.changes.map(\.itemID) == ["success"], "unsuccessful edits entered the review list")
        },
        CodexBarTestCase(name: "knowledge changes merge canonical live records without duplicate or terminal rollback") {
            var reducer = knowledgeReducer()
            let canonical: [String: Any] = ["turnId": "shared", "items": [knowledgeFile()]]
            let live: [String: Any] = ["turnId": "shared", "items": [knowledgeFile(status: "inProgress")]]
            let snapshot = try require(reducer.consume(try knowledgeSnapshot(items: [], extra: [
                "turnHistory": ["kind": "canonical", "history": ["isComplete": true,
                    "islands": [["entries": [["value": "turn-key"]]]], "entitiesByKey": ["turn-key": canonical]]],
                "turns": [live]
            ])).snapshot, "missing canonical changes")
            try expect(snapshot.changes.count == 1 && snapshot.changes[0].status == "completed", "stale live item regressed canonical completion")
            let repeated = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "completed"]
            ]))
            try expect(repeated.snapshot?.changes == snapshot.changes, "canonical and live file duplicated")
        },
        CodexBarTestCase(name: "knowledge changes preserve completion across later stale live revisions") {
            var reducer = knowledgeReducer()
            let initial = try require(reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()])).snapshot, "missing initial")
            let stale = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "status"], "value": "inProgress"]
            ]))
            try expect(stale.snapshot?.changes == initial.changes, "completed edit regressed to running")
        },
        CodexBarTestCase(name: "knowledge changes preserve canonical anchors when live history fills gaps") {
            for crossTurn in [false, true] {
                var reducer = knowledgeReducer()
                func turn(_ id: String, items: [[String: Any]]) -> [String: Any] { ["turnId": id, "items": items] }
                let first = knowledgeFile(id: "f1")
                let middle = knowledgeFile(id: "f2")
                let last = knowledgeFile(id: "f3")
                let canonical = crossTurn
                    ? [turn("t1", items: [first]), turn("t3", items: [last])]
                    : [turn("shared", items: [first, last])]
                let live = crossTurn
                    ? [turn("t1", items: [first]), turn("t2", items: [middle]), turn("t3", items: [last])]
                    : [turn("shared", items: [first, middle, last])]
                let keys = canonical.indices.map { "key-\($0)" }
                let snapshot = reducer.consume(try knowledgeSnapshot(items: [], extra: [
                    "turnHistory": ["kind": "canonical", "history": ["isComplete": true,
                        "islands": [["entries": keys.map { ["value": $0] }]],
                        "entitiesByKey": Dictionary(uniqueKeysWithValues: zip(keys, canonical))]],
                    "turns": live
                ])).snapshot
                try expect(snapshot?.changes.map(\.itemID) == ["f1", "f2", "f3"], "live gap filling reordered edits")
            }
        },
        CodexBarTestCase(name: "knowledge changes mark partial history and missing canonical entities") {
            for extra: [String: Any] in [
                ["resumeState": "needs_resume"], ["turnsPagination": ["hasLoadedOldest": false]],
                ["turnsPagination": ["hasLoadedOldest": true, "source": "compact"]],
                ["turns": [["turnId": "turn-1", "items": [knowledgeFile()], "itemsPagination": ["hasLoadedOldest": false]]]]
            ] {
                var reducer = knowledgeReducer()
                try expect(reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()], extra: extra)).snapshot?.historyComplete == false,
                           "partial history claimed complete")
            }
        },
        CodexBarTestCase(name: "knowledge changes ignore message bodies and unrelated output patches") {
            var reducer = knowledgeReducer()
            let largeBody = String(repeating: "PRIVATE_BODY", count: 900_000)
            let result = reducer.consume(try knowledgeSnapshot(items: [
                ["id": "message", "type": "agentMessage", "text": largeBody],
                ["id": "command", "type": "commandExecution", "aggregatedOutput": largeBody],
                knowledgeFile()
            ]))
            try expect(result.snapshot?.changes.count == 1 && result.snapshot?.isTruncated == false,
                       "conversation content consumed file-change budget")
            let patched = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": ["unexpected": largeBody]]
            ]))
            try expect(patched.snapshot == nil && patched.invalidatedSessionID == nil, "ignored message patch republished file changes")
            let completed = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 2, "changes", 0, "diff"], "value": "+latest"]
            ], base: 2, revision: 3))
            try expect(completed.snapshot?.changes.first?.diff == "+latest", "ignored patch did not advance stream revision")
        },
        CodexBarTestCase(name: "knowledge changes invalidate gaps atomically and request one recovery snapshot") {
            var reducer = knowledgeReducer()
            _ = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()]))
            let gap = reducer.consume(try knowledgePatches([], base: 7, revision: 8))
            try expect(gap.snapshot == nil && gap.invalidatedSessionID == "knowledge-session" && gap.resnapshotSessionID == "knowledge-session", "gap did not invalidate")
            try expect(reducer.consume(try knowledgePatches([], base: 8, revision: 9)).resnapshotSessionID == nil, "recovery loop")
            try expect(reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()], revision: 10)).snapshot?.changes.count == 1, "snapshot recovery failed")
        },
        CodexBarTestCase(name: "knowledge changes ignore duplicate revisions and retired owners") {
            var reducer = knowledgeReducer()
            _ = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()]))
            _ = reducer.consume(try knowledgePatches([], owner: "new-owner"))
            let fresh = reducer.consume(try knowledgeSnapshot(items: [], revision: 0, owner: "new-owner"))
            try expect(fresh.snapshot?.changes.isEmpty == true, "new owner could not restart")
            try expect(reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()], revision: 99)).snapshot == nil, "retired owner restored stale content")
            _ = reducer.consume(try knowledgePatches([], base: 0, revision: 1, owner: "new-owner"))
            try expect(reducer.consume(try knowledgePatches([], base: 0, revision: 1, owner: "new-owner")).snapshot == nil, "duplicate patch republished")
        },
        CodexBarTestCase(name: "knowledge changes bound individual diffs and clearly report omitted content") {
            var reducer = knowledgeReducer()
            let hugeDiff = String(repeating: "x", count: CodexKnowledgeChangesReducer.maximumDiffBytes + 1)
            let result = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile(changes: [
                ["path": "Notes/large.md", "kind": "update", "diff": hugeDiff]
            ])]))
            try expect(result.snapshot?.changes.first?.path == "Notes/large.md" && result.snapshot?.changes.first?.diff == nil,
                       "large diff lost path or bypassed bound")
            try expect(result.snapshot?.isTruncated == true && result.resnapshotSessionID == nil, "omitted diff not disclosed")
            let fingerprint = result.snapshot?.changes.first?.diffFingerprint
            try expect(fingerprint?.count == 64, "omitted diff lost its content identity")
            let updated = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "changes", 0, "diff"], "value": hugeDiff + "changed"]
            ]))
            try expect(updated.snapshot?.changes.first?.diffFingerprint != fingerprint,
                       "a changed omitted diff retained the same review identity")
        },
        CodexBarTestCase(name: "knowledge changes stop total-budget overflow without snapshot retry loops") {
            var reducer = knowledgeReducer()
            let diff = String(repeating: "x", count: CodexKnowledgeChangesReducer.maximumDiffBytes)
            let count = CodexKnowledgeChangesReducer.maximumRetainedBytes / diff.utf8.count + 1
            let changes = (0..<count).map { ["path": "Notes/\($0).md", "kind": "update", "diff": diff] }
            let result = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile(changes: changes)]))
            try expect(result.snapshot?.isTruncated == true && result.snapshot?.historyComplete == false, "total budget overflow was silent")
            try expect(result.resnapshotSessionID == nil, "overflow requested another oversized snapshot")
            try expect(reducer.consume(try knowledgePatches([], base: 1, revision: 2)).resnapshotSessionID == nil, "overflow retry loop")
            reducer.reset(sessionID: "knowledge-session")
            try expect(reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()])).snapshot?.isTruncated == false, "reset failed to restore collection")
        },
        CodexBarTestCase(name: "knowledge changes reject malformed patch transactions and allow same revision refresh") {
            var reducer = knowledgeReducer()
            _ = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile()]))
            let changed = knowledgeFile(changes: [["path": "Notes/changed.md", "kind": "add", "diff": "+new"]])
            try expect(reducer.consume(try knowledgeSnapshot(items: [changed])).snapshot?.changes.first?.path == "Notes/changed.md",
                       "fresh same revision snapshot was ignored")
            let invalid = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "changes", 0, "diff"], "value": "PARTIAL"],
                ["op": "remove", "path": ["turns", 0, "items", 99]]
            ]))
            try expect(invalid.snapshot == nil && invalid.resnapshotSessionID == "knowledge-session", "partial malformed transaction was published")
        },
        CodexBarTestCase(name: "knowledge changes apply the memory budget across sessions") {
            var reducer = knowledgeReducer()
            reducer.setSessions(["knowledge-session": "/tmp/knowledge-vault", "other-session": "/tmp/other-vault"])
            let diff = String(repeating: "x", count: CodexKnowledgeChangesReducer.maximumDiffBytes)
            let changes = (0..<20).map { ["path": "Notes/\($0).md", "kind": "update", "diff": diff] }
            let first = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile(changes: changes)]))
            try expect(first.snapshot?.isTruncated == false, "individual session did not fit the budget")
            let second = reducer.consume(try knowledgeSnapshot(items: [knowledgeFile(changes: changes)], overrides: [
                "session": "other-session", "cwd": "/tmp/other-vault"
            ]))
            try expect(second.snapshot?.isTruncated == true, "sessions each consumed a separate unlimited budget")
            let original = reducer.consume(try knowledgePatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "changes", 0, "diff"], "value": "+fresh"]
            ]))
            try expect(original.snapshot?.changes.first?.diff == "+fresh", "overflow in another session invalidated healthy data")
        }
    ]
}

private func knowledgeReducer() -> CodexKnowledgeChangesReducer {
    var reducer = CodexKnowledgeChangesReducer()
    reducer.setSessions(["knowledge-session": "/tmp/knowledge-vault"])
    return reducer
}

private func knowledgeFile(id: String = "file-1", status: String = "completed", changes: [[String: Any]]? = nil) -> [String: Any] {
    ["id": id, "type": "fileChange", "status": status, "changes": changes ?? [
        ["path": "Notes/笔记.md", "kind": ["type": "update"], "diff": "-before\n+after"]
    ]]
}

private func knowledgeSnapshot(
    items: [[String: Any]], revision: Int = 1, owner: String = "owner", overrides: [String: Any] = [:], extra: [String: Any] = [:]
) throws -> Data {
    let session = overrides["session"] as? String ?? "knowledge-session"
    var state: [String: Any] = [
        "id": session, "sessionId": overrides["sessionId"] ?? session,
        "cwd": overrides["cwd"] ?? "/tmp/knowledge-vault", "source": overrides["source"] ?? "vscode",
        "resumeState": "resumed", "turnsPagination": ["hasLoadedOldest": true],
        "turns": [["turnId": "turn-1", "items": items]]
    ]
    state.merge(extra) { _, new in new }
    return try knowledgeFrame(change: ["type": "snapshot", "revision": revision, "conversationState": state],
                              owner: owner, session: session, host: overrides["host"] as? String ?? "local", version: overrides["version"] as? Int ?? 11)
}

private func knowledgePatches(_ patches: [[String: Any]], base: Int = 1, revision: Int = 2, owner: String = "owner") throws -> Data {
    try knowledgeFrame(change: ["type": "patches", "baseRevision": base, "revision": revision, "patches": patches], owner: owner)
}

private func knowledgeFrame(change: [String: Any], owner: String, session: String = "knowledge-session", host: String = "local", version: Int = 11) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "broadcast", "method": "thread-stream-state-changed", "version": version, "sourceClientId": owner,
        "params": ["conversationId": session, "hostId": host, "change": change]
    ])
}
