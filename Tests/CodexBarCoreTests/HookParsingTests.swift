import Foundation
import CodexBarCore

@MainActor
func hookParsingTestCases() -> [CodexBarTestCase] {
    let fixedNow = Date(timeIntervalSince1970: 1_777_777_777)

    return [
        CodexBarTestCase(name: "parses official lifecycle fixtures") {
            let parser = CodexHookEventParser(now: { fixedNow }, source: .visualStudioCode)

            let submitted = try parser.parse(fixture("user-prompt-submit"))
            try expect(submitted.sessionID == "session-A", "session_id was not parsed")
            try expect(submitted.turnID == "turn-1", "turn_id was not parsed")
            try expect(submitted.cwd == "/tmp/project-alpha", "cwd was not parsed")
            try expect(submitted.name == .userPromptSubmit, "event name was not parsed")
            try expect(submitted.promptSummary == "Implement login flow", "prompt was not normalized")

            let permission = try parser.parse(fixture("permission-request"))
            try expect(permission.name == .permissionRequest, "PermissionRequest was not parsed")
            try expect(permission.toolName == "Bash", "tool_name was not parsed")

            let stopped = try parser.parse(fixture("stop"))
            try expect(stopped.name == .stop, "Stop was not parsed")
            try expect(stopped.lastAssistantMessagePresent, "assistant message presence was not captured")
        },
        CodexBarTestCase(name: "summarizes apply_patch without retaining raw input") {
            let fullPath = "/Users/example/private-client/Sources/CodexBarCore/TaskStore.swift"
            let exampleSecret = "example-private-token"
            let patch = """
            *** Begin Patch
            *** Update File: \(fullPath)
            @@
            -let token = "\(exampleSecret)"
            +let token = "replacement"
            *** End Patch
            """
            let input = try JSONSerialization.data(withJSONObject: [
                "session_id": "session-A",
                "turn_id": "turn-1",
                "cwd": "/tmp/project-alpha",
                "hook_event_name": "PreToolUse",
                "tool_name": "apply_patch",
                "tool_use_id": "tool-apply-1",
                "tool_input": ["command": patch],
                "timestamp": fixedNow.timeIntervalSince1970
            ])

            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(input)
            let activity = try require(event.activity, "apply_patch activity is missing")

            try expect(event.name == .preToolUse, "PreToolUse was not parsed")
            try expect(activity.kind == .edit, "apply_patch was not classified as an edit")
            try expect(activity.safeSubject == "TaskStore.swift", "edit subject is not useful")
            try expect(event.timestamp == fixedNow, "activity timestamp is wrong")

            let encoded = String(decoding: try JSONEncoder.codexBar.encode(event), as: UTF8.self)
            try expect(!encoded.contains(fullPath), "full file path was retained")
            try expect(!encoded.contains(exampleSecret), "patch secret was retained")
            try expect(!encoded.contains("*** Begin Patch"), "raw patch was retained")
            try expect(!encoded.contains("replacement"), "patch body was retained")
            try expect(!encoded.contains("tool-apply-1"), "raw tool_use_id was retained")
        },
        CodexBarTestCase(name: "classifies Swift tests and keys IDs by tool use") {
            func payload(toolUseID: String) throws -> Data {
                try JSONSerialization.data(withJSONObject: [
                    "session_id": "session-A",
                    "turn_id": "turn-1",
                    "cwd": "/tmp/project-alpha",
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_use_id": toolUseID,
                    "tool_input": ["command": "swift test --filter HookParsingTests"],
                    "timestamp": fixedNow.timeIntervalSince1970
                ])
            }
            let parser = CodexHookEventParser(now: { fixedNow }, source: .visualStudioCode)

            let first = try parser.parse(payload(toolUseID: "tool-test-1"))
            let second = try parser.parse(payload(toolUseID: "tool-test-2"))

            try expect(first.activity?.kind == .test, "Swift test command was not classified as a test")
            try expect(first.id != second.id, "different tool_use_id values produced the same event ID")
            let encoded = String(decoding: try JSONEncoder.codexBar.encode(first), as: UTF8.self)
            try expect(!encoded.contains("tool-test-1"), "raw tool_use_id was retained")
        },
        CodexBarTestCase(name: "classifies common Bash reads and searches without retaining arguments") {
            func payload(toolUseID: String, command: String) throws -> Data {
                try JSONSerialization.data(withJSONObject: [
                    "session_id": "session-A",
                    "turn_id": "turn-1",
                    "cwd": "/tmp/project-alpha",
                    "hook_event_name": "PreToolUse",
                    "tool_name": "Bash",
                    "tool_use_id": toolUseID,
                    "tool_input": ["command": command],
                    "timestamp": fixedNow.timeIntervalSince1970
                ])
            }
            let parser = CodexHookEventParser(now: { fixedNow }, source: .visualStudioCode)
            let privateQuery = "PrivateNeedle"
            let search = try parser.parse(payload(
                toolUseID: "tool-search",
                command: "rg -n \"\(privateQuery)\" Sources"
            ))
            let read = try parser.parse(payload(
                toolUseID: "tool-read",
                command: "sed -n '1,80p' Sources/App.swift"
            ))

            try expect(search.activity?.kind == .search, "Bash rg was not classified as a search")
            try expect(read.activity?.kind == .read, "Bash sed was not classified as a read")
            let encoded = String(
                decoding: try JSONEncoder.codexBar.encode(search),
                as: UTF8.self
            )
            try expect(!encoded.contains(privateQuery), "Bash search arguments were retained")
        },
        CodexBarTestCase(name: "handles a single quote path without crashing") {
            let input = try JSONSerialization.data(withJSONObject: [
                "session_id": "session-A",
                "turn_id": "turn-1",
                "cwd": "/tmp/project-alpha",
                "hook_event_name": "PreToolUse",
                "tool_name": "Read",
                "tool_use_id": "tool-single-quote",
                "tool_input": ["file_path": "'"]
            ])

            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(input)

            try expect(event.activity?.kind == .read, "single quote path lost its activity kind")
        },
        CodexBarTestCase(name: "tolerates missing hook fields") {
            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(Data("{}".utf8))

            try expect(event.sessionID == nil, "missing session_id should remain nil")
            try expect(event.turnID == nil, "missing turn_id should remain nil")
            try expect(event.cwd == nil, "missing cwd should remain nil")
            try expect(event.name == nil, "missing event name should remain nil")
            try expect(event.timestamp == fixedNow, "missing timestamp should use receive time")
        },
        CodexBarTestCase(name: "redacts and truncates prompt summary") {
            let longTail = String(repeating: "界", count: 100)
            let exampleCredential = "example-credential"
            let input = """
            {
              "session_id": "s",
              "turn_id": "t",
              "cwd": "/tmp/project",
              "hook_event_name": "UserPromptSubmit",
              "prompt": "  Deploy   with api_key=\(exampleCredential) \(longTail)\\nsecond line"
            }
            """

            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(Data(input.utf8))
            try expect(!(event.promptSummary?.contains(exampleCredential) ?? true), "secret leaked into summary")
            try expect(event.promptSummary?.contains("[REDACTED]") ?? false, "redaction marker is missing")
            try expect((event.promptSummary?.count ?? .max) <= 80, "summary exceeds 80 characters")
            try expect(!(event.promptSummary?.contains("second line") ?? true), "summary kept later lines")
        },
        CodexBarTestCase(name: "does not persist assistant message body") {
            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(fixture("stop"))
            let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)

            try expect(event.lastAssistantMessagePresent, "message presence was not captured")
            try expect(!json.contains("secret assistant detail"), "assistant message body was persisted")
        },
        CodexBarTestCase(name: "detects assistant message presence without decoding its body") {
            let input = Data(#"{"hook_event_name":"Stop","last_assistant_message":{"secret":"body"}}"#.utf8)

            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(input)

            try expect(event.lastAssistantMessagePresent, "non-string assistant body presence was missed")
        },
        CodexBarTestCase(name: "event ID ignores the raw assistant message body") {
            let first = Data(#"{"session_id":"s","turn_id":"t","cwd":"/tmp/project","hook_event_name":"Stop","last_assistant_message":"first private body"}"#.utf8)
            let second = Data(#"{"session_id":"s","turn_id":"t","cwd":"/tmp/project","hook_event_name":"Stop","last_assistant_message":{"private":"second body"}}"#.utf8)
            let parser = CodexHookEventParser(now: { fixedNow }, source: .visualStudioCode)

            let firstEvent = try parser.parse(first)
            let secondEvent = try parser.parse(second)

            try expect(firstEvent.lastAssistantMessagePresent, "first assistant body presence was missed")
            try expect(secondEvent.lastAssistantMessagePresent, "second assistant body presence was missed")
            try expect(firstEvent.id == secondEvent.id, "raw assistant body changed the event ID")
        },
        CodexBarTestCase(name: "event ID ignores credential values removed from the prompt") {
            let first = Data(#"{"session_id":"s","turn_id":"t","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit","prompt":"Deploy api_key=first-private-value"}"#.utf8)
            let second = Data(#"{"session_id":"s","turn_id":"t","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit","prompt":"Deploy api_key=second-private-value"}"#.utf8)
            let parser = CodexHookEventParser(now: { fixedNow }, source: .visualStudioCode)

            let firstEvent = try parser.parse(first)
            let secondEvent = try parser.parse(second)

            try expect(firstEvent.promptSummary == secondEvent.promptSummary, "test prompts did not sanitize identically")
            try expect(firstEvent.id == secondEvent.id, "redacted credential value changed the event ID")
        },
        CodexBarTestCase(name: "event ID changes when a validated identity field changes") {
            let first = Data(#"{"session_id":"s","turn_id":"first-turn","cwd":"/tmp/project","hook_event_name":"Stop"}"#.utf8)
            let second = Data(#"{"session_id":"s","turn_id":"second-turn","cwd":"/tmp/project","hook_event_name":"Stop"}"#.utf8)
            let parser = CodexHookEventParser(now: { fixedNow }, source: .visualStudioCode)

            let firstEvent = try parser.parse(first)
            let secondEvent = try parser.parse(second)

            try expect(firstEvent.id != secondEvent.id, "validated turn_id did not change the event ID")
        },
        CodexBarTestCase(name: "event ID stays stable when a missing timestamp uses a new receive time") {
            let input = Data(#"{"session_id":"s","turn_id":"t","cwd":"/tmp/project","hook_event_name":"Stop"}"#.utf8)

            let firstEvent = try CodexHookEventParser(
                now: { Date(timeIntervalSince1970: 100) },
                source: .visualStudioCode
            ).parse(input)
            let secondEvent = try CodexHookEventParser(
                now: { Date(timeIntervalSince1970: 200) },
                source: .visualStudioCode
            ).parse(input)

            try expect(firstEvent.timestamp != secondEvent.timestamp, "test did not exercise receive-time fallback")
            try expect(firstEvent.id == secondEvent.id, "receive-time fallback made the event ID unstable")
        },
        CodexBarTestCase(name: "rejects oversized fields and unreasonable timestamps") {
            let oversizedSession = String(repeating: "s", count: 513)
            let input = Data("""
            {
              "session_id": "\(oversizedSession)",
              "turn_id": "turn",
              "cwd": "/tmp/project",
              "hook_event_name": "Stop",
              "timestamp": "9999-01-01T00:00:00Z"
            }
            """.utf8)

            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(input)

            try expect(event.sessionID == nil, "oversized identifier was retained")
            try expect(event.timestamp == fixedNow, "unreasonable timestamp was trusted")
        },
        CodexBarTestCase(name: "redacts common credentials and removes bidi controls") {
            let apiValue = "example-credential"
            let uriPassword = "example-password"
            let basicValue = "QWxhZGRp" + "bjpvcGVuIHNlc2FtZQ=="
            let slackValue = "xoxb-" + "000000000000-example-only"
            let prompt = "\u{202E}api key = \(apiValue) "
                + "postgresql://example:\(uriPassword)@db.example "
                + "Authorization: Basic \(basicValue) \(slackValue)"
            let input = try JSONSerialization.data(withJSONObject: ["prompt": prompt])

            let event = try CodexHookEventParser(
                now: { fixedNow },
                source: .visualStudioCode
            ).parse(input)
            let summary = try require(event.promptSummary, "sanitized prompt is missing")

            try expect(!summary.contains(apiValue), "spaced API key leaked")
            try expect(!summary.contains(uriPassword), "URI password leaked")
            try expect(!summary.contains(basicValue), "Basic credential leaked")
            try expect(!summary.contains("xoxb-"), "Slack token leaked")
            try expect(!summary.unicodeScalars.contains("\u{202E}"), "bidi override was retained")

            let focusedSamples = [
                ("Authorization: Basic \(basicValue)", basicValue),
                ("postgresql://example:\(uriPassword)@db.example", uriPassword),
                (slackValue, "xoxb-")
            ]
            for (value, secret) in focusedSamples {
                let sanitized = try require(
                    PromptSanitizer.sanitize(value),
                    "focused sanitized prompt is missing"
                )
                try expect(!sanitized.contains(secret), "focused credential pattern leaked")
                try expect(sanitized.contains("[REDACTED]"), "focused credential was not marked")
            }
        }
    ]
}

@MainActor
private func fixture(_ name: String) throws -> Data {
    let url = try require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "fixture \(name) is missing"
    )
    return try Data(contentsOf: url)
}
