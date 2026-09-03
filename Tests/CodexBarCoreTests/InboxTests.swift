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

            try expect(processedCount == 4, "processor did not consume the activity event")
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
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path).isEmpty,
                "processed activity remained in Inbox"
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
            try expect(!taskSnapshot.contains("PreToolUse"), "activity event leaked into tasks.json")
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
    turn: String = "turn-1"
) -> CodexHookEvent {
    CodexHookEvent(
        id: "event-\(name.rawValue)-\(timestamp)",
        sessionID: session,
        turnID: turn,
        cwd: "/tmp/project-alpha",
        name: name,
        promptSummary: name == .userPromptSubmit ? "Test inbox" : nil,
        toolName: nil,
        timestamp: Date(timeIntervalSince1970: timestamp),
        lastAssistantMessagePresent: false
    )
}

private func inboxActionEvent(timestamp: TimeInterval) throws -> CodexHookEvent {
    let date = Date(timeIntervalSince1970: timestamp)
    let payload = try JSONSerialization.data(withJSONObject: [
        "session_id": "session-A",
        "turn_id": "turn-1",
        "cwd": "/tmp/project-alpha",
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_use_id": "tool-test-1",
        "tool_input": ["command": "swift test --filter InboxTests"],
        "timestamp": timestamp
    ])
    return try CodexHookEventParser(now: { date }).parse(payload)
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexBarTests-\(UUID().uuidString)", isDirectory: true)
}
