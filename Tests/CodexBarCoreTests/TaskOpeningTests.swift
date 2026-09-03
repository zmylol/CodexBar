import Foundation
import CodexBarCore
import CodexBarWindowing

@MainActor
func taskOpeningTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "detects the task destination from the hook originator") {
            let key = "CODEX_INTERNAL_ORIGINATOR_OVERRIDE"

            try expect(
                CodexTaskDestination.fromHookEnvironment([key: "codex_vscode"]) == .visualStudioCode,
                "VS Code originator was not detected"
            )
            for originator in ["Codex", "Codex Desktop", "codex_work_desktop"] {
                try expect(
                    CodexTaskDestination.fromHookEnvironment([key: originator]) == .codexDesktop,
                    "desktop originator \(originator) was not detected"
                )
            }
            try expect(
                CodexTaskDestination.fromHookEnvironment([key: "future-client"]) == nil,
                "an unknown originator was assigned to a client"
            )
            try expect(
                CodexTaskDestination.fromHookEnvironment([:]) == nil,
                "a missing originator was assigned to a client"
            )
        },
        CodexBarTestCase(name: "persists a detected desktop destination on hook events") {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let input = Data(#"{"session_id":"018f0000-0000-7000-8000-000000000001","turn_id":"turn-1","cwd":"/tmp/project","hook_event_name":"UserPromptSubmit","prompt":"Open me"}"#.utf8)

            let event = try CodexHookEventParser(
                now: { now },
                destination: .codexDesktop
            ).parse(input)
            let encoded = try JSONEncoder.codexBar.encode(event)
            let decoded = try JSONDecoder.codexBar.decode(CodexHookEvent.self, from: encoded)

            try expect(decoded.destination == .codexDesktop, "event lost its desktop destination")
        },
        CodexBarTestCase(name: "loads legacy tasks without inventing a destination") {
            let legacyJSON = Data(#"{"cwd":"/tmp/project","id":"session:turn","isUnread":false,"sessionID":"session","startedAt":"2026-01-01T00:00:00.000Z","status":"running","title":"Legacy","turnID":"turn","updatedAt":"2026-01-01T00:00:00.000Z","workspaceName":"project"}"#.utf8)

            let task = try JSONDecoder.codexBar.decode(CodexTask.self, from: legacyJSON)

            try expect(task.destination == nil, "legacy task was incorrectly assigned to a client")
        },
        CodexBarTestCase(name: "updates a task destination when work continues in another client") {
            let store = TaskStore()
            let first = openingEvent(
                id: "first",
                timestamp: 1_700_000_000,
                destination: .visualStudioCode
            )
            let second = openingEvent(
                id: "second",
                timestamp: 1_700_000_001,
                destination: .codexDesktop
            )

            _ = try await store.apply(first)
            _ = try await store.apply(second)

            let task = try require(store.tasks.first, "task was not created")
            try expect(task.destination == .codexDesktop, "latest client did not become the destination")
        },
        CodexBarTestCase(name: "builds an exact Codex desktop thread link") {
            let sessionID = "018f0000-0000-7000-8000-000000000001"

            try expect(
                CodexDesktopThreadLink.make(sessionID: sessionID)?.absoluteString
                    == "codex://threads/\(sessionID)",
                "thread link did not preserve the exact session ID"
            )
            try expect(
                CodexDesktopThreadLink.make(sessionID: "../settings") == nil,
                "unsafe session ID was accepted"
            )
        },
        CodexBarTestCase(name: "desktop activator targets only the verified Codex app") {
            let appURL = URL(fileURLWithPath: "/Applications/ChatGPT.app")
            var openedURLs: [URL] = []
            let activator = CodexDesktopTaskActivator(
                applicationURLProvider: { appURL },
                signatureValidator: { $0 == appURL },
                urlOpener: { threadURL, selectedAppURL in
                    guard selectedAppURL == appURL else {
                        return false
                    }
                    openedURLs.append(threadURL)
                    return true
                }
            )

            let result = await activator.openThread(
                sessionID: "018f0000-0000-7000-8000-000000000001"
            )

            try expect(result == .opened, "verified Codex app did not open")
            try expect(
                openedURLs.map(\.absoluteString)
                    == ["codex://threads/018f0000-0000-7000-8000-000000000001"],
                "desktop activator did not send the exact thread link"
            )
        },
        CodexBarTestCase(name: "desktop activator rejects an unverified app") {
            var attemptedOpen = false
            let activator = CodexDesktopTaskActivator(
                applicationURLProvider: { URL(fileURLWithPath: "/Applications/Fake.app") },
                signatureValidator: { _ in false },
                urlOpener: { _, _ in
                    attemptedOpen = true
                    return true
                }
            )

            let result = await activator.openThread(
                sessionID: "018f0000-0000-7000-8000-000000000001"
            )

            try expect(result == .untrustedApplication, "unverified app was not rejected")
            try expect(!attemptedOpen, "unverified app received the thread link")
        },
        CodexBarTestCase(name: "routes a known desktop task by session ID only") {
            let vscode = FakeVSCodeTaskActivator(result: .applicationNotRunning)
            let desktop = FakeCodexDesktopTaskActivator(result: .opened)
            let opener = CodexTaskOpener(
                visualStudioCodeActivator: vscode,
                codexDesktopActivator: desktop
            )
            let task = openingTask(destination: .codexDesktop)

            let result = await opener.open(task)

            try expect(result == .codexDesktop(.opened), "desktop task was not opened in Codex")
            try expect(vscode.cwds.isEmpty, "desktop task attempted VS Code activation")
            try expect(desktop.sessionIDs == [task.sessionID], "wrong desktop thread was opened")
        },
        CodexBarTestCase(name: "keeps known VS Code tasks on the existing window path") {
            let descriptor = VSCodeWindowDescriptor(id: 1, title: "project — Visual Studio Code")
            let vscode = FakeVSCodeTaskActivator(result: .activated(descriptor))
            let desktop = FakeCodexDesktopTaskActivator(result: .opened)
            let opener = CodexTaskOpener(
                visualStudioCodeActivator: vscode,
                codexDesktopActivator: desktop
            )
            let task = openingTask(destination: .visualStudioCode)

            let result = await opener.open(task)

            try expect(
                result == .visualStudioCode(.activated(descriptor)),
                "VS Code result was not preserved"
            )
            try expect(vscode.cwds == [task.cwd], "VS Code task did not use its cwd")
            try expect(desktop.sessionIDs.isEmpty, "VS Code task attempted desktop activation")
        },
        CodexBarTestCase(name: "legacy task falls back to its exact desktop thread") {
            let vscode = FakeVSCodeTaskActivator(result: .windowNotFound)
            let desktop = FakeCodexDesktopTaskActivator(result: .opened)
            let opener = CodexTaskOpener(
                visualStudioCodeActivator: vscode,
                codexDesktopActivator: desktop
            )
            let task = openingTask(destination: nil)

            let result = await opener.open(task)

            try expect(result == .codexDesktop(.opened), "legacy desktop task did not fall back")
            try expect(vscode.cwds == [task.cwd], "legacy task skipped the existing VS Code path")
            try expect(desktop.sessionIDs == [task.sessionID], "fallback opened the wrong thread")
        }
    ]
}

private func openingEvent(
    id: String,
    timestamp: TimeInterval,
    destination: CodexTaskDestination
) -> CodexHookEvent {
    CodexHookEvent(
        id: id,
        sessionID: "018f0000-0000-7000-8000-000000000001",
        turnID: "turn-1",
        cwd: "/tmp/project",
        name: .userPromptSubmit,
        promptSummary: "Open me",
        toolName: nil,
        timestamp: Date(timeIntervalSince1970: timestamp),
        lastAssistantMessagePresent: false,
        destination: destination
    )
}

private func openingTask(destination: CodexTaskDestination?) -> CodexTask {
    CodexTask(
        id: "018f0000-0000-7000-8000-000000000001:turn-1",
        sessionID: "018f0000-0000-7000-8000-000000000001",
        turnID: "turn-1",
        cwd: "/tmp/project",
        workspaceName: "project",
        title: "Open me",
        status: .ready,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
        isUnread: true,
        destination: destination
    )
}

@MainActor
private final class FakeVSCodeTaskActivator: VSCodeTaskActivating {
    let result: VSCodeWindowActivationResult
    var cwds: [String] = []

    init(result: VSCodeWindowActivationResult) {
        self.result = result
    }

    func activateWindow(
        forCWD cwd: String,
        promptForAccessibility: Bool
    ) async -> VSCodeWindowActivationResult {
        cwds.append(cwd)
        return result
    }
}

@MainActor
private final class FakeCodexDesktopTaskActivator: CodexDesktopTaskActivating {
    let result: CodexDesktopTaskActivationResult
    var sessionIDs: [String] = []

    init(result: CodexDesktopTaskActivationResult) {
        self.result = result
    }

    func openThread(sessionID: String) async -> CodexDesktopTaskActivationResult {
        sessionIDs.append(sessionID)
        return result
    }
}
