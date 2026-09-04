import Foundation
import CodexBarCore

@MainActor
func taskOpeningTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "accepts only the exact VS Code hook originator") {
            let key = "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"

            try expect(
                CodexHookSource.fromHookEnvironment([key: "codex_vscode"])
                    == .visualStudioCode,
                "exact VS Code originator was not accepted"
            )
            for originator in [
                "Codex",
                "Codex Desktop",
                "codex_work_desktop",
                "codex_cli",
                "future-client",
                " codex_vscode ",
                "CODEX_VSCODE"
            ] {
                try expect(
                    CodexHookSource.fromHookEnvironment([key: originator]) == nil,
                    "unsupported originator \(originator) was accepted"
                )
            }
            try expect(
                CodexHookSource.fromHookEnvironment([:]) == nil,
                "a missing originator was accepted"
            )
        },
        CodexBarTestCase(name: "decodes new and legacy VS Code source markers") {
            let newEvent = try JSONDecoder.codexBar.decode(
                CodexHookEvent.self,
                from: try encodedEvent(id: "new", sourceField: "source", sourceValue: "vscode")
            )
            let legacyEvent = try JSONDecoder.codexBar.decode(
                CodexHookEvent.self,
                from: try encodedEvent(id: "legacy", sourceField: "destination", sourceValue: "vscode")
            )

            try expect(newEvent.source == .visualStudioCode, "new source marker was lost")
            try expect(legacyEvent.source == .visualStudioCode, "legacy VS Code marker was lost")
        },
        CodexBarTestCase(name: "drops queued events that are not proven to come from VS Code") {
            let root = temporaryVSCodeBoundaryDirectory("QueueMigration")
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = CodexBarPaths(rootDirectory: root)
            try paths.prepareEventDirectories()
            let fixtures = [
                ("01-new.json", try encodedEvent(id: "new", sourceField: "source", sourceValue: "vscode")),
                ("02-legacy.json", try encodedEvent(id: "legacy", sourceField: "destination", sourceValue: "vscode")),
                ("03-desktop.json", try encodedEvent(id: "desktop", sourceField: "destination", sourceValue: "codexDesktop")),
                ("04-cli.json", try encodedEvent(id: "cli", sourceField: "destination", sourceValue: nil))
            ]
            for (filename, data) in fixtures {
                try data.write(to: paths.inbox.appendingPathComponent(filename))
            }

            let pending = try CodexHookEventSource(paths: paths).pendingEvents()

            try expect(
                pending.map(\.event.id) == ["new", "legacy"],
                "queue exposed events without a VS Code source marker"
            )
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path).sorted()
                    == ["01-new.json", "02-legacy.json"],
                "discarded queue files were retained"
            )
            try expect(
                try FileManager.default.contentsOfDirectory(atPath: paths.failed.path).isEmpty,
                "unsupported events were retained as failures"
            )
        },
        CodexBarTestCase(name: "loads mixed legacy state as VS Code-only schema v2") {
            let root = temporaryVSCodeBoundaryDirectory("TaskMigration")
            let persistenceURL = root.appendingPathComponent("tasks.json")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try legacyTaskSnapshot().write(to: persistenceURL)

            let store = TaskStore(persistenceURL: persistenceURL)
            await store.load()

            try expect(
                store.tasks.map(\.sessionID) == ["vscode-session"],
                "old non-VS-Code tasks remained visible"
            )
            let migrated = try require(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: persistenceURL)
                ) as? [String: Any],
                "migrated snapshot is not an object"
            )
            try expect(migrated["schemaVersion"] as? Int == 2, "snapshot was not upgraded to v2")
            let migratedTasks = try require(
                migrated["tasks"] as? [[String: Any]],
                "migrated snapshot has no tasks"
            )
            try expect(migratedTasks.count == 1, "non-VS-Code tasks remain persisted")
            try expect(
                migratedTasks.allSatisfy { $0["destination"] == nil && $0["source"] == nil },
                "v2 task state still persists per-client routing"
            )
            try expect(
                migrated["appliedEventIDs"] as? [String] == ["old-event"],
                "migration changed applied event IDs"
            )
        },
        CodexBarTestCase(name: "production sources contain no Codex desktop integration") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourcesRoot = repositoryRoot.appendingPathComponent("Sources", isDirectory: true)
            let sourcePaths = try FileManager.default.subpathsOfDirectory(
                atPath: sourcesRoot.path
            ).filter { $0.hasSuffix(".swift") }
            let forbiddenMarkers = ["CodexDesktop", "com.openai.codex", "codex://threads"]
            var offenders: [String] = []
            for path in sourcePaths {
                let url = sourcesRoot.appendingPathComponent(path)
                let source = try String(contentsOf: url, encoding: .utf8)
                if forbiddenMarkers.contains(where: source.contains) {
                    offenders.append(path)
                }
            }

            try expect(
                offenders.isEmpty,
                "Codex desktop integration remains in: \(offenders.sorted().joined(separator: ", "))"
            )
        }
    ]
}

private func encodedEvent(
    id: String,
    sourceField: String,
    sourceValue: String?
) throws -> Data {
    var event: [String: Any] = [
        "id": id,
        "sessionID": "\(id)-session",
        "turnID": "turn-1",
        "cwd": "/tmp/\(id)-project",
        "name": "UserPromptSubmit",
        "timestamp": "2026-09-01T00:00:00.000Z",
        "lastAssistantMessagePresent": false
    ]
    if let sourceValue {
        event[sourceField] = sourceValue
    }
    return try JSONSerialization.data(withJSONObject: event)
}

private func legacyTaskSnapshot() throws -> Data {
    let tasks: [[String: Any]] = [
        legacyTask(
            session: "vscode-session",
            cwd: "/tmp/vscode-project",
            destination: "vscode"
        ),
        legacyTask(
            session: "desktop-session",
            cwd: "/tmp/desktop-project",
            destination: "codexDesktop"
        ),
        legacyTask(
            session: "unknown-session",
            cwd: "/tmp/unknown-project",
            destination: nil
        )
    ]
    return try JSONSerialization.data(withJSONObject: [
        "tasks": tasks,
        "appliedEventIDs": ["old-event"],
        "deletedTaskTombstones": []
    ])
}

private func legacyTask(
    session: String,
    cwd: String,
    destination: String?
) -> [String: Any] {
    var task: [String: Any] = [
        "id": "\(session):turn-1",
        "sessionID": session,
        "turnID": "turn-1",
        "cwd": cwd,
        "workspaceName": URL(fileURLWithPath: cwd).lastPathComponent,
        "title": "Legacy task",
        "status": "running",
        "startedAt": "2026-09-01T00:00:00.000Z",
        "updatedAt": "2026-09-01T00:00:00.000Z",
        "isUnread": false
    ]
    if let destination {
        task["destination"] = destination
    }
    return task
}

private func temporaryVSCodeBoundaryDirectory(_ suffix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodexBarVSCodeOnly\(suffix)-\(UUID().uuidString)",
        isDirectory: true
    )
}
