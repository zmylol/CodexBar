import CodexBarCore
import CoreServices
import Foundation

@MainActor
func sessionCreationMonitoringTests() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "session creation filtering deduplicates retained creation flags and renamed rollouts") {
            let root = try sessionMonitorFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let sessions = root.appendingPathComponent("sessions")
            var filter = CodexSessionCreationFilter(sessions: sessions, startedAt: Date().addingTimeInterval(-1))
            let file = try writeSessionMonitorFixture("sessions/2026/09/19/rollout-one.jsonl", root: root)
            let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            let changed = created | UInt32(kFSEventStreamEventFlagItemModified)
            try expect(filter.accepts(path: file.path, flags: created), "new rollout did not request discovery")
            try expect(!filter.accepts(path: file.path, flags: changed), "retained creation flags repeated discovery")
            let renamed = file.deletingLastPathComponent().appendingPathComponent("rollout-renamed.jsonl")
            try FileManager.default.moveItem(at: file, to: renamed)
            let rename = UInt32(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
            try expect(!filter.accepts(path: renamed.path, flags: rename), "renaming an already observed rollout repeated discovery")
            let published = try writeSessionMonitorFixture("sessions/2026/09/19/.pending", root: root)
            let destination = published.deletingLastPathComponent().appendingPathComponent("rollout-two.jsonl")
            try FileManager.default.moveItem(at: published, to: destination)
            try expect(filter.accepts(path: destination.path, flags: rename), "a newly published renamed rollout was ignored")
        },
        CodexBarTestCase(name: "session creation filtering ignores existing files appends and unrelated paths") {
            let root = try sessionMonitorFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let existing = try writeSessionMonitorFixture("sessions/2026/09/19/rollout-existing.jsonl", root: root)
            try await Task.sleep(for: .milliseconds(20))
            var filter = CodexSessionCreationFilter(sessions: root.appendingPathComponent("sessions"), startedAt: Date())
            let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            try expect(!filter.accepts(path: existing.path, flags: created), "preexisting session triggered discovery")
            let file = try writeSessionMonitorFixture("sessions/2026/09/19/rollout-current.jsonl", root: root)
            let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
            try expect(!filter.accepts(path: existing.path, flags: modified), "old session append triggered discovery")
            try expect(filter.accepts(path: file.path, flags: modified), "a new file with a coalesced creation event was missed")
            for path in ["sessions-backup/rollout-other.jsonl", "sessions/notes.jsonl", "sessions/rollout-other.txt"] {
                let unrelated = try writeSessionMonitorFixture(path, root: root)
                try expect(!filter.accepts(path: unrelated.path, flags: created), "unrelated path triggered discovery")
            }
            let link = file.deletingLastPathComponent().appendingPathComponent("rollout-link.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            try expect(!filter.accepts(path: link.path, flags: created), "symbolic link was treated as a new session")
        },
        CodexBarTestCase(name: "session creation monitor observes new date directories without repeating on appends") {
            let root = try sessionMonitorFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let home = root.appendingPathComponent("missing-home")
            let monitor = CodexSessionCreationMonitor(codexHome: home)
            var changes = 0
            try await monitor.start { candidates in
                changes += 1
                monitor.acknowledge(sessionIDs: Set(candidates.map(\.sessionID)))
            }
            defer { monitor.stop() }
            try await Task.sleep(for: .milliseconds(200))
            try expect(changes == 0, "starting a monitor triggered an unsolicited scan")
            let file = try writeSessionMonitorFixture("sessions/2026/09/19/rollout-first.jsonl", root: home)
            _ = try writeSessionMonitorFixture("sessions/2026/09/19/rollout-second.jsonl", root: home)
            try await waitForSessionMonitor { changes > 0 }
            try await Task.sleep(for: .milliseconds(400))
            try expect(changes == 1, "one creation burst was not coalesced")
            for _ in 0..<3 {
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data("fixture append\n".utf8))
                try handle.close()
                try await Task.sleep(for: .milliseconds(300))
            }
            try expect(changes == 1, "rollout append repeated session discovery")
            _ = try writeSessionMonitorFixture("sessions/2026/09/20/rollout-next-day.jsonl", root: home)
            try await waitForSessionMonitor { changes == 2 }
            monitor.stop()
            _ = try writeSessionMonitorFixture("sessions/2026/09/20/rollout-after-stop.jsonl", root: home)
            try await Task.sleep(for: .milliseconds(400))
            try expect(changes == 2, "stopped monitor delivered an old callback")
            var restartedChanges = 0
            try await monitor.start { candidates in
                restartedChanges += 1
                monitor.acknowledge(sessionIDs: Set(candidates.map(\.sessionID)))
            }
            try FileManager.default.moveItem(at: home, to: root.appendingPathComponent("old-home"))
            _ = try writeSessionMonitorFixture("sessions/2026/09/20/rollout-replaced-home.jsonl", root: home)
            try await waitForSessionMonitor { restartedChanges == 1 }
            _ = try writeSessionMonitorFixture("sessions/2026/09/20/rollout-restarted.jsonl", root: home)
            monitor.stop()
            try await Task.sleep(for: .milliseconds(400))
            try expect(restartedChanges == 1, "stop did not cancel pending delivery after restart")
        },
        CodexBarTestCase(name: "pending session headers and delayed first turns retry only until acknowledged") {
            let root = try sessionMonitorFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var tracker = CodexSessionCreationTracker(sessions: root.appendingPathComponent("sessions"), startedAt: Date().addingTimeInterval(-1))
            let file = try writeSessionMonitorFixture("sessions/rollout-pending.jsonl", root: root)
            try Data().write(to: file)
            let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
            try expect(tracker.receive(path: file.path, flags: created) == nil, "incomplete header produced a candidate")
            let id = UUID().uuidString.lowercased()
            try sessionMonitorHeader(id: id).write(to: file)
            let candidate = try require(tracker.receive(path: file.path, flags: modified), "completed header did not retry discovery")
            try expect(candidate.sessionID == id, "header identity was lost")
            try expect(tracker.receive(path: file.path, flags: modified) == candidate, "delayed first turn stopped discovery too early")
            tracker.acknowledge(sessionIDs: [id])
            try expect(tracker.receive(path: file.path, flags: modified | created) == nil, "acknowledged session retriggered on append")
            let ignored = try writeSessionMonitorFixture("sessions/rollout-cli.jsonl", root: root)
            try sessionMonitorHeader(id: UUID().uuidString, source: "cli").write(to: ignored)
            try expect(tracker.receive(path: ignored.path, flags: created) == nil, "CLI session entered discovery")
            try expect(tracker.receive(path: ignored.path, flags: modified | created) == nil, "ignored CLI session reentered discovery")
        },
        CodexBarTestCase(name: "session creation recovery signals remain scoped to the session tree") {
            let root = try sessionMonitorFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let filter = CodexSessionCreationFilter(sessions: root.appendingPathComponent("sessions"), startedAt: Date())
            let dropped = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped)
            try expect(filter.needsRecovery(path: root.path, flags: dropped), "ancestor event loss was ignored")
            try expect(filter.needsRecovery(path: root.appendingPathComponent("sessions/2026").path, flags: dropped), "nested event loss was ignored")
            try expect(!filter.needsRecovery(path: root.appendingPathComponent("unrelated").path, flags: dropped), "unrelated tree caused recovery")
        },
        CodexBarTestCase(name: "pending session creation tracking has a fixed capacity released by acknowledgment") {
            let root = try sessionMonitorFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var tracker = CodexSessionCreationTracker(sessions: root.appendingPathComponent("sessions"), startedAt: Date().addingTimeInterval(-1))
            let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            var first: URL?
            for index in 0..<512 {
                let file = try writeSessionMonitorFixture("sessions/rollout-\(index).jsonl", root: root)
                try Data().write(to: file)
                if first == nil { first = file }
                try expect(tracker.receive(path: file.path, flags: created) == nil, "incomplete candidate escaped")
            }
            let overflow = try writeSessionMonitorFixture("sessions/rollout-overflow.jsonl", root: root)
            try expect(tracker.receive(path: overflow.path, flags: created) == nil, "pending capacity was exceeded")
            let firstFile = try require(first, "missing first fixture")
            let id = UUID().uuidString.lowercased()
            try sessionMonitorHeader(id: id).write(to: firstFile)
            try expect(tracker.receive(path: firstFile.path, flags: created)?.sessionID == id, "existing pending slot was lost")
            tracker.acknowledge(sessionIDs: [id])
            let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
            try expect(tracker.receive(path: overflow.path, flags: modified) != nil, "an overflow file remained ignored after capacity was released")
        },
        CodexBarTestCase(name: "session acknowledgment before header completion releases the pending candidate") {
            let root = try sessionMonitorFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            var tracker = CodexSessionCreationTracker(sessions: root.appendingPathComponent("sessions"), startedAt: Date().addingTimeInterval(-1))
            let file = try writeSessionMonitorFixture("sessions/rollout-incomplete.jsonl", root: root)
            try Data().write(to: file)
            let created = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
            let modified = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
            try expect(tracker.receive(path: file.path, flags: created) == nil, "empty header produced a candidate")
            let id = UUID().uuidString.lowercased()
            tracker.acknowledge(sessionIDs: [id])
            try sessionMonitorHeader(id: id).write(to: file)
            try expect(tracker.receive(path: file.path, flags: modified) == nil, "already acknowledged metadata remained pending")
            try expect(tracker.receive(path: file.path, flags: modified | created) == nil, "acknowledged candidate reappeared on later appends")
            let next = try writeSessionMonitorFixture("sessions/rollout-next.jsonl", root: root)
            try expect(tracker.receive(path: next.path, flags: created) != nil, "acknowledgment did not release capacity")
        }
    ]
}

private func sessionMonitorFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarSessionMonitor-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@discardableResult
private func writeSessionMonitorFixture(_ path: String, root: URL) throws -> URL {
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try sessionMonitorHeader(id: UUID().uuidString.lowercased()).write(to: file)
    return file
}

private func sessionMonitorHeader(id: String, source: String = "vscode") throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/fixture-project", "source": source]])
    data.append(0x0A)
    return data
}

@MainActor
private func waitForSessionMonitor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try expect(condition(), "session creation notification did not arrive")
}
