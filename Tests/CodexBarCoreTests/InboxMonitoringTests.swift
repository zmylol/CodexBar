import Foundation
import CodexBarCore

@MainActor
func inboxMonitoringTests() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "inbox monitor reports published Inbox and Activity files without idle callbacks") {
            let paths = try monitoringPaths()
            defer { try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent()) }
            try Data("before".utf8).write(to: paths.inbox.appendingPathComponent("before.json"))
            let monitor = CodexInboxMonitor(paths: paths)
            let changes = InboxChanges()
            try monitor.start { changes.count += 1 }
            defer { monitor.stop() }

            try await Task.sleep(for: .milliseconds(950))
            try expect(changes.count == 0, "idle monitoring invoked the processing callback")
            try expect(
                FileManager.default.fileExists(atPath: paths.inbox.appendingPathComponent("before.json").path),
                "monitor consumed the event that initial processing must handle"
            )

            try Data("after".utf8).write(to: paths.inbox.appendingPathComponent("after.json"), options: .atomic)
            try await awaitInboxChange(changes, after: 0)
            try await Task.sleep(for: .milliseconds(120))
            let inboxCount = changes.count
            try Data("activity".utf8).write(to: paths.activity.appendingPathComponent("activity.json"), options: .atomic)
            try await awaitInboxChange(changes, after: inboxCount)
            try await Task.sleep(for: .milliseconds(120))
            let settledCount = changes.count
            try Data("saved tasks".utf8).write(to: paths.taskStore, options: .atomic)
            try await Task.sleep(for: .milliseconds(950))
            try expect(changes.count == settledCount, "idle monitoring or task persistence re-triggered event processing")
        },
        CodexBarTestCase(name: "inbox monitor catches a temporary file published by rename") {
            let paths = try monitoringPaths()
            defer { try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent()) }
            let temporary = paths.inbox.appendingPathComponent(".event.tmp")
            try Data("event".utf8).write(to: temporary)
            let monitor = CodexInboxMonitor(paths: paths)
            let changes = InboxChanges()
            try monitor.start { changes.count += 1 }
            defer { monitor.stop() }

            try FileManager.default.moveItem(at: temporary, to: paths.inbox.appendingPathComponent("event.json"))
            try await awaitInboxChange(changes, after: 0)
        },
        CodexBarTestCase(name: "inbox monitor reattaches after event directories and storage root are replaced") {
            let paths = try monitoringPaths()
            defer { try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent()) }
            let monitor = CodexInboxMonitor(paths: paths)
            let changes = InboxChanges()
            try monitor.start { changes.count += 1 }
            defer { monitor.stop() }

            for directory in [paths.inbox, paths.activity, paths.rootDirectory] {
                try FileManager.default.removeItem(at: directory)
                try await Task.sleep(for: .milliseconds(100))
                try paths.prepareEventDirectories()
                try Data("first".utf8).write(to: paths.activity.appendingPathComponent("first.json"), options: .atomic)
                let before = changes.count
                try await awaitInboxChange(changes, after: before)
                try await Task.sleep(for: .milliseconds(120))
                let reattached = changes.count
                try Data("later".utf8).write(to: paths.inbox.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
                try await awaitInboxChange(changes, after: reattached)
            }
        },
        CodexBarTestCase(name: "inbox monitor stops pending delivery and restarts without stale callbacks") {
            let paths = try monitoringPaths()
            defer { try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent()) }
            let monitor = CodexInboxMonitor(paths: paths)
            let oldChanges = InboxChanges()
            try monitor.start { oldChanges.count += 1 }
            try Data().write(to: paths.inbox.appendingPathComponent("old.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(10))
            monitor.stop()
            try await Task.sleep(for: .milliseconds(120))
            try expect(oldChanges.count == 0, "stop delivered a queued callback")

            let newChanges = InboxChanges()
            try monitor.start { newChanges.count += 1 }
            defer { monitor.stop() }
            try Data().write(to: paths.activity.appendingPathComponent("new.json"), options: .atomic)
            try await awaitInboxChange(newChanges, after: 0)
            try expect(oldChanges.count == 0, "restart invoked the previous callback")
        },
        CodexBarTestCase(name: "inbox monitor rejects a symlink and resumes when a real directory replaces it") {
            let paths = try monitoringPaths()
            defer { try? FileManager.default.removeItem(at: paths.rootDirectory.deletingLastPathComponent()) }
            let outside = paths.rootDirectory.deletingLastPathComponent().appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let monitor = CodexInboxMonitor(paths: paths)
            let changes = InboxChanges()
            try monitor.start { changes.count += 1 }
            defer { monitor.stop() }

            try FileManager.default.removeItem(at: paths.inbox)
            try FileManager.default.createSymbolicLink(at: paths.inbox, withDestinationURL: outside)
            try await Task.sleep(for: .milliseconds(200))
            let beforeOutsideWrite = changes.count
            try Data().write(to: outside.appendingPathComponent("outside.json"), options: .atomic)
            try await Task.sleep(for: .milliseconds(200))
            try expect(changes.count == beforeOutsideWrite, "monitor followed a replaced directory symlink")

            try FileManager.default.removeItem(at: paths.inbox)
            try paths.prepareEventDirectories()
            try await Task.sleep(for: .milliseconds(200))
            let beforeRealWrite = changes.count
            try Data().write(to: paths.inbox.appendingPathComponent("real.json"), options: .atomic)
            try await awaitInboxChange(changes, after: beforeRealWrite)
        }
    ]
}

@MainActor
private final class InboxChanges {
    var count = 0
}

private func monitoringPaths() throws -> CodexBarPaths {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexBarMonitorTests-\(UUID().uuidString)", isDirectory: true)
    let paths = CodexBarPaths(rootDirectory: parent.appendingPathComponent("storage", isDirectory: true))
    try paths.prepareEventDirectories()
    return paths
}

@MainActor
private func awaitInboxChange(_ changes: InboxChanges, after count: Int) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while changes.count <= count && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expect(changes.count > count, "filesystem change did not invoke the processing callback")
}
