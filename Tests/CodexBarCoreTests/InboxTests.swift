import Foundation
import CodexBarCore

@MainActor
func inboxTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "writes inbox events atomically with private permissions") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let event = inboxEvent(.userPromptSubmit, timestamp: 100)

            let url = try InboxWriter(paths: paths).write(event)

            try expect(url.pathExtension == "json", "final file is not JSON")
            try expect(FileManager.default.fileExists(atPath: url.path), "event file does not exist")
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path)
                    .allSatisfy { !$0.hasSuffix(".tmp") },
                "temporary file remained in inbox"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "event mode is not 0600")
            try expect(
                try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: Data(contentsOf: url)) == event,
                "written event does not round-trip"
            )
        },
        CodexBarTestCase(name: "orders lifecycle and plan files at microsecond precision") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            let baseTimestamp: TimeInterval = 1_700_000_000

            let promptURL = try writer.write(inboxEvent(
                .userPromptSubmit,
                timestamp: baseTimestamp + 0.000_1
            ))
            let planURL = try writer.write(inboxPlanEvent(
                timestamp: baseTimestamp + 0.000_2
            ))
            let stopURL = try writer.write(inboxEvent(
                .stop,
                timestamp: baseTimestamp + 0.000_3
            ))
            let prefixes = [promptURL, planURL, stopURL].map { url in
                String(url.lastPathComponent.prefix { $0 != "_" })
            }

            try expect(
                prefixes[0] < prefixes[1] && prefixes[1] < prefixes[2],
                "submillisecond event timestamps collapsed or sorted out of order"
            )
            let pendingNames = try CodexHookEventSource(paths: paths)
                .pendingEvents()
                .compactMap(\.event.name)
            try expect(
                pendingNames == [.userPromptSubmit, .preToolUse, .stop],
                "prompt, plan, and Stop were replayed out of order"
            )
        },
        CodexBarTestCase(name: "rejects timestamps outside the filename range") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            var didThrow = false

            do {
                _ = try InboxWriter(paths: paths).write(inboxEvent(
                    .stop,
                    timestamp: 10_000_000_000_000
                ))
            } catch {
                didThrow = true
            }

            try expect(didThrow, "an out-of-range timestamp reached a trapping integer conversion")
        },
        CodexBarTestCase(name: "bounds transient activity separately and prioritizes lifecycle") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            _ = try writer.write(inboxEvent(.userPromptSubmit, timestamp: 100))
            for index in 0..<20 {
                _ = try writer.write(inboxActionEvent(
                    timestamp: TimeInterval(101 + index),
                    toolUseID: "bounded-tool-\(index)"
                ))
            }

            let inboxFiles = try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path)
            let activityFiles = try FileManager.default.contentsOfDirectory(atPath: paths.activity.path)
            try expect(inboxFiles.count == 1, "activity files entered the lifecycle Inbox")
            try expect(activityFiles.count == 12, "transient activity queue exceeded its bound")

            let pending = try CodexHookEventSource(paths: paths).pendingEvents()
            try expect(pending.count == 13, "source did not read both bounded queues")
            try expect(
                pending.first?.event.name == .userPromptSubmit,
                "transient activity was processed ahead of lifecycle state"
            )
        },
        CodexBarTestCase(name: "keeps a plan snapshot through an activity burst") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            _ = try writer.write(inboxPlanEvent(timestamp: 100))
            for index in 0..<12 {
                _ = try writer.write(inboxActionEvent(
                    timestamp: TimeInterval(101 + index),
                    toolUseID: "burst-tool-\(index)"
                ))
            }

            let queuedEvents = try FileManager.default.contentsOfDirectory(
                at: paths.activity,
                includingPropertiesForKeys: nil
            ).map { url in
                try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: Data(contentsOf: url))
            }

            try expect(queuedEvents.count == 12, "the transient queue exceeded its bound")
            try expect(
                queuedEvents.contains(where: { $0.plan != nil }),
                "an activity burst evicted the current plan snapshot"
            )
        },
        CodexBarTestCase(name: "new prompt clears queued activity only for its workspace") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            _ = try writer.write(inboxActionEvent(
                timestamp: 100,
                cwd: "/tmp/project-alpha",
                toolUseID: "alpha-old"
            ))
            _ = try writer.write(inboxActionEvent(
                timestamp: 101,
                session: "session-B",
                turn: "turn-B",
                cwd: "/tmp/project-beta",
                toolUseID: "beta-current"
            ))

            _ = try writer.write(inboxEvent(
                .userPromptSubmit,
                timestamp: 102,
                session: "session-new",
                turn: "turn-new",
                cwd: "/tmp/project-alpha"
            ))

            let remainingActivities = try FileManager.default.contentsOfDirectory(
                at: paths.activity,
                includingPropertiesForKeys: nil
            ).map { url in
                try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: Data(contentsOf: url))
            }
            try expect(remainingActivities.count == 1, "new prompt did not replace old workspace activity")
            try expect(
                remainingActivities.first?.cwd == "/tmp/project-beta",
                "new prompt removed another workspace's current activity"
            )
        },
        CodexBarTestCase(name: "new prompt removes malformed transient activity") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            try Data("{not-json".utf8).write(
                to: paths.activity.appendingPathComponent("malformed.json")
            )

            _ = try InboxWriter(paths: paths).write(inboxEvent(
                .userPromptSubmit,
                timestamp: 100
            ))

            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.activity.path).isEmpty,
                "a malformed old activity survived the next prompt"
            )
        },
        CodexBarTestCase(name: "does not consume activity past a lifecycle backlog") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            for index in 0..<26 {
                _ = try writer.write(inboxEvent(
                    .userPromptSubmit,
                    timestamp: TimeInterval(100 + index),
                    session: "backlog-session",
                    turn: "turn-\(index)"
                ))
            }
            _ = try writer.write(inboxActionEvent(
                timestamp: 126,
                session: "backlog-session",
                turn: "turn-25",
                toolUseID: "backlog-tool"
            ))
            let store = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let processor = EventProcessor(
                source: CodexHookEventSource(paths: paths),
                store: store,
                activityStore: activityStore
            )

            let firstCount = try await processor.processPending()
            try expect(firstCount == 25, "first poll did not stop at the lifecycle bound")
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.activity.path).count == 1,
                "activity was deleted before its prompt could be processed"
            )

            let secondCount = try await processor.processPending()
            let task = try require(store.tasks.first, "backlog task is missing")
            try expect(secondCount == 2, "second poll did not consume prompt and activity")
            try expect(task.turnID == "turn-25", "backlog did not advance to its final prompt")
            try expect(
                activityStore.nodes(for: task).first?.kind == .test,
                "deferred activity was not attached to its prompt"
            )
        },
        CodexBarTestCase(name: "does not consume activity from a newer lifecycle snapshot") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            let writer = InboxWriter(paths: paths)
            let fileManager = InboxSnapshotRaceFileManager(inboxURL: paths.inbox) {
                _ = try writer.write(inboxEvent(.userPromptSubmit, timestamp: 100))
                _ = try writer.write(inboxActionEvent(timestamp: 101))
            }
            let source = CodexHookEventSource(paths: paths, fileManager: fileManager)

            let firstPoll = try source.pendingEvents()
            try expect(
                firstPoll.allSatisfy { $0.event.name != .preToolUse },
                "activity overtook the prompt written after the lifecycle snapshot"
            )

            let secondPoll = try source.pendingEvents()
            try expect(secondPoll.count == 2, "the deferred prompt and activity were not both retained")
            try expect(
                secondPoll.map(\.event.name) == [.userPromptSubmit, .preToolUse],
                "the deferred activity was not ordered after its prompt"
            )
        },
        CodexBarTestCase(name: "treats a concurrently replaced activity file as consumed") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let url = try InboxWriter(paths: paths).write(inboxActionEvent(timestamp: 100))
            let source = CodexHookEventSource(paths: paths)
            let pending = try require(
                try source.pendingEvents().first,
                "activity was not available before the simulated race"
            )
            try FileManager.default.removeItem(at: url)

            try source.markProcessed(pending)

            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.activity.path).isEmpty,
                "concurrently removed activity was recreated"
            )
        },
        CodexBarTestCase(name: "deletes malformed activity without archiving it") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            try Data("{not-json".utf8).write(
                to: paths.activity.appendingPathComponent("malformed.json")
            )

            let pending = try CodexHookEventSource(paths: paths).pendingEvents()

            try expect(pending.isEmpty, "malformed activity became a pending event")
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.activity.path).isEmpty,
                "malformed activity was retained in the transient queue"
            )
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.failed.path).isEmpty,
                "malformed activity was persisted in the Failed archive"
            )
        },
        CodexBarTestCase(name: "deletes stale managed temporary activity files") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            let staleURL = paths.activity.appendingPathComponent(
                ".2026-09-04T00-00-00.000Z_\(UUID().uuidString.lowercased()).plan.tmp"
            )
            let recentURL = paths.activity.appendingPathComponent(
                ".2026-09-04T00-00-01.000Z_\(UUID().uuidString.lowercased()).tmp"
            )
            let unrelatedURL = paths.activity.appendingPathComponent(".not-managed.tmp")
            try Data("private stale plan".utf8).write(to: staleURL)
            try Data("active writer".utf8).write(to: recentURL)
            try Data("unrelated".utf8).write(to: unrelatedURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-600)],
                ofItemAtPath: staleURL.path
            )

            _ = try CodexHookEventSource(paths: paths).pendingEvents()

            try expect(
                !FileManager.default.fileExists(atPath: staleURL.path),
                "a stale managed temporary plan file survived polling"
            )
            try expect(
                FileManager.default.fileExists(atPath: recentURL.path),
                "a recent writer temporary file was removed"
            )
            try expect(
                FileManager.default.fileExists(atPath: unrelatedURL.path),
                "an unrelated hidden file was removed"
            )
        },
        CodexBarTestCase(name: "drops lifecycle events carrying transient plan data") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            let invalidEvent = CodexHookEvent(
                id: "event-invalid-lifecycle-plan",
                sessionID: "session-A",
                turnID: "turn-1",
                cwd: "/tmp/project-alpha",
                name: .stop,
                promptSummary: nil,
                toolName: "update_plan",
                timestamp: Date(timeIntervalSince1970: 120),
                lastAssistantMessagePresent: false,
                plan: CodexHookPlanSummary(steps: [
                    CodexTaskPlanStep(id: 0, title: "private transient plan", status: .completed)
                ]),
                source: .visualStudioCode
            )
            let invalidURL = paths.inbox.appendingPathComponent("invalid-lifecycle-plan.json")
            try JSONEncoder.codexBar.encode(invalidEvent).write(to: invalidURL)
            func writeMalformedFixture(
                _ filename: String,
                mutate: (inout [String: Any]) -> Void
            ) throws -> URL {
                var payload: [String: Any] = [
                    "id": "event-invalid-transient-plan",
                    "sessionID": "session-A",
                    "turnID": "turn-1",
                    "cwd": "/tmp/project-alpha",
                    "name": "Stop",
                    "toolName": "update_plan",
                    "plan": [
                        "steps": [[
                            "id": 0,
                            "title": "private malformed transient plan",
                            "status": "completed"
                        ]]
                    ],
                    "timestamp": 120,
                    "lastAssistantMessagePresent": false,
                    "source": "vscode"
                ]
                mutate(&payload)
                let url = paths.inbox.appendingPathComponent(filename)
                try JSONSerialization.data(withJSONObject: payload).write(to: url)
                return url
            }
            let malformedURLs = try [
                writeMalformedFixture("invalid-plan-status.json") { payload in
                    payload["plan"] = [
                        "steps": [[
                            "id": 0,
                            "title": "private invalid status plan",
                            "status": "future_status"
                        ]]
                    ]
                },
                writeMalformedFixture("invalid-plan-id.json") { payload in
                    payload["id"] = ["not-a-string"]
                },
                writeMalformedFixture("invalid-plan-name.json") { payload in
                    payload["name"] = "FutureStop"
                },
                writeMalformedFixture("invalid-plan-timestamp.json") { payload in
                    payload["timestamp"] = "not-a-date"
                }
            ]

            let pending = try CodexHookEventSource(paths: paths).pendingEvents()

            try expect(pending.isEmpty, "a lifecycle event retained transient plan data")
            try expect(
                !FileManager.default.fileExists(atPath: invalidURL.path),
                "the invalid transient plan remained in Inbox"
            )
            for malformedURL in malformedURLs {
                try expect(
                    !FileManager.default.fileExists(atPath: malformedURL.path),
                    "a malformed transient plan remained in Inbox"
                )
            }
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.processed.path).isEmpty,
                "the invalid transient plan entered Processed"
            )
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.failed.path).isEmpty,
                "the invalid transient plan entered Failed"
            )
        },
        CodexBarTestCase(name: "processes each inbox file once") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            _ = try writer.write(inboxEvent(.userPromptSubmit, timestamp: 100))
            _ = try writer.write(inboxEvent(.stop, timestamp: 110))
            let store = TaskStore()
            let processor = EventProcessor(source: CodexHookEventSource(paths: paths), store: store)

            let firstProcessedCount = try await processor.processPending()
            try expect(firstProcessedCount == 2, "processor did not consume two files")
            try expect(store.tasks.first?.status == .ready, "processed state is not ready")
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path).count == 0,
                "inbox was not emptied"
            )
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.processed.path).count == 2,
                "processed files were not retained"
            )
            let secondProcessedCount = try await processor.processPending()
            try expect(secondProcessedCount == 0, "files were processed more than once")
        },
        CodexBarTestCase(name: "keeps tool activity in memory and out of lifecycle archives") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            _ = try writer.write(inboxEvent(.userPromptSubmit, timestamp: 100))
            _ = try writer.write(inboxActionEvent(timestamp: 105))
            _ = try writer.write(inboxPlanEvent(timestamp: 107))
            _ = try writer.write(inboxEvent(.permissionRequest, timestamp: 110))
            _ = try writer.write(inboxEvent(.stop, timestamp: 120))
            let store = TaskStore(persistenceURL: paths.taskStore)
            let activityStore = LiveTaskActivityStore()
            let processor = EventProcessor(
                source: CodexHookEventSource(paths: paths),
                store: store,
                activityStore: activityStore
            )

            let processedCount = try await processor.processPending()

            try expect(processedCount == 5, "processor did not consume both live events")
            let task = try require(store.tasks.first, "lifecycle task is missing")
            try expect(task.status == .ready, "lifecycle events did not reach ready")
            let nodes = activityStore.nodes(for: task)
            try expect(nodes.count == 1, "activity was not retained as one in-memory node")
            try expect(nodes.first?.kind == .test, "activity kind is wrong")
            try expect(nodes.first?.summary == "运行 Swift 测试", "activity summary is wrong")
            try expect(
                nodes.first?.occurredAt == Date(timeIntervalSince1970: 105),
                "activity timestamp is wrong"
            )
            let plan = try require(activityStore.plan(for: task), "plan was not kept in memory")
            try expect(plan.currentStepNumber == 2, "plan current step is wrong")
            try expect(plan.totalStepCount == 3, "plan total step count is wrong")
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path).isEmpty,
                "processed activity remained in Inbox"
            )
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.activity.path).isEmpty,
                "processed live events remained in Activity"
            )

            let archivedEvents = try FileManager.default.contentsOfDirectory(
                at: paths.processed,
                includingPropertiesForKeys: nil
            ).map { url in
                try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: Data(contentsOf: url))
            }
            try expect(archivedEvents.count == 3, "activity was retained in Processed")
            try expect(
                archivedEvents.compactMap(\.name).map(\.rawValue).sorted()
                    == ["PermissionRequest", "Stop", "UserPromptSubmit"],
                "Processed did not contain only lifecycle events"
            )

            let taskSnapshot = String(decoding: try Data(contentsOf: paths.taskStore), as: UTF8.self)
            try expect(!taskSnapshot.contains("运行 Swift 测试"), "activity summary leaked into tasks.json")
            try expect(!taskSnapshot.contains("Private transient plan"), "plan leaked into tasks.json")
            try expect(!taskSnapshot.contains("PreToolUse"), "activity event leaked into tasks.json")
        },
        CodexBarTestCase(name: "keeps activity when a continued turn completes in one Inbox batch") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            _ = try writer.write(inboxEvent(
                .userPromptSubmit,
                timestamp: 100,
                session: "same-session",
                turn: "initial-turn"
            ))
            _ = try writer.write(inboxActionEvent(
                timestamp: 110,
                session: "same-session",
                turn: "initial-turn"
            ))
            _ = try writer.write(inboxEvent(
                .stop,
                timestamp: 120,
                session: "same-session",
                turn: "continued-turn"
            ))
            let store = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let processor = EventProcessor(
                source: CodexHookEventSource(paths: paths),
                store: store,
                activityStore: activityStore
            )

            _ = try await processor.processPending()

            let task = try require(store.tasks.first, "continued task is missing")
            try expect(task.turnID == "continued-turn", "continued stop did not replace the turn")
            try expect(
                activityStore.nodes(for: task).first?.summary == "运行 Swift 测试",
                "one-batch continued turn discarded its activity"
            )
        },
        CodexBarTestCase(name: "does not migrate old activity into a newly prompted turn") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            let store = TaskStore()
            let activityStore = LiveTaskActivityStore()
            let processor = EventProcessor(
                source: CodexHookEventSource(paths: paths),
                store: store,
                activityStore: activityStore
            )
            _ = try writer.write(inboxEvent(
                .userPromptSubmit,
                timestamp: 100,
                session: "same-session",
                turn: "old-turn"
            ))
            _ = try writer.write(inboxActionEvent(
                timestamp: 110,
                session: "same-session",
                turn: "old-turn",
                toolUseID: "old-tool"
            ))
            _ = try await processor.processPending()
            let oldTask = try require(store.tasks.first, "old task is missing")
            try expect(!activityStore.nodes(for: oldTask).isEmpty, "old task has no trace to reject")

            _ = try writer.write(inboxEvent(
                .userPromptSubmit,
                timestamp: 200,
                session: "same-session",
                turn: "new-turn"
            ))
            _ = try writer.write(inboxEvent(
                .stop,
                timestamp: 210,
                session: "same-session",
                turn: "new-turn"
            ))
            _ = try await processor.processPending()

            let newTask = try require(store.tasks.first, "new task is missing")
            try expect(newTask.turnID == "new-turn", "new prompt did not replace the old turn")
            try expect(
                activityStore.nodes(for: newTask).isEmpty,
                "newly prompted turn inherited the old turn's activity"
            )
        },
        CodexBarTestCase(name: "keeps one current turn when Inbox contains two turns for one cwd") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let writer = InboxWriter(paths: paths)
            _ = try writer.write(inboxEvent(
                .userPromptSubmit,
                timestamp: 100,
                session: "old-session",
                turn: "old-turn"
            ))
            _ = try writer.write(inboxEvent(
                .userPromptSubmit,
                timestamp: 200,
                session: "new-session",
                turn: "new-turn"
            ))
            let store = TaskStore()
            let processor = EventProcessor(source: CodexHookEventSource(paths: paths), store: store)

            let processedCount = try await processor.processPending()
            try expect(processedCount == 2, "processor did not consume both turns")
            try expect(store.tasks.count == 1, "Inbox processing created duplicate cwd rows")
            try expect(store.tasks.first?.id == "new-session:new-turn", "Inbox kept the old turn")
        },
        CodexBarTestCase(name: "captures a sanitized hook probe without the app running") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let raw = Data("""
            {
              "session_id": "probe-session",
              "turn_id": "probe-turn",
              "cwd": "/tmp/probe-project",
              "hook_event_name": "Stop",
              "last_assistant_message": "private assistant body",
              "tool_name": "Bash",
              "timestamp": "2026-08-30T23:42:12Z"
            }
            """.utf8)

            let url = try HookCaptureService(paths: paths).capture(raw, mode: .probe)
            let data = try Data(contentsOf: url)
            let json = String(decoding: data, as: UTF8.self)
            let record = try JSONDecoder.codexBar.decode(CodexHookProbeRecord.self, from: data)

            try expect(url.deletingLastPathComponent() == paths.probe, "probe was written outside Probe")
            try expect(record.sessionID == "probe-session", "probe session is wrong")
            try expect(record.turnID == "probe-turn", "probe turn is wrong")
            try expect(record.hookEventName == "Stop", "probe event name is wrong")
            try expect(record.lastAssistantMessage == "[REDACTED]", "assistant body was not redacted")
            try expect(!json.contains("private assistant body"), "assistant body leaked into probe")
        },
        CodexBarTestCase(name: "captures only a safe activity summary in probe mode") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let privatePath = "/Users/example/private-client/ProbeOnly.swift"
            let patchSecret = "example-secret-from-patch"
            let raw = try JSONSerialization.data(withJSONObject: [
                "session_id": "probe-session",
                "turn_id": "probe-turn",
                "cwd": "/tmp/probe-project",
                "hook_event_name": "PreToolUse",
                "tool_name": "apply_patch",
                "tool_use_id": "probe-tool",
                "tool_input": [
                    "command": "*** Begin Patch\n*** Update File: \(privatePath)\n@@\n+\(patchSecret)\n*** End Patch"
                ]
            ])

            let url = try HookCaptureService(paths: paths).capture(raw, mode: .probe)
            let data = try Data(contentsOf: url)
            let json = String(decoding: data, as: UTF8.self)
            let record = try JSONDecoder.codexBar.decode(CodexHookProbeRecord.self, from: data)

            try expect(record.activityKind == .edit, "probe omitted the activity kind")
            try expect(record.activitySubject == "ProbeOnly.swift", "probe activity subject is not safe")
            try expect(!json.contains(privatePath), "probe retained an absolute activity path")
            try expect(!json.contains(patchSecret), "probe retained raw patch content")
            try expect(!json.contains("*** Begin Patch"), "probe retained the raw patch")
        },
        CodexBarTestCase(name: "captures a normal hook into Inbox") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            let raw = Data("""
            {
              "session_id": "capture-session",
              "turn_id": "capture-turn",
              "cwd": "/tmp/capture-project",
              "hook_event_name": "UserPromptSubmit",
              "prompt": "Test capture"
            }
            """.utf8)

            let url = try HookCaptureService(paths: paths).capture(raw, mode: .inbox)

            try expect(url.deletingLastPathComponent() == paths.inbox, "normal event was not written to Inbox")
            try expect(FileManager.default.fileExists(atPath: url.path), "captured event is missing")
        },
        CodexBarTestCase(name: "quarantines malformed inbox files without blocking valid events") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            let malformedURL = paths.inbox.appendingPathComponent("000-malformed.json")
            try Data("not-json".utf8).write(to: malformedURL)
            _ = try InboxWriter(paths: paths).write(
                inboxEvent(.userPromptSubmit, timestamp: 100)
            )
            let store = TaskStore()
            let processor = EventProcessor(source: CodexHookEventSource(paths: paths), store: store)

            let processedCount = try await processor.processPending()
            try expect(processedCount == 1, "valid event was blocked")
            try expect(store.tasks.count == 1, "valid event was not applied")
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.failed.path).count == 1,
                "malformed event was not quarantined"
            )
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path).isEmpty,
                "inbox was not drained"
            )
        },
        CodexBarTestCase(name: "rotates Processed to 500 files and preserves the event just archived") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            let oldest = paths.processed.appendingPathComponent("000-oldest.json")
            try writeArchiveFixture(oldest, modifiedAt: Date().addingTimeInterval(-3_600))
            for index in 1..<500 {
                let url = paths.processed.appendingPathComponent(
                    String(format: "%03d-recent.json", index)
                )
                try writeArchiveFixture(url, modifiedAt: Date())
            }
            let inboxURL = try InboxWriter(paths: paths).write(
                inboxEvent(.stop, timestamp: 120)
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-(8 * 24 * 60 * 60))],
                ofItemAtPath: inboxURL.path
            )
            let source = CodexHookEventSource(paths: paths)
            let pending = try require(
                try source.pendingEvents().first,
                "new event was not available for archiving"
            )

            try source.markProcessed(pending)

            let archivedURL = paths.processed.appendingPathComponent(inboxURL.lastPathComponent)
            try expect(try archiveFileCount(in: paths.processed) == 500, "Processed exceeded 500 files")
            try expect(FileManager.default.fileExists(atPath: archivedURL.path), "newly processed event was pruned")
            try expect(!FileManager.default.fileExists(atPath: oldest.path), "oldest Processed file was retained")
        },
        CodexBarTestCase(name: "removes Failed records older than seven days and preserves the new quarantine") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            let expired = paths.failed.appendingPathComponent("expired.json")
            try writeArchiveFixture(
                expired,
                modifiedAt: Date().addingTimeInterval(-(8 * 24 * 60 * 60))
            )
            let malformed = paths.inbox.appendingPathComponent("new-malformed.json")
            try Data("not-json".utf8).write(to: malformed)

            let pending = try CodexHookEventSource(paths: paths).pendingEvents()

            try expect(pending.isEmpty, "malformed event unexpectedly became pending")
            try expect(!FileManager.default.fileExists(atPath: expired.path), "expired Failed record was retained")
            try expect(
                FileManager.default.fileExists(
                    atPath: paths.failed.appendingPathComponent(malformed.lastPathComponent).path
                ),
                "newly quarantined record was pruned"
            )
        },
        CodexBarTestCase(name: "rotates Probe to 500 files and preserves the record just written") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareProbeDirectory()
            let expired = paths.probe.appendingPathComponent("000-expired.json")
            try writeArchiveFixture(
                expired,
                modifiedAt: Date().addingTimeInterval(-(8 * 24 * 60 * 60))
            )
            for index in 1..<500 {
                let url = paths.probe.appendingPathComponent(
                    String(format: "%03d-recent.json", index)
                )
                try writeArchiveFixture(url, modifiedAt: Date())
            }
            let current = try ProbeWriter(paths: paths).write(
                CodexHookProbeRecord(event: inboxEvent(.stop, timestamp: 120))
            )

            try expect(try archiveFileCount(in: paths.probe) == 500, "Probe exceeded 500 files")
            try expect(FileManager.default.fileExists(atPath: current.path), "new Probe record was pruned")
            try expect(!FileManager.default.fileExists(atPath: expired.path), "expired Probe record was retained")
        },
        CodexBarTestCase(name: "normal Inbox polling removes expired Probe records") {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareProbeDirectory()
            let expired = paths.probe.appendingPathComponent("expired-after-probe-mode.json")
            try writeArchiveFixture(
                expired,
                modifiedAt: Date().addingTimeInterval(-(8 * 24 * 60 * 60))
            )

            _ = try CodexHookEventSource(paths: paths).pendingEvents()

            try expect(
                !FileManager.default.fileExists(atPath: expired.path),
                "normal Inbox polling left expired Probe data behind"
            )
        },
        CodexBarTestCase(name: "rejects a symbolic-link Application Support root") {
            let sandbox = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let target = sandbox.appendingPathComponent("unrelated-target", isDirectory: true)
            let linkedRoot = sandbox.appendingPathComponent("CodexBar", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)

            var rejected = false
            do {
                try CodexBarPaths(rootDirectory: linkedRoot).prepareEventDirectories()
            } catch {
                rejected = true
            }

            try expect(rejected, "a symbolic-link support root was accepted")
            try expect(
                !FileManager.default.fileExists(
                    atPath: target.appendingPathComponent("Inbox", isDirectory: true).path
                ),
                "managed directories were created through a symbolic link"
            )
        },
        CodexBarTestCase(name: "rejects a symbolic-link task snapshot without moving it") {
            let sandbox = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let paths = CodexBarPaths(
                rootDirectory: sandbox.appendingPathComponent("CodexBar", isDirectory: true)
            )
            try paths.prepareStorageDirectory()
            let target = sandbox.appendingPathComponent("unrelated-tasks.json")
            let originalData = Data("must remain unchanged".utf8)
            try originalData.write(to: target)
            try FileManager.default.createSymbolicLink(
                at: paths.taskStore,
                withDestinationURL: target
            )

            let store = TaskStore(persistenceURL: paths.taskStore)
            var didThrow = false
            do {
                _ = try await store.apply(inboxEvent(.userPromptSubmit, timestamp: 100))
            } catch TaskStorePersistenceError.persistenceUnavailable {
                didThrow = true
            }

            try expect(didThrow, "symbolic-link task snapshot remained writable")
            try expect(
                try FileManager.default.destinationOfSymbolicLink(atPath: paths.taskStore.path)
                    == target.path,
                "symbolic-link task snapshot was moved or replaced"
            )
            try expect(try Data(contentsOf: target) == originalData, "linked target was modified")
        },
        CodexBarTestCase(name: "archives a processed Inbox batch in one source operation") {
            let events = [
                PendingCodexEvent(
                    event: inboxEvent(.userPromptSubmit, timestamp: 100),
                    sourceURL: URL(fileURLWithPath: "/tmp/first.json")
                ),
                PendingCodexEvent(
                    event: inboxEvent(.stop, timestamp: 110),
                    sourceURL: URL(fileURLWithPath: "/tmp/second.json")
                )
            ]
            let source = BatchRecordingEventSource(events: events)
            let store = TaskStore()
            let processor = EventProcessor(source: source, store: store)

            let processedCount = try await processor.processPending()
            try expect(processedCount == 2, "batch was not processed")
            let calls = source.recordedCalls()
            try expect(calls.batch == 1, "source batch archiving was not used once")
            try expect(calls.single == 0, "source archived events one at a time")
        },
        CodexBarTestCase(name: "does not archive Inbox events when task persistence fails") {
            let sandbox = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
            let target = sandbox.appendingPathComponent("unrelated.json")
            try Data("unchanged".utf8).write(to: target)
            let persistenceURL = sandbox.appendingPathComponent("tasks.json")
            try FileManager.default.createSymbolicLink(
                at: persistenceURL,
                withDestinationURL: target
            )
            let pending = PendingCodexEvent(
                event: inboxEvent(.userPromptSubmit, timestamp: 100),
                sourceURL: URL(fileURLWithPath: "/tmp/persistence-failure.json")
            )
            let source = BatchRecordingEventSource(events: [pending])
            let processor = EventProcessor(
                source: source,
                store: TaskStore(persistenceURL: persistenceURL)
            )

            var didThrow = false
            do {
                _ = try await processor.processPending()
            } catch TaskStorePersistenceError.persistenceUnavailable {
                didThrow = true
            }

            try expect(didThrow, "persistence failure was swallowed")
            let calls = source.recordedCalls()
            try expect(calls.batch == 0 && calls.single == 0, "events were archived before state persisted")
            try expect(try Data(contentsOf: target) == Data("unchanged".utf8), "linked target changed")
        },
        CodexBarTestCase(name: "retries archiving after task state is already durable") {
            let events = [
                PendingCodexEvent(
                    event: inboxEvent(.userPromptSubmit, timestamp: 100),
                    sourceURL: URL(fileURLWithPath: "/tmp/retry-first.json")
                ),
                PendingCodexEvent(
                    event: inboxEvent(.stop, timestamp: 110),
                    sourceURL: URL(fileURLWithPath: "/tmp/retry-second.json")
                )
            ]
            let source = BatchRecordingEventSource(events: events, batchFailuresRemaining: 1)
            let store = TaskStore()
            let processor = EventProcessor(source: source, store: store)

            var firstAttemptFailed = false
            do {
                _ = try await processor.processPending()
            } catch BatchRecordingError.expectedFailure {
                firstAttemptFailed = true
            }
            try expect(firstAttemptFailed, "archive failure was swallowed")
            try expect(store.tasks.first?.status == .ready, "durable state was rolled back after archive failure")

            let retryCount = try await processor.processPending()
            try expect(retryCount == 2, "retry did not consume the retained events")
            let calls = source.recordedCalls()
            try expect(calls.batch == 2 && calls.single == 0, "archive retry was not batched")
        }
    ]
}

private final class BatchRecordingEventSource: CodexEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [PendingCodexEvent]
    private var singleCalls = 0
    private var batchCalls = 0
    private var batchFailuresRemaining: Int

    init(events: [PendingCodexEvent], batchFailuresRemaining: Int = 0) {
        self.events = events
        self.batchFailuresRemaining = batchFailuresRemaining
    }

    func pendingEvents() throws -> [PendingCodexEvent] {
        events
    }

    func markProcessed(_ pendingEvent: PendingCodexEvent) throws {
        lock.withLock {
            singleCalls += 1
        }
    }

    func markProcessed(_ pendingEvents: [PendingCodexEvent]) throws {
        let shouldFail = lock.withLock {
            batchCalls += 1
            guard batchFailuresRemaining > 0 else {
                return false
            }
            batchFailuresRemaining -= 1
            return true
        }
        if shouldFail {
            throw BatchRecordingError.expectedFailure
        }
    }

    func recordedCalls() -> (single: Int, batch: Int) {
        lock.withLock { (singleCalls, batchCalls) }
    }
}

private enum BatchRecordingError: Error {
    case expectedFailure
}

private final class InboxSnapshotRaceFileManager: FileManager, @unchecked Sendable {
    private let inboxURL: URL
    private let onFirstInboxSnapshot: () throws -> Void
    private var didInjectRace = false

    init(inboxURL: URL, onFirstInboxSnapshot: @escaping () throws -> Void) {
        self.inboxURL = inboxURL
        self.onFirstInboxSnapshot = onFirstInboxSnapshot
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        let contents = try super.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: mask
        )
        if url.standardizedFileURL == inboxURL.standardizedFileURL, !didInjectRace {
            didInjectRace = true
            try onFirstInboxSnapshot()
        }
        return contents
    }
}

private func writeArchiveFixture(_ url: URL, modifiedAt: Date) throws {
    try Data("{}".utf8).write(to: url)
    try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: url.path
    )
}

private func archiveFileCount(in directory: URL) throws -> Int {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ).filter { url in
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }.count
}

private func inboxEvent(
    _ name: CodexHookEventName,
    timestamp: TimeInterval,
    session: String = "session-A",
    turn: String = "turn-1",
    cwd: String = "/tmp/project-alpha"
) -> CodexHookEvent {
    CodexHookEvent(
        id: "event-\(name.rawValue)-\(timestamp)",
        sessionID: session,
        turnID: turn,
        cwd: cwd,
        name: name,
        promptSummary: name == .userPromptSubmit ? "Test inbox" : nil,
        toolName: nil,
        timestamp: Date(timeIntervalSince1970: timestamp),
        lastAssistantMessagePresent: false,
        source: .visualStudioCode
    )
}

private func inboxActionEvent(
    timestamp: TimeInterval,
    session: String = "session-A",
    turn: String = "turn-1",
    cwd: String = "/tmp/project-alpha",
    toolUseID: String = "tool-test-1"
) throws -> CodexHookEvent {
    let date = Date(timeIntervalSince1970: timestamp)
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": session,
        "turn_id": turn,
        "cwd": cwd,
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_use_id": toolUseID,
        "tool_input": ["command": "swift test --filter InboxTests"],
        "timestamp": timestamp
    ])
    return try CodexHookEventParser(
        now: { date },
        source: .visualStudioCode
    ).parse(payload)
}

private func inboxPlanEvent(
    timestamp: TimeInterval,
    session: String = "session-A",
    turn: String = "turn-1",
    cwd: String = "/tmp/project-alpha"
) throws -> CodexHookEvent {
    let date = Date(timeIntervalSince1970: timestamp)
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": session,
        "turn_id": turn,
        "cwd": cwd,
        "hook_event_name": "PreToolUse",
        "tool_name": "update_plan",
        "tool_use_id": "tool-plan-inbox",
        "tool_input": [
            "plan": [
                ["step": "Inspect", "status": "completed"],
                ["step": "Private transient plan", "status": "in_progress"],
                ["step": "Verify", "status": "pending"]
            ]
        ],
        "timestamp": timestamp
    ])
    return try CodexHookEventParser(
        now: { date },
        source: .visualStudioCode
    ).parse(payload)
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexBarTests-\(UUID().uuidString)", isDirectory: true)
}
