import CodexBarCore
import Foundation

@main
@MainActor
struct GitWorkspaceBrowserIntegrationChecks {
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-workspace-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let root = temporary.resolvingSymlinksInPath().appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], in: root)
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "Initial"], in: root)
        try git(["branch", "dev"], in: root)
        let registry = temporary.appendingPathComponent("workspaces.json")
        let suite = "CodexBar.workspace-integration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = GitWorkspaceBrowserModel(service: GitWorkspaceService(storageURL: registry), defaults: defaults)
        model.start()
        defer { model.stop() }
        await model.addProject(root)
        precondition(model.errorMessage == nil && model.activeDirectory == root.path)
        let a = root.deletingLastPathComponent().appendingPathComponent("A")
        let b = root.deletingLastPathComponent().appendingPathComponent("B")
        let c = root.deletingLastPathComponent().appendingPathComponent("C")
        let d = root.deletingLastPathComponent().appendingPathComponent("D")
        for (source, destination, branch) in [(root, a, "a"), (root, b, "b"), (a, c, "c"), (a, d, "d")] {
            await model.createWorktree(from: source.path, at: destination, branch: branch)
            precondition(model.errorMessage == nil && model.activeDirectory == destination.path)
        }
        let expectedRecords = model.snapshot.records
        precondition(model.rows.map(\.id) == [root.path, a.path, c.path, d.path, b.path])
        precondition(model.rows.map(\.depth) == [0, 1, 2, 2, 1])
        model.selectDirectory(root.path)
        await model.switchBranch("dev")
        precondition(model.errorMessage == nil && model.activeIdentity?.branch == "dev")
        precondition(model.snapshot.records == expectedRecords, "Switching the root changed directory ancestry")
        try git(["switch", "main"], in: root)
        try await eventually("external branch refresh") { model.activeIdentity?.branch == "main" }
        precondition(model.snapshot.records == expectedRecords, "External branch switch changed directory ancestry")
        let sources = c.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        model.followDirectory(sources.path)
        try await eventually("follow active subdirectory") { model.activeDirectory == c.path }
        try await eventually("load active branches") { model.branches.contains("c") }
        precondition(model.activeIdentity?.branch == "c")
        let restored = GitWorkspaceBrowserModel(service: GitWorkspaceService(storageURL: registry), defaults: defaults)
        restored.start()
        defer { restored.stop() }
        try await eventually("restore persisted directories") { restored.snapshot.records.count == 5 }
        precondition(restored.snapshot.records == expectedRecords && restored.activeDirectory == c.path)
        print("PASS native browser with real Git: A/B/C/D creation, branch switching, live refresh, active directory and restart persistence")
    }

    static func eventually(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Native Git browser integration timed out: \(description)")
    }

    static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Git fixture setup failed")
    }
}
