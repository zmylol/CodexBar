import Foundation
import CodexBarCore

@MainActor
func approvalPayloadTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "correlates approval execution using only hashed input and invocation IDs") {
            let command = "example-tool --credential example-private-credential"
            let before = try approvalPayloadEvent("PreToolUse", input: ["command": command])
            let permission = try approvalPayloadEvent("PermissionRequest", input: [
                "command": command,
                "description": "private approval explanation"
            ])
            let after = try approvalPayloadEvent("PostToolUse", input: ["command": command])
            let execution = try require(before.toolExecution, "PreToolUse correlation is missing")
            try expect(after.name == .postToolUse, "PostToolUse was not parsed")
            try expect(after.toolExecution == execution, "PreToolUse and PostToolUse do not correlate")
            try expect(
                permission.toolExecution?.inputFingerprint == execution.inputFingerprint,
                "approval-only description broke input matching"
            )
            try expect(permission.toolExecution?.invocationID == nil, "approval invented an invocation ID")
            try expect(after.activity == nil && after.plan == nil, "PostToolUse generated an activity")
            let invocationID = try require(execution.invocationID, "execution ID is missing")
            try expect(invocationID.count == 64 && execution.inputFingerprint.count == 64, "hashes are not SHA256 sized")
            let encoded = String(decoding: try JSONEncoder.codexBar.encode(after), as: UTF8.self)
            for value in [command, "example-private-credential", "private-tool-result", "raw-invocation-id"] {
                try expect(!encoded.contains(value), "raw execution data escaped into the queued event")
            }
            let replay = try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: JSONEncoder.codexBar.encode(after))
            try expect(replay == after, "execution metadata did not round-trip")
        },
        CodexBarTestCase(name: "distinguishes commands and canonicalizes MCP input for approval correlation") {
            let first = try approvalPayloadEvent("PreToolUse", input: ["command": "first-command"])
            let second = try approvalPayloadEvent("PreToolUse", input: ["command": "second-command"])
            try expect(first.toolExecution?.inputFingerprint != second.toolExecution?.inputFingerprint, "different commands collided")
            let before = try approvalPayloadEvent("PreToolUse", tool: "mcp__example__query", input: [
                "limit": 3, "filter": ["b": 2, "a": 1], "query": "private search",
                "flags": [true, false, NSNull()] as [Any]
            ])
            let permission = try approvalPayloadEvent("PermissionRequest", tool: "mcp__example__query", input: [
                "query": "private search", "filter": ["a": 1, "b": 2], "limit": 3,
                "description": "approval-only explanation", "flags": [true, false, NSNull()] as [Any]
            ])
            let execution = try require(before.toolExecution, "MCP execution metadata is missing")
            try expect(execution.inputFingerprint == permission.toolExecution?.inputFingerprint, "MCP dictionary ordering broke matching")
            let differentTool = try approvalPayloadEvent("PreToolUse", tool: "mcp__other__query", input: [
                "limit": 3, "filter": ["a": 1, "b": 2], "query": "private search",
                "flags": [true, false, NSNull()] as [Any]
            ])
            try expect(execution.inputFingerprint != differentTool.toolExecution?.inputFingerprint, "different MCP tools collided")
            let capitalizedTool = try approvalPayloadEvent("PreToolUse", tool: "mcp__Example__query", input: [
                "limit": 3, "filter": ["a": 1, "b": 2], "query": "private search",
                "flags": [true, false, NSNull()] as [Any]
            ])
            try expect(execution.inputFingerprint != capitalizedTool.toolExecution?.inputFingerprint, "case-sensitive MCP tool identities collided")
            let encoded = String(decoding: try JSONEncoder.codexBar.encode(before), as: UTF8.self)
            try expect(!encoded.contains("private search"), "MCP argument was retained")
            let patch = try approvalPayloadEvent("PreToolUse", tool: "apply_patch", input: ["command": "example patch"])
            let patchPermission = try approvalPayloadEvent("PermissionRequest", tool: "apply_patch", input: ["patch": "example patch"])
            try expect(patch.toolExecution?.inputFingerprint == patchPermission.toolExecution?.inputFingerprint, "patch alias failed to match")
            let read = try approvalPayloadEvent("PreToolUse", tool: "Read", input: ["file_path": "example.swift"])
            try expect(read.toolExecution == nil, "ordinary reads gained approval metadata")
        },
        CodexBarTestCase(name: "assigns distinct approval receipt IDs while preserving replay identity") {
            let first = try approvalPayloadEvent("PermissionRequest", input: ["command": "same-command"])
            let second = try approvalPayloadEvent("PermissionRequest", input: ["command": "same-command"])
            try expect(first.id != second.id, "separate approvals for the same tool collided")
            let replay = try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: JSONEncoder.codexBar.encode(first))
            try expect(replay.id == first.id, "queued approval replay changed its ID")
            let before = try approvalPayloadEvent("PreToolUse", input: ["command": "same-command"])
            let repeatedBefore = try approvalPayloadEvent("PreToolUse", input: ["command": "same-command"])
            try expect(before.id == repeatedBefore.id, "execution redelivery changed its ID")
        },
        CodexBarTestCase(name: "rejects malformed or misplaced execution metadata") {
            let event = try approvalPayloadEvent("PreToolUse", input: ["command": "example-command"])
            let data = try JSONEncoder.codexBar.encode(event)
            let valid = try require(JSONSerialization.jsonObject(with: data) as? [String: Any], "event JSON is missing")
            let invalidExecutions: [[String: Any]] = [
                ["inputFingerprint": "raw-command"],
                ["inputFingerprint": String(repeating: "a", count: 64), "invocationID": "raw-tool-id"],
                ["inputFingerprint": String(repeating: "A", count: 64)]
            ]
            for invalid in invalidExecutions {
                var payload = valid
                payload["toolExecution"] = invalid
                let decoded = try? JSONDecoder.codexBar.decode(CodexHookEvent.self, from: JSONSerialization.data(withJSONObject: payload))
                try expect(decoded == nil, "invalid execution metadata was decoded")
            }
            for name in ["UserPromptSubmit", "Stop"] {
                var payload = valid
                payload["name"] = name
                payload.removeValue(forKey: "activity")
                let decoded = try? JSONDecoder.codexBar.decode(CodexHookEvent.self, from: JSONSerialization.data(withJSONObject: payload))
                try expect(decoded == nil, "execution metadata was allowed on an unrelated lifecycle event")
            }
            let invalidEvent = CodexHookEvent(
                id: "invalid-execution", sessionID: "session", turnID: "turn", cwd: "/tmp/project",
                name: .stop, promptSummary: nil, toolName: "Bash", timestamp: Date(),
                lastAssistantMessagePresent: false, toolExecution: event.toolExecution,
                source: .visualStudioCode
            )
            try expect((try? JSONEncoder.codexBar.encode(invalidEvent)) == nil, "misplaced execution metadata was encoded")
        },
        CodexBarTestCase(name: "preserves trusted submillisecond execution arrival order") {
            let base = Date(timeIntervalSince1970: 1_777_777_777)
            let before = try approvalPayloadEvent("PreToolUse", input: ["command": "example"], receivedAt: base.addingTimeInterval(0.000_1))
            let permission = try approvalPayloadEvent("PermissionRequest", input: ["command": "example"], receivedAt: base.addingTimeInterval(0.000_2))
            let after = try approvalPayloadEvent("PostToolUse", input: ["command": "example"], receivedAt: base.addingTimeInterval(0.000_3))
            let events = try [before, permission, after].map {
                try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: JSONEncoder.codexBar.encode($0))
            }
            try expect(events[0].timestamp < events[1].timestamp && events[1].timestamp < events[2].timestamp, "execution arrival order collapsed")
        },
        CodexBarTestCase(name: "strips execution correlation metadata when archiving an approval") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarApprovalArchive-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let event = try approvalPayloadEvent("PermissionRequest", input: ["command": "private-approval-command"])
            let url = try InboxWriter(paths: paths).write(event)
            let source = CodexHookEventSource(paths: paths)
            try source.markProcessed(try source.pendingEvents())
            try expect(!FileManager.default.fileExists(atPath: url.path), "processed approval remained in Inbox")
            let archives = try FileManager.default.contentsOfDirectory(at: paths.processed, includingPropertiesForKeys: nil)
            try expect(archives.count == 1, "approval archive is missing or has leftover temporary files")
            let archive = try require(archives.first, "approval archive is missing")
            let data = try Data(contentsOf: archive)
            let decoded = try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: data)
            try expect(decoded.id == event.id && decoded.name == .permissionRequest, "approval archive lost lifecycle identity")
            try expect(decoded.toolExecution == nil, "approval archive retained transient correlation")
            let encoded = String(decoding: data, as: UTF8.self)
            try expect(!encoded.contains("toolExecution") && !encoded.contains("private-approval-command"), "approval metadata leaked into the archive")
            let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "approval archive permissions are not private")
        },
        CodexBarTestCase(name: "preserves approval execution backlog beyond the activity cap and deletes it after processing") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarApprovalPayload-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            for index in 0..<30 {
                for name in ["PreToolUse", "PostToolUse"] {
                    let event = try approvalPayloadEvent(name, input: ["command": "command-\(index)"], invocationID: "tool-\(index)")
                    let url = try writer.write(event)
                    try expect(url.deletingLastPathComponent() == paths.inbox, "approval execution was sent to the lossy activity queue")
                }
            }
            try expect(try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path).count == 60, "approval execution backlog was truncated")
            let source = CodexHookEventSource(paths: paths)
            var processedCount = 0
            while true {
                let pending = try source.pendingEvents()
                if pending.isEmpty { break }
                processedCount += pending.count
                try source.markProcessed(pending)
            }
            try expect(processedCount == 60, "queued executions were lost during draining")
            try expect(try FileManager.default.contentsOfDirectory(atPath: paths.processed.path).isEmpty, "transient execution metadata entered the archive")
        }
    ]
}

private func approvalPayloadEvent(
    _ name: String,
    tool: String = "Bash",
    input: [String: Any],
    invocationID: String = "raw-invocation-id",
    receivedAt: Date = Date(timeIntervalSince1970: 1_777_777_777)
) throws -> CodexHookEvent {
    let payload: [String: Any] = [
        "session_id": "approval-session",
        "turn_id": "approval-turn",
        "cwd": "/tmp/approval-project",
        "hook_event_name": name,
        "tool_name": tool,
        "tool_use_id": invocationID,
        "tool_input": input,
        "tool_response": ["output": "private-tool-result"],
        "timestamp": 1_777_777_777
    ]
    return try CodexHookEventParser(
        now: { receivedAt },
        source: .visualStudioCode
    ).parse(JSONSerialization.data(withJSONObject: payload))
}
