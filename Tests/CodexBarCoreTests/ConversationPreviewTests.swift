import Foundation
import CodexBarCore

func conversationPreviewTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "conversation preview separates user input from assistant and command results") {
            var reducer = previewReducer()
            let items: [[String: Any]] = [
                ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "检查构建"]]],
                ["id": "a", "type": "agentMessage", "text": "正在构建。"],
                ["id": "c", "type": "commandExecution", "command": "printf INPUT", "aggregatedOutput": "OUT\nERR", "status": "failed", "exitCode": 7]
            ]
            let preview = try require(reducer.consume(try previewSnapshot(items: items)).preview, "missing preview")
            try expect(preview.items.map(\.kind) == [.user, .assistant, .tool], "roles were confused")
            try expect(preview.items[0].text == "检查构建", "user text was lost")
            try expect(preview.items[2].text == "OUT\nERR", "command input was presented as output")
            try expect(preview.items[2].detail == "printf INPUT", "command context was lost")
            try expect(preview.items[2].isError && !preview.items[2].isRunning, "failed command state was lost")
            try expect(preview.items[2].title.contains("7"), "exit code was lost")
        },
        CodexBarTestCase(name: "conversation preview displays steering user input from the protocol input field") {
            var reducer = previewReducer()
            let preview = try require(reducer.consume(try previewSnapshot(items: [
                ["id": "steering", "type": "steeringUserMessage", "input": [["type": "inputText", "text": "先修复登录"]]]
            ])).preview, "missing steering preview")
            try expect(preview.items.first?.kind == .user && preview.items.first?.text == "先修复登录", "steering message body was lost")
        },
        CodexBarTestCase(name: "conversation preview applies text add replace and remove patches in order") {
            var reducer = previewReducer()
            _ = reducer.consume(try previewSnapshot(items: [["id": "a", "type": "agentMessage", "text": "开始"]]))
            let changed = reducer.consume(try previewPatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "开始检查\n完整正文"],
                ["op": "add", "path": ["turns", 0, "items", 1], "value": ["id": "b", "type": "agentMessage", "text": "完成"]]
            ]))
            try expect(changed.preview?.items.map(\.text) == ["开始检查\n完整正文", "完成"], "text patches were lost")
            let removed = reducer.consume(try previewPatches([
                ["op": "remove", "path": ["turns", 0, "items", 0]]
            ], base: 2, revision: 3))
            try expect(removed.preview?.items.map(\.text) == ["完成"], "removed message remained")
        },
        CodexBarTestCase(name: "conversation preview accepts fresh same revision snapshots and ignores duplicate patches") {
            var reducer = previewReducer()
            _ = reducer.consume(try previewSnapshot(items: [["id": "c", "type": "commandExecution", "aggregatedOutput": "old", "status": "inProgress"]]))
            let fresh = reducer.consume(try previewSnapshot(items: [["id": "c", "type": "commandExecution", "aggregatedOutput": "new", "status": "inProgress"]]))
            try expect(fresh.preview?.items.first?.text == "new", "same revision snapshot was discarded")
            _ = reducer.consume(try previewPatches([["op": "replace", "path": ["turns", 0, "items", 0, "aggregatedOutput"], "value": "latest"]]))
            let duplicate = reducer.consume(try previewPatches([["op": "replace", "path": ["turns", 0, "items", 0, "aggregatedOutput"], "value": "old"]]))
            try expect(duplicate.preview == nil && !duplicate.invalidated, "duplicate patch was replayed")
            try expect(reducer.consume(try previewSnapshot(items: [], revision: 1)).preview == nil, "stale snapshot regressed state")
        },
        CodexBarTestCase(name: "conversation preview requests a single snapshot on gaps and owner changes") {
            var reducer = previewReducer()
            _ = reducer.consume(try previewSnapshot(items: []))
            let gap = reducer.consume(try previewPatches([], base: 4, revision: 5))
            try expect(gap.invalidated && gap.needsSnapshot, "gap retained stale content")
            try expect(!reducer.consume(try previewPatches([], base: 5, revision: 6)).needsSnapshot, "snapshot retry loop")
            _ = reducer.consume(try previewSnapshot(items: [], revision: 6))
            let owner = reducer.consume(try previewPatches([], base: 6, revision: 7, owner: "new-owner"))
            try expect(owner.invalidated && owner.needsSnapshot, "owner change reused old patch base")
            try expect(reducer.consume(try previewSnapshot(items: [], revision: 0, owner: "new-owner")).preview != nil,
                       "new owner snapshot could not restart revision")
        },
        CodexBarTestCase(name: "conversation preview isolates the selected local VS Code session and workspace") {
            for fields: [String: Any] in [
                ["session": "other-session"], ["source": "cli"], ["host": "remote"], ["cwd": "/tmp/other"], ["version": 12]
            ] {
                var reducer = previewReducer()
                let result = reducer.consume(try previewSnapshot(items: [["id": "x", "type": "agentMessage", "text": "OTHER"]], overrides: fields))
                try expect(result.preview == nil, "unrelated session content was accepted: \(fields)")
                try expect(!result.needsSnapshot, "unsupported snapshot restarted recovery")
            }
        },
        CodexBarTestCase(name: "conversation preview preserves canonical island order and merges live turns without duplicates") {
            var reducer = previewReducer()
            let old = previewTurn("old", text: "first")
            let latest = previewTurn("latest", text: "older live text")
            let history: [String: Any] = ["kind": "canonical", "history": [
                "isComplete": true,
                "islands": [["entries": [["value": "z-key"], ["value": "a-key"]]]],
                "entitiesByKey": ["a-key": latest, "z-key": old]
            ]]
            let snapshot = try previewSnapshot(items: [], stateExtra: [
                "turnHistory": history,
                "turns": [previewTurn("latest", text: "live text"), previewTurn("new", text: "last")]
            ])
            let preview = try require(reducer.consume(snapshot).preview, "missing canonical preview")
            try expect(preview.items.map(\.text) == ["first", "live text", "last"], "history was sorted by keys or duplicated")
            try expect(Set(preview.items.map(\.id)).count == 3, "message IDs are not unique")
            try expect(preview.historyComplete, "complete history flags were ignored")
        },
        CodexBarTestCase(name: "conversation preview marks incomplete turn and item history") {
            for extra: [String: Any] in [
                ["turnsPagination": ["hasLoadedOldest": false]],
                ["turnsPagination": ["hasLoadedOldest": true, "source": "compact"]],
                ["turns": [["turnId": "turn-1", "items": [], "itemsPagination": ["hasLoadedOldest": false]]]],
                ["turnHistory": ["kind": "canonical", "history": ["isComplete": false, "islands": [], "entitiesByKey": [:]]], "turnsPagination": ["hasLoadedOldest": false]],
                ["resumeState": "needs_resume"]
            ] {
                var reducer = previewReducer()
                let preview = try require(reducer.consume(try previewSnapshot(items: [], stateExtra: extra)).preview, "missing partial preview")
                try expect(!preview.historyComplete, "partial history was marked complete")
            }
        },
        CodexBarTestCase(name: "conversation preview preserves canonical completed output over stale live tools") {
            var reducer = previewReducer()
            let completed: [String: Any] = ["turnId": "shared", "status": "completed", "items": [
                ["id": "command", "type": "commandExecution", "status": "completed", "exitCode": 0, "aggregatedOutput": "FULL RESULT"]
            ]]
            let live: [String: Any] = ["turnId": "shared", "status": "inProgress", "items": [
                ["id": "command", "type": "commandExecution", "status": "inProgress", "aggregatedOutput": "PARTIAL"]
            ]]
            let preview = try require(reducer.consume(try previewSnapshot(items: [], stateExtra: [
                "turnHistory": ["kind": "canonical", "history": ["isComplete": true,
                    "islands": [["entries": [["value": "shared"]]]], "entitiesByKey": ["shared": completed]]],
                "turns": [live]
            ])).preview, "missing preview")
            try expect(preview.items.first?.text == "FULL RESULT", "stale live turn overwrote complete canonical output")
            try expect(preview.items.first?.isRunning == false, "completed command regressed to running")
        },
        CodexBarTestCase(name: "conversation preview follows canonical and resumed history completeness precedence") {
            for extra: [String: Any] in [
                ["turnHistory": ["kind": "canonical", "history": ["isComplete": true, "islands": [["entries": []]], "entitiesByKey": [:]]],
                 "turnsPagination": ["hasLoadedOldest": false]],
                ["turnHistory": ["kind": "canonical", "history": ["isComplete": false, "islands": [], "entitiesByKey": [:]]]]
            ] {
                var reducer = previewReducer()
                try expect(reducer.consume(try previewSnapshot(items: [], stateExtra: extra)).preview?.historyComplete == true,
                           "owner-complete canonical or resumed history remained incomplete")
            }
        },
        CodexBarTestCase(name: "conversation preview includes turn user input fallback and function call outputs") {
            var reducer = previewReducer()
            let preview = try require(reducer.consume(try previewSnapshot(items: [], stateExtra: [
                "turns": [["turnId": "t", "params": ["input": [["type": "inputText", "text": "原始请求"]]], "items": [
                    ["id": "function-output", "type": "functionCallOutput", "name": "lookup", "output": "RESULT_TEXT"]
                ]]]
            ])).preview, "missing preview")
            try expect(preview.items.map(\.text) == ["原始请求", "RESULT_TEXT"], "original user prompt or tool output was lost")
            try expect(preview.items.map(\.kind) == [.user, .tool], "function output was misclassified")
        },
        CodexBarTestCase(name: "conversation preview includes file diffs search actions and observable collaboration") {
            var reducer = previewReducer()
            let preview = try require(reducer.consume(try previewSnapshot(items: [
                ["id": "f", "type": "fileChange", "status": "completed", "changes": [["path": "Sources/App.swift", "kind": ["type": "update"], "diff": "-old\n+new"]]],
                ["id": "w", "type": "webSearch", "status": "completed", "action": ["type": "search", "query": "official docs", "urls": ["https://example.com/docs"]]],
                ["id": "s", "type": "collabAgentToolCall", "tool": "spawnAgent", "status": "inProgress", "prompt": "INTERNAL_PROMPT"]
            ])).preview, "missing preview")
            try expect(preview.items[0].text.contains("Sources/App.swift") && preview.items[0].text.contains("-old\n+new"), "file diff was dropped")
            try expect(preview.items[1].text.contains("official docs") && preview.items[1].text.contains("https://example.com/docs"), "search action was dropped")
            try expect(preview.items[2].isRunning && !preview.items[2].text.contains("INTERNAL_PROMPT"), "collaboration state exposed prompt")
        },
        CodexBarTestCase(name: "conversation preview renders dynamic and MCP results without inventing tool success") {
            var reducer = previewReducer()
            let items: [[String: Any]] = [
                ["id": "d", "type": "dynamicToolCall", "tool": "lookup", "arguments": ["input": "INPUT_ONLY"], "contentItems": [["type": "inputText", "text": "DYNAMIC_RESULT"]], "status": "completed", "success": false],
                ["id": "m", "type": "mcpToolCall", "server": "local", "tool": "check", "result": ["content": [["type": "text", "text": "MCP_RESULT"]], "structuredContent": ["count": 3], "isError": true], "status": "completed"],
                ["id": "r", "type": "commandExecution", "command": "INPUT_ONLY", "status": "inProgress"]
            ]
            let preview = try require(reducer.consume(try previewSnapshot(items: items)).preview, "missing tools")
            try expect(preview.items[0].text == "DYNAMIC_RESULT" && preview.items[0].isError, "dynamic result or failure missing")
            try expect(preview.items[1].text.contains("MCP_RESULT") && preview.items[1].text.contains("3") && preview.items[1].isError, "MCP result missing")
            try expect(preview.items[2].isRunning && !preview.items[2].text.contains("INPUT_ONLY"), "running tool input was shown as a result")
        },
        CodexBarTestCase(name: "conversation preview never exposes raw reasoning or unknown internal payloads") {
            var reducer = previewReducer()
            let preview = try require(reducer.consume(try previewSnapshot(items: [
                ["id": "r", "type": "reasoning", "summary": ["可展示摘要"], "content": ["RAW_REASONING"]],
                ["id": "x", "type": "futureInternalType", "text": "INTERNAL_SECRET", "payload": ["instructions": "PRIVATE_CONTEXT"]]
            ])).preview, "missing preview")
            let display = preview.items.map { $0.title + $0.text + ($0.detail ?? "") }.joined()
            try expect(display.contains("可展示摘要"), "safe reasoning summary was lost")
            try expect(!display.contains("RAW_REASONING") && !display.contains("INTERNAL_SECRET") && !display.contains("PRIVATE_CONTEXT"), "internal content leaked")
        },
        CodexBarTestCase(name: "conversation preview omits reasoning without a visible summary") {
            var reducer = previewReducer()
            let preview = try require(reducer.consume(try previewSnapshot(items: [
                ["id": "empty", "type": "reasoning", "summary": [], "content": ["RAW_REASONING"]],
                ["id": "blank", "type": "reasoning", "summary": [" \n\t"], "content": ["RAW_REASONING"]],
                ["id": "missing", "type": "reasoning", "content": ["RAW_REASONING"]],
                ["id": "visible", "type": "reasoning", "summary": ["可展示摘要"]]
            ])).preview, "missing preview")
            try expect(preview.items.count == 1 && preview.items.first?.text == "可展示摘要", "empty reasoning placeholders remained")
        },
        CodexBarTestCase(name: "conversation command titles identify the command while preserving full inputs and exit status") {
            var reducer = previewReducer()
            let longLine = "rg " + String(repeating: "长路径", count: 60)
            let commands = ["\n  swift build\nprintf done", longLine + "\nprintf next"]
            let preview = try require(reducer.consume(try previewSnapshot(items: commands.enumerated().map { index, command in
                ["id": "c-\(index)", "type": "commandExecution", "command": command, "status": "completed", "exitCode": 0]
            })).preview, "missing commands")
            try expect(preview.items[0].title.contains("swift build") && !preview.items[0].title.contains("printf done"), "title did not identify first command")
            try expect(preview.items[1].title.hasPrefix(String(longLine.prefix(99)) + "…"), "long command title was not bounded clearly")
            try expect(preview.items.allSatisfy { $0.title.contains("完成") && $0.title.contains("退出码 0") }, "title lost command state")
            try expect(preview.items.map(\.detail) == commands.map(Optional.some), "full command input was truncated")
        },
        CodexBarTestCase(name: "conversation preview preserves long output and invalidates oversized frames without retrying") {
            var reducer = previewReducer()
            let output = String(repeating: "输出\n", count: 10_000)
            let preview = reducer.consume(try previewSnapshot(items: [["id": "long", "type": "commandExecution", "aggregatedOutput": output, "status": "completed", "exitCode": 0]])).preview
            try expect(preview?.items.first?.text == output, "output was silently truncated")
            var oversizedData = try previewSnapshot(items: [])
            oversizedData.append(Data(repeating: 32, count: 32 * 1_024 * 1_024))
            let oversized = reducer.consume(oversizedData)
            try expect(oversized.invalidated && !oversized.needsSnapshot, "oversized frame retained content or retried forever")
            try expect(!reducer.consume(try previewPatches([])).needsSnapshot, "oversize protection allowed a resnapshot loop")
            reducer.reset()
            try expect(reducer.consume(try previewSnapshot(items: [])).preview != nil, "reset failed to recover")
        },
        CodexBarTestCase(name: "conversation preview ignores oversized unrelated session frames") {
            var reducer = previewReducer()
            _ = reducer.consume(try previewSnapshot(items: [["id": "a", "type": "agentMessage", "text": "before"]]))
            var unrelated = try previewSnapshot(items: [], overrides: ["session": "other-session"])
            unrelated.append(Data(repeating: 32, count: 32 * 1_024 * 1_024))
            let result = reducer.consume(unrelated)
            try expect(!result.invalidated, "another session exhausted the selected preview budget")
            let updated = reducer.consume(try previewPatches([["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "after"]]))
            try expect(updated.preview?.items.first?.text == "after", "unrelated oversized frame disabled selected updates")
        },
        CodexBarTestCase(name: "conversation preview rejects malformed patches without publishing partial edits") {
            var reducer = previewReducer()
            _ = reducer.consume(try previewSnapshot(items: [["id": "a", "type": "agentMessage", "text": "before"]]))
            let result = reducer.consume(try previewPatches([
                ["op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "after"],
                ["op": "remove", "path": ["turns", 0, "items", 99]]
            ]))
            try expect(result.preview == nil && result.invalidated && result.needsSnapshot, "partial patch transaction was published")
        }
    ]
}

private func previewReducer() -> CodexConversationPreviewReducer {
    CodexConversationPreviewReducer(sessionID: "session-preview", cwd: "/tmp/preview-project")
}

private func previewTurn(_ id: String, text: String) -> [String: Any] {
    ["turnId": id, "items": [["id": "\(id)-message", "type": "agentMessage", "text": text]]]
}

private func previewSnapshot(
    items: [[String: Any]], revision: Int = 1, owner: String = "owner", overrides: [String: Any] = [:], stateExtra: [String: Any] = [:]
) throws -> Data {
    let session = overrides["session"] as? String ?? "session-preview"
    var state: [String: Any] = [
        "id": session, "sessionId": session, "cwd": overrides["cwd"] ?? "/tmp/preview-project", "source": overrides["source"] ?? "vscode",
        "resumeState": "resumed", "turnsPagination": ["hasLoadedOldest": true],
        "turns": [["turnId": "turn-1", "items": items]]
    ]
    state.merge(stateExtra) { _, new in new }
    return try previewFrame(change: ["type": "snapshot", "revision": revision, "conversationState": state], owner: owner,
                            session: session, host: overrides["host"] as? String ?? "local", version: overrides["version"] as? Int ?? 11)
}

private func previewPatches(_ patches: [[String: Any]], base: Int = 1, revision: Int = 2, owner: String = "owner") throws -> Data {
    try previewFrame(change: ["type": "patches", "baseRevision": base, "revision": revision, "patches": patches], owner: owner)
}

private func previewFrame(change: [String: Any], owner: String, session: String = "session-preview", host: String = "local", version: Int = 11) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "broadcast", "method": "thread-stream-state-changed", "version": version, "sourceClientId": owner,
        "params": ["conversationId": session, "hostId": host, "change": change]
    ])
}
