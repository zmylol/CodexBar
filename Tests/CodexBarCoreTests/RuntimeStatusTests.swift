import Foundation
import CodexBarCore

func runtimeStatusTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "runtime routing preserves session identity without a status change") {
            var reducer = CodexRuntimeStatusReducer()
            let snapshot = try runtimeSnapshot()
            try expect(reducer.consume(snapshot).sessionID == "session-A", "snapshot lost its routing identity")
            let repeated = reducer.consume(snapshot)
            try expect(repeated.update == nil, "same revision unexpectedly changed status")
            try expect(repeated.sessionID == "session-A", "same revision snapshot cannot refresh conversation output")
            let contentOnly = reducer.consume(try runtimePatches([
                ["op": "replace", "path": ["turns", 0, "items"], "value": [["text": "new text"]]]
            ]))
            try expect(contentOnly.update == nil, "body text changed task status")
            try expect(contentOnly.sessionID == "session-A", "body-only patch lost its routing identity")
            try expect(reducer.consume(try runtimeSnapshot(session: "session-B")).sessionID == "session-B",
                       "another conversation would be parsed as the selected preview")
        },
        CodexBarTestCase(name: "runtime routing excludes invalid or remote envelopes") {
            var reducer = CodexRuntimeStatusReducer()
            try expect(reducer.consume(Data("invalid".utf8)).sessionID == nil, "invalid data gained an identity")
            try expect(reducer.consume(try runtimeSnapshot(host: "remote")).sessionID == nil,
                       "remote conversation gained a local routing identity")
        },
        CodexBarTestCase(name: "projects live approval resolution without waiting for tool completion") {
            var reducer = CodexRuntimeStatusReducer()
            let waiting = reducer.consume(try runtimeSnapshot(flags: ["waitingOnApproval"]))
            try expect(waiting.update?.status == .needsAttention, "approval was not projected")
            let running = reducer.consume(try runtimePatches([
                ["op": "replace", "path": ["threadRuntimeStatus", "activeFlags"], "value": []]
            ]))
            try expect(running.update?.status == .running, "approval resolution did not immediately resume")
            try expect(running.update?.turnID == "turn-1", "exact turn identity was lost")
            try expect(running.update?.cwd == "/tmp/project-alpha", "workspace identity was lost")
        },
        CodexBarTestCase(name: "retains attention until all interactive requests are removed") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot(requests: [
                ["method": "item/commandExecution/requestApproval", "params": ["command": "PRIVATE"]],
                ["method": "item/tool/requestUserInput", "params": ["questions": ["PRIVATE"]]]
            ]))
            let first = reducer.consume(try runtimePatches([
                ["op": "remove", "path": ["requests", 0]]
            ]))
            try expect(first.update == nil, "one response cleared another pending request")
            let last = reducer.consume(try runtimePatches([
                ["op": "remove", "path": ["requests", 0]]
            ], base: 2, revision: 3))
            try expect(last.update?.status == .running, "last response did not resume")
        },
        CodexBarTestCase(name: "ignores private content and unknown request methods in runtime projection") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot(requests: [["method": "unknown/method", "params": ["secret": "PRIVATE"]]]))
            let update = reducer.consume(try runtimePatches([
                ["op": "replace", "path": ["turns", 0, "items"], "value": [["text": "PRIVATE"]]],
                ["op": "replace", "path": ["title"], "value": "PRIVATE"]
            ]))
            try expect(update.update == nil, "unrelated content produced a state update")
            try expect(!String(reflecting: reducer).contains("PRIVATE"), "projection retained private content")
        },
        CodexBarTestCase(name: "invalidates missing revisions and accepts a replacement runtime snapshot") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot(flags: ["waitingOnApproval"]))
            let gap = reducer.consume(try runtimePatches([], base: 3, revision: 4))
            try expect(gap.resnapshotSessionID == "session-A", "revision gap did not request snapshot")
            try expect(gap.invalidatedSessionID == "session-A", "revision gap retained authority")
            let recovered = reducer.consume(try runtimeSnapshot(revision: 4))
            try expect(recovered.update?.status == .running, "fresh snapshot did not restore projection")
            let stale = reducer.consume(try runtimeSnapshot(flags: ["waitingOnApproval"], revision: 3))
            try expect(stale.update == nil, "stale snapshot regressed status")
        },
        CodexBarTestCase(name: "runtime updates remain separated by session and source") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot())
            let other = reducer.consume(try runtimeSnapshot(session: "session-B", flags: ["waitingOnApproval"]))
            try expect(other.update?.sessionID == "session-B", "second session was not independent")
            try expect(reducer.consume(try runtimePatches([], session: "session-A")).update == nil, "other session changed the first")
            try expect(reducer.consume(try runtimeSnapshot(session: "session-C", source: "cli")).update == nil, "CLI thread was accepted")
            try expect(reducer.consume(try runtimeSnapshot(session: "session-D", version: 12)).update == nil, "unknown stream version was accepted")
            try expect(reducer.consume(try runtimeSnapshot(session: "session-E", host: "remote")).update == nil, "remote thread was accepted")
        },
        CodexBarTestCase(name: "unknown runtime status revokes authority without reporting ready") {
            for type in ["notLoaded", "systemError", "futureStatus"] {
                var reducer = CodexRuntimeStatusReducer()
                _ = reducer.consume(try runtimeSnapshot())
                let result = reducer.consume(try runtimePatches([
                    ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": type]]
                ]))
                try expect(result.update == nil, "unknown status became ready")
                try expect(result.invalidatedSessionID == "session-A", "unknown status retained stale authority")
                try expect(result.resnapshotSessionID == nil, "unknown status would cause a resnapshot loop")
            }
        },
        CodexBarTestCase(name: "idle runtime status waits for interactive requests before reporting ready") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot(type: "idle", requests: [["method": "item/fileChange/requestApproval"]]))
            let result = reducer.consume(try runtimePatches([["op": "replace", "path": ["requests"], "value": []]]))
            try expect(result.update?.status == .ready, "idle did not become ready after request resolved")
        },
        CodexBarTestCase(name: "extracts canonical live turn identity without retaining history content") {
            var reducer = CodexRuntimeStatusReducer()
            let history: [String: Any] = [
                "kind": "canonical", "history": [
                    "islands": [["newerBoundary": ["status": "exhausted"], "entries": [["value": "key-old"], ["value": "key-live"]]]],
                    "entitiesByKey": [
                        "key-old": ["turnId": "turn-old", "items": [["text": "PRIVATE"]]],
                        "key-live": ["turnId": "turn-live", "params": ["input": "PRIVATE"]]
                    ]
                ]
            ]
            let initial = reducer.consume(try runtimeSnapshot(history: history))
            try expect(initial.update?.turnID == "turn-live", "canonical turn identity was not projected")
            let changed = reducer.consume(try runtimePatches([
                ["op": "replace", "path": ["turnHistory", "history", "entitiesByKey", "key-live", "turnId"], "value": "turn-next"]
            ]))
            try expect(changed.update?.turnID == "turn-next", "canonical identity patch was ignored")
            try expect(!String(reflecting: reducer).contains("PRIVATE"), "canonical history content was retained")
        },
        CodexBarTestCase(name: "rejects malformed runtime patches and resets obsolete owner state") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot())
            let invalid = reducer.consume(try runtimePatches([
                ["op": "remove", "path": ["requests", 99]]
            ]))
            try expect(invalid.resnapshotSessionID == "session-A", "bad array index was accepted")
            _ = reducer.consume(try runtimeSnapshot(revision: 3))
            reducer.reset(sessionID: "session-A")
            let missing = reducer.consume(try runtimePatches([], base: 3, revision: 4))
            try expect(missing.resnapshotSessionID == "session-A", "reset left an obsolete patch base")
            let waitingInput = reducer.consume(try runtimeSnapshot(flags: ["waitingOnUserInput"], revision: 4))
            try expect(waitingInput.update?.status == .needsAttention, "user input waiting flag was ignored")
            let incompatible = reducer.consume(try runtimeSnapshot(revision: 5, version: 12))
            try expect(incompatible.invalidatedSessionID == "session-A", "version change retained stale authority")
        },
        CodexBarTestCase(name: "invalidates malformed runtime metadata without retaining the last status") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot())
            let malformed = reducer.consume(try runtimePatches([
                ["op": "replace", "path": ["threadRuntimeStatus"], "value": ["type": "active", "activeFlags": "invalid"]]
            ]))
            try expect(malformed.update == nil, "malformed metadata produced a status")
            try expect(malformed.invalidatedSessionID == "session-A", "malformed metadata retained authority")
            try expect(malformed.resnapshotSessionID == "session-A", "malformed metadata did not request resnapshot")
        },
        CodexBarTestCase(name: "requests one runtime snapshot per gap and does not loop on incompatible snapshots") {
            var reducer = CodexRuntimeStatusReducer()
            _ = reducer.consume(try runtimeSnapshot())
            let firstGap = reducer.consume(try runtimePatches([], base: 3, revision: 4))
            try expect(firstGap.resnapshotSessionID == "session-A", "gap did not request recovery")
            let repeatedGap = reducer.consume(try runtimePatches([], base: 4, revision: 5))
            try expect(repeatedGap.resnapshotSessionID == nil, "patches repeatedly requested snapshots")
            let invalidSnapshot = reducer.consume(try runtimeFrame(session: "session-A", change: [
                "type": "snapshot", "revision": 5, "conversationState": "incompatible"
            ]))
            try expect(invalidSnapshot.invalidatedSessionID == "session-A", "bad snapshot retained authority")
            try expect(invalidSnapshot.resnapshotSessionID == nil, "bad snapshot requested itself again")
            try expect(reducer.consume(try runtimePatches([], base: 5, revision: 6)).resnapshotSessionID == nil,
                       "patch after failed snapshot restarted recovery loop")
            _ = reducer.consume(try runtimeSnapshot(revision: 6))
            try expect(reducer.consume(try runtimePatches([], base: 7, revision: 8)).resnapshotSessionID == "session-A",
                       "a later independent gap could not request recovery")
        }
    ]
}

private func runtimeSnapshot(
    session: String = "session-A", flags: [String] = [], type: String = "active",
    requests: [[String: Any]] = [], revision: Int = 1, source: String = "vscode",
    version: Int = 11, host: String = "local", history: [String: Any]? = nil
) throws -> Data {
    var state: [String: Any] = [
        "id": session, "sessionId": session, "cwd": "/tmp/project-alpha", "source": source,
        "threadRuntimeStatus": ["type": type, "activeFlags": flags], "requests": requests,
        "turns": [["turnId": "turn-1", "items": [["text": "PRIVATE"]]]]
    ]
    if let history { state["turnHistory"] = history }
    return try runtimeFrame(session: session, version: version, host: host, change: [
        "type": "snapshot", "revision": revision, "conversationState": state
    ])
}

private func runtimePatches(
    _ patches: [[String: Any]], session: String = "session-A", base: Int = 1, revision: Int = 2
) throws -> Data {
    try runtimeFrame(session: session, change: [
        "type": "patches", "baseRevision": base, "revision": revision, "patches": patches
    ])
}

private func runtimeFrame(
    session: String, version: Int = 11, host: String = "local", change: [String: Any]
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "broadcast", "method": "thread-stream-state-changed", "version": version,
        "sourceClientId": "owner", "params": ["conversationId": session, "hostId": host, "change": change]
    ])
}
