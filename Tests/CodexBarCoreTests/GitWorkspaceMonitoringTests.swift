import CodexBarCore
import Foundation

@MainActor
func gitWorkspaceMonitoringTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "worktree labels follow atomic branch changes and visible directories") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitMonitor-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let main = root.appendingPathComponent("project")
            let linked = root.appendingPathComponent("project-graph")
            let git = main.appendingPathComponent(".git")
            let linkedGit = git.appendingPathComponent("worktrees/graph")
            try FileManager.default.createDirectory(at: linkedGit, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
            try Data("gitdir: \(linkedGit.path)\n".utf8).write(to: linked.appendingPathComponent(".git"))
            try Data("../..\n".utf8).write(to: linkedGit.appendingPathComponent("commondir"))
            try Data("ref: refs/heads/graph-runtime\n".utf8).write(to: linkedGit.appendingPathComponent("HEAD"))

            let monitor = GitWorkspaceMonitor()
            var linkedBranch: String?
            var labelCount = 0
            var callbacks = 0
            monitor.start(cwds: [main.path, linked.path]) { labels in
                linkedBranch = labels[linked.path]?.branch
                labelCount = labels.count
                callbacks += 1
            }
            defer { monitor.stop() }
            try await waitForGitLabels { linkedBranch == "graph-runtime" && labelCount == 2 }

            try Data("ref: refs/heads/graph-editor\n".utf8).write(
                to: linkedGit.appendingPathComponent("HEAD"), options: .atomic
            )
            try await waitForGitLabels { linkedBranch == "graph-editor" }
            let settled = callbacks
            try await Task.sleep(for: .milliseconds(250))
            try expect(callbacks == settled, "idle monitor repeatedly published unchanged labels")

            monitor.setCWDs([main.path])
            try await waitForGitLabels { labelCount == 0 }
            monitor.setCWDs([main.path, linked.path])
            try await waitForGitLabels { labelCount == 2 }
            monitor.stop()
            let stopped = callbacks
            try Data("ref: refs/heads/later\n".utf8).write(
                to: linkedGit.appendingPathComponent("HEAD"), options: .atomic
            )
            try await Task.sleep(for: .milliseconds(250))
            try expect(callbacks == stopped, "stopped monitor published stale metadata")
        },
        CodexBarTestCase(name: "worktree origin follows reflog appends and atomic history replacement") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitOriginMonitor-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let main = root.appendingPathComponent("project")
            let linked = root.appendingPathComponent("project-graph")
            let git = main.appendingPathComponent(".git")
            let linkedGit = git.appendingPathComponent("worktrees/graph")
            let refs = git.appendingPathComponent("refs/heads")
            let logs = git.appendingPathComponent("logs/refs/heads")
            for directory in [linked, linkedGit, refs, logs] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let oid = String(repeating: "a", count: 40)
            try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
            try Data("gitdir: \(linkedGit.path)\n".utf8).write(to: linked.appendingPathComponent(".git"))
            try Data("../..\n".utf8).write(to: linkedGit.appendingPathComponent("commondir"))
            try Data("ref: refs/heads/graph\n".utf8).write(to: linkedGit.appendingPathComponent("HEAD"))
            for branch in ["main", "graph"] {
                try Data("\(oid)\n".utf8).write(to: refs.appendingPathComponent(branch))
            }
            let log = logs.appendingPathComponent("graph")
            let creation = "\(String(repeating: "0", count: 40)) \(oid) Developer <dev@example.test> 1789372800 +0800\tbranch: Created from main\n"
            try Data(creation.utf8).write(to: log)
            let monitor = GitWorkspaceMonitor()
            var source: String?
            var labelCount = 0
            monitor.start(cwds: [linked.path]) { labels in
                source = labels[linked.path]?.sourceBranch
                labelCount = labels.count
            }
            defer { monitor.stop() }
            try await waitForGitLabels { source == "main" && labelCount == 1 }

            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(oid) \(oid) Developer <dev@example.test> 1789372801 +0800\tBranch: copied refs/heads/other to refs/heads/graph\n".utf8))
            try handle.close()
            try await waitForGitLabels { source == nil && labelCount == 1 }

            try Data(creation.utf8).write(to: log, options: .atomic)
            try await waitForGitLabels { source == "main" }
        }
    ]
}

@MainActor
private func waitForGitLabels(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try expect(predicate(), "worktree labels did not update")
}
