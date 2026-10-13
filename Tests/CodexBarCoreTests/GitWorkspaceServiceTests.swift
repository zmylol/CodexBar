import CodexBarCore
import Darwin
import Foundation

func gitWorkspaceServiceTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "Git service persists directory ancestry while root and child branches change") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main.appendingPathComponent("src"))
            let a = fixture.root.appendingPathComponent("worktree A")
            let b = fixture.root.appendingPathComponent("worktree B")
            let c = fixture.root.appendingPathComponent("worktree C")
            let d = fixture.root.appendingPathComponent("worktree D")
            _ = try await service.createWorktree(from: fixture.main.path, at: a, branch: "a")
            _ = try await service.createWorktree(from: fixture.main.path, at: b, branch: "b")
            try "parent-specific commit\n".write(to: a.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            try fixture.git(["-C", a.path, "commit", "-am", "parent-specific commit"])
            _ = try await service.createWorktree(from: a.path, at: c, branch: "c")
            try expect(fixture.gitOutput(["-C", c.path, "rev-parse", "HEAD"]) == fixture.gitOutput(["-C", a.path, "rev-parse", "HEAD"]), "child did not start from its selected directory's commit")
            let initial = try await service.createWorktree(from: a.path, at: d, branch: "d")
            try fixture.git(["branch", "dev"])
            try fixture.git(["branch", "feature-x"])
            _ = try await service.switchBranch(in: fixture.main.path, to: "dev")
            let changed = try await service.switchBranch(in: a.path, to: "feature-x")
            try expect(initial.records == changed.records, "branch switching changed directory records")
            try expect(changed.identities[fixture.main.path]?.branch == "dev", "root branch stayed stale")
            try expect(changed.identities[a.path]?.branch == "feature-x", "child branch stayed stale")
            try expect(changed.records.first { $0.workspaceRoot == c.path }?.parentWorkspaceRoot == a.path, "grandchild lost its creator")
            try expect(changed.records.first { $0.workspaceRoot == d.path }?.parentWorkspaceRoot == a.path, "sibling grandchild lost its creator")
            let restored = try await GitWorkspaceService(storageURL: fixture.storage).snapshot()
            try expect(restored == changed, "restart lost persistent ancestry")
            try expect(try await service.localBranches(in: a.path) == ["a", "b", "c", "d", "dev", "feature-x", "main"], "local branch choices are incorrect")
        },
        CodexBarTestCase(name: "Git service imports unknown worktree origins without inventing parents") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let linked = fixture.root.appendingPathComponent("external checkout")
            try fixture.git(["worktree", "add", "-b", "external", linked.path])
            let result = try await GitWorkspaceService(storageURL: fixture.storage).addProject(directory: linked)
            try expect(result.records.count == 2, "import did not discover the main checkout")
            try expect(result.records.allSatisfy { $0.parentWorkspaceRoot == nil }, "external origin was guessed")
            try expect(result.records.filter(\.isMainWorkspace).map(\.workspaceRoot) == [fixture.main.path], "main checkout role is wrong")
            try FileManager.default.moveItem(at: linked, to: fixture.root.appendingPathComponent("moved external checkout"))
            let secondStorage = fixture.storage.deletingLastPathComponent().appendingPathComponent("import-missing.json")
            let missing = try await GitWorkspaceService(storageURL: secondStorage).addProject(directory: fixture.main)
            try expect(missing.records.count == 2 && missing.identities[linked.path] == nil, "registered but missing external checkout was discarded during import")
            try expect(missing.records.first { $0.workspaceRoot == linked.path }?.parentWorkspaceRoot == nil, "missing external checkout was assigned an invented parent")
        },
        CodexBarTestCase(name: "Git service refresh discovers externally created worktrees without inventing ancestry") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            let external = fixture.root.appendingPathComponent("external after import")
            try fixture.git(["worktree", "add", "-b", "external", external.path])
            let refreshed = try await service.snapshot()
            try expect(refreshed.records.count == 2 && refreshed.identities[external.path]?.branch == "external", "refresh did not discover an external worktree")
            try expect(refreshed.records.first { $0.workspaceRoot == external.path }?.parentWorkspaceRoot == nil, "refresh guessed external creation ancestry")
            let restored = try await GitWorkspaceService(storageURL: fixture.storage).snapshot()
            try expect(restored.records == refreshed.records, "refresh discovery was not persisted")
        },
        CodexBarTestCase(name: "Git service refuses invalid branches occupied branches and dirty checkout conflicts") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            let before = try await service.addProject(directory: fixture.main)
            for branch in ["--detach", "bad name", "@{-1}", "main"] {
                do {
                    _ = try await service.createWorktree(from: fixture.main.path, at: fixture.root.appendingPathComponent("invalid"), branch: branch)
                    throw TestFailure(description: "invalid or existing branch accepted: \(branch)")
                } catch is TestFailure { throw TestFailure(description: "invalid or existing branch accepted: \(branch)") }
                catch {}
            }
            try expect(try await service.snapshot() == before, "failed creates changed metadata")
            try fixture.git(["checkout", "-b", "other"])
            try "other\n".write(to: fixture.main.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            try fixture.git(["commit", "-am", "other content"])
            try fixture.git(["checkout", "main"])
            try "local edits\n".write(to: fixture.main.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            do {
                _ = try await service.switchBranch(in: fixture.main.path, to: "other")
                throw TestFailure(description: "dirty conflict switch succeeded")
            } catch is TestFailure { throw TestFailure(description: "dirty conflict switch succeeded") }
            catch {}
            try expect(try String(contentsOf: fixture.main.appendingPathComponent("tracked.txt"), encoding: .utf8) == "local edits\n", "switch discarded local edits")
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.main.path)?.branch == "main", "failed switch changed HEAD")
            let linked = fixture.root.appendingPathComponent("linked")
            _ = try await service.createWorktree(from: fixture.main.path, at: linked, branch: "occupied")
            do {
                _ = try await service.switchBranch(in: fixture.main.path, to: "occupied")
                throw TestFailure(description: "occupied branch accepted")
            } catch is TestFailure { throw TestFailure(description: "occupied branch accepted") }
            catch {}
            do {
                _ = try await service.createWorktree(from: fixture.main.path, at: linked, branch: "duplicate")
                throw TestFailure(description: "duplicate directory accepted")
            } catch is TestFailure { throw TestFailure(description: "duplicate directory accepted") }
            catch {}
            try expect(!fixture.gitOutput(["branch", "--list", "duplicate"]).contains("duplicate"), "failed create left a branch")
        },
        CodexBarTestCase(name: "Git service rejects creating branch names its identity reader cannot display") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            let before = try await service.addProject(directory: fixture.main)
            for (index, branch) in ["@", "feature\u{00A0}test"].enumerated() {
                let destination = fixture.root.appendingPathComponent("unsupported-\(index)")
                do {
                    _ = try await service.createWorktree(from: fixture.main.path, at: destination, branch: branch)
                    throw TestFailure(description: "created an unsupported branch: \(branch)")
                } catch GitWorkspaceServiceError.invalidBranch {}
                try expect(!FileManager.default.fileExists(atPath: destination.path), "unsupported branch created a directory")
                try expect(fixture.gitOutput(["branch", "--list", branch]).isEmpty, "unsupported branch changed Git refs")
            }
            try expect(try await service.snapshot() == before, "unsupported branch changed directory records")
        },
        CodexBarTestCase(name: "Git service hides existing unsupported branch names from branch choices") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            for branch in ["@", "feature\u{00A0}test", "功能/修复"] { try fixture.git(["branch", branch]) }
            try expect(try await service.localBranches(in: fixture.main.path) == ["main", "功能/修复"], "branch choices include names that make workspace identity unavailable")
        },
        CodexBarTestCase(name: "Git service refuses switching to existing unsupported branch names") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            let before = try await service.addProject(directory: fixture.main)
            for branch in ["@", "feature\u{00A0}test"] {
                try fixture.git(["branch", branch])
                do {
                    _ = try await service.switchBranch(in: fixture.main.path, to: branch)
                    throw TestFailure(description: "switched to an unsupported branch: \(branch)")
                } catch GitWorkspaceServiceError.invalidBranch {}
                try expect(GitWorkspaceIdentityReader.read(cwd: fixture.main.path)?.branch == "main", "unsupported branch changed HEAD or made workspace unavailable")
            }
            try expect(try await service.snapshot() == before, "unsupported switch changed directory records")
        },
        CodexBarTestCase(name: "Git service never switches the ancestor when a nested worktree gitfile disappears") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            try fixture.git(["branch", "dev"])
            let child = fixture.main.appendingPathComponent("nested child")
            let before = try await service.createWorktree(from: fixture.main.path, at: child, branch: "child")
            let originalCommit = fixture.gitOutput(["rev-parse", "HEAD"])
            try FileManager.default.moveItem(at: child.appendingPathComponent(".git"), to: fixture.root.appendingPathComponent("saved-child-gitfile"))
            do {
                _ = try await service.switchBranch(in: child.path, to: "dev")
                throw TestFailure(description: "missing child gitfile allowed switching an ancestor")
            } catch GitWorkspaceServiceError.unavailableWorkspace {}
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.main.path)?.branch == "main", "rejected child operation switched the main workspace")
            try expect(fixture.gitOutput(["rev-parse", "HEAD"]) == originalCommit, "rejected child operation changed the main HEAD commit")
            try expect(try await service.snapshot().records == before.records, "missing child gitfile changed directory ancestry")
        },
        CodexBarTestCase(name: "Git service never creates from the ancestor when a nested worktree gitfile disappears") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            let child = fixture.main.appendingPathComponent("nested child")
            let before = try await service.createWorktree(from: fixture.main.path, at: child, branch: "child")
            let originalCommit = fixture.gitOutput(["rev-parse", "HEAD"])
            try FileManager.default.moveItem(at: child.appendingPathComponent(".git"), to: fixture.root.appendingPathComponent("saved-child-gitfile"))
            let destination = fixture.root.appendingPathComponent("should not be created")
            do {
                _ = try await service.createWorktree(from: child.path, at: destination, branch: "grandchild")
                throw TestFailure(description: "missing child gitfile allowed creating from an ancestor")
            } catch GitWorkspaceServiceError.unavailableWorkspace {}
            try expect(!FileManager.default.fileExists(atPath: destination.path), "rejected child operation created a worktree")
            try expect(fixture.gitOutput(["branch", "--list", "grandchild"]).isEmpty, "rejected child operation created a branch")
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.main.path)?.branch == "main", "rejected child operation changed the main branch")
            try expect(fixture.gitOutput(["rev-parse", "HEAD"]) == originalCommit, "rejected child operation changed the main HEAD commit")
            try expect(try await service.snapshot().records == before.records, "rejected child creation changed directory ancestry")
        },
        CodexBarTestCase(name: "Git service keeps an unavailable parent and its child creation record") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            let parent = fixture.root.appendingPathComponent("parent")
            let child = fixture.root.appendingPathComponent("child")
            _ = try await service.createWorktree(from: fixture.main.path, at: parent, branch: "parent")
            let before = try await service.createWorktree(from: parent.path, at: child, branch: "child")
            try FileManager.default.moveItem(at: parent, to: fixture.root.appendingPathComponent("moved externally"))
            let after = try await GitWorkspaceService(storageURL: fixture.storage).snapshot()
            try expect(after.records == before.records, "missing parent was removed or reparented: \(after.records) vs \(before.records)")
            try expect(after.identities[parent.path] == nil && after.identities[child.path] != nil, "availability is not distinct from identity")
        },
        CodexBarTestCase(name: "Git service rejects cyclic dangling and cross-repository registry parents") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            let child = fixture.root.appendingPathComponent("child")
            _ = try await service.createWorktree(from: fixture.main.path, at: child, branch: "child")
            let data = try Data(contentsOf: fixture.storage)
            let original = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "registry envelope missing")
            for corruption in ["cycle", "dangling", "cross-repository"] {
                var registry = original
                var records = try require(registry["records"] as? [[String: Any]], "registry records missing")
                if corruption == "cycle" { records[1]["parentWorkspaceRoot"] = child.path }
                if corruption == "dangling" { records[1]["parentWorkspaceRoot"] = fixture.root.appendingPathComponent("unknown").path }
                if corruption == "cross-repository" { records[1]["repositoryID"] = fixture.root.appendingPathComponent("different.git").path }
                registry["records"] = records
                let corrupted = try JSONSerialization.data(withJSONObject: registry)
                try corrupted.write(to: fixture.storage)
                do {
                    _ = try await service.snapshot()
                    throw TestFailure(description: "invalid registry accepted: \(corruption)")
                } catch is TestFailure { throw TestFailure(description: "invalid registry accepted: \(corruption)") }
                catch {}
                try expect(try Data(contentsOf: fixture.storage) == corrupted, "validation rewrote invalid registry")
            }
        },
        CodexBarTestCase(name: "Git service serializes separate instances without losing sibling records") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let first = GitWorkspaceService(storageURL: fixture.storage)
            let second = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await first.addProject(directory: fixture.main)
            async let a = first.createWorktree(from: fixture.main.path, at: fixture.root.appendingPathComponent("A"), branch: "a")
            async let b = second.createWorktree(from: fixture.main.path, at: fixture.root.appendingPathComponent("B"), branch: "b")
            _ = try await (a, b)
            let result = try await first.snapshot()
            try expect(result.records.count == 3 && result.identities.count == 3, "concurrent instance writes lost a workspace")
            let attributes = try FileManager.default.attributesOfItem(atPath: fixture.storage.path)
            try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "registry contains private paths but is not owner-only")
        },
        CodexBarTestCase(name: "Git service refuses a cancelled operation before creating any branch") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            let before = try await service.addProject(directory: fixture.main)
            let operation = Task {
                try await service.createWorktree(from: fixture.main.path, at: fixture.root.appendingPathComponent("cancelled"), branch: "cancelled")
            }
            operation.cancel()
            do {
                _ = try await operation.value
                throw TestFailure(description: "cancelled create completed")
            } catch is CancellationError {}
            try expect(try await service.snapshot() == before, "cancelled operation changed the registry")
            try expect(fixture.gitOutput(["branch", "--list", "cancelled"]).isEmpty, "cancelled operation created a branch")
        },
        CodexBarTestCase(name: "Git service isolates inherited Git targeting and rejects unsafe destinations") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let keys = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT"]
            let previous = keys.map { key in getenv(key).map { String(cString: $0) } }
            for key in keys { setenv(key, "/not/the/selected/repository", 1) }
            defer {
                for (key, value) in zip(keys, previous) {
                    if let value { setenv(key, value, 1) } else { unsetenv(key) }
                }
            }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            let before = try await service.addProject(directory: fixture.main)
            let dangling = fixture.root.appendingPathComponent("dangling")
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside)
            do {
                _ = try await service.createWorktree(from: fixture.main.path, at: dangling, branch: "unsafe")
                throw TestFailure(description: "symlink destination accepted")
            } catch is TestFailure { throw TestFailure(description: "symlink destination accepted") }
            catch {}
            try expect(!FileManager.default.fileExists(atPath: outside.path), "create followed a destination symlink")
            try expect(try await service.snapshot() == before, "unsafe destination changed registry")
            let linked = fixture.root.appendingPathComponent("safe linked")
            let result = try await service.createWorktree(from: fixture.main.path, at: linked, branch: "safe")
            try expect(result.identities[linked.path]?.branch == "safe", "inherited Git variables overrode selected directory")
        },
        CodexBarTestCase(name: "Git service persists creation metadata before invoking Git") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            let parent = fixture.storage.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
            let destination = fixture.root.appendingPathComponent("not-created")
            do {
                _ = try await service.createWorktree(from: fixture.main.path, at: destination, branch: "not-created")
                throw TestFailure(description: "creation continued after metadata write failure")
            } catch is TestFailure { throw TestFailure(description: "creation continued after metadata write failure") }
            catch {}
            try expect(!FileManager.default.fileExists(atPath: destination.path), "Git ran before metadata was saved")
            try expect(fixture.gitOutput(["branch", "--list", "not-created"]).isEmpty, "Git branch survived metadata write failure")
        },
        CodexBarTestCase(name: "Git service rejects corrupt ancestry and storage failures before changing Git") {
            let fixture = try RealWorkspaceFixture()
            defer { fixture.remove() }
            let service = GitWorkspaceService(storageURL: fixture.storage)
            _ = try await service.addProject(directory: fixture.main)
            try Data("{broken".utf8).write(to: fixture.storage)
            let destination = fixture.root.appendingPathComponent("should not exist")
            do {
                _ = try await service.createWorktree(from: fixture.main.path, at: destination, branch: "never-created")
                throw TestFailure(description: "corrupt registry was overwritten")
            } catch is TestFailure { throw TestFailure(description: "corrupt registry was overwritten") }
            catch {}
            try expect(!FileManager.default.fileExists(atPath: destination.path), "Git ran before registry validation")
            try expect(try String(contentsOf: fixture.storage, encoding: .utf8) == "{broken", "corrupt registry was erased")
            try FileManager.default.removeItem(at: fixture.storage)
            try FileManager.default.createDirectory(at: fixture.storage, withIntermediateDirectories: false)
            do {
                _ = try await service.createWorktree(from: fixture.main.path, at: destination, branch: "never-created")
                throw TestFailure(description: "invalid storage was accepted")
            } catch is TestFailure { throw TestFailure(description: "invalid storage was accepted") }
            catch {}
            try expect(fixture.gitOutput(["branch", "--list", "never-created"]).isEmpty, "storage failure created a Git branch")
        }
    ]
}

private struct RealWorkspaceFixture {
    let root: URL
    let main: URL
    let storage: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codexbar Git service \(UUID().uuidString)").resolvingSymlinksInPath()
        main = root.appendingPathComponent("main project")
        storage = root.appendingPathComponent("state/workspaces.json")
        try FileManager.default.createDirectory(at: main.appendingPathComponent("src"), withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try "initial\n".write(to: main.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try git(["add", "tracked.txt"])
        try git(["commit", "-m", "initial"])
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func git(_ arguments: [String]) throws {
        let result = run(arguments)
        guard result.0 == 0 else { throw TestFailure(description: "fixture Git failed: \(result.1)") }
    }

    func gitOutput(_ arguments: [String]) -> String { run(arguments).1 }

    private func run(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", main.path, "-c", "user.name=CodexBar Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return (-1, String(describing: error)) }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
