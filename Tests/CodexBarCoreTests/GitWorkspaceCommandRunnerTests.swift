import CodexBarCore
import Darwin
import Foundation

func gitWorkspaceCommandRunnerTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "workspace Git runner preserves arguments and returns output") {
            let root = try commandRunnerFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            for _ in 0..<100 {
                let output = try GitWorkspaceCommandRunner.run(arguments: ["rev-parse", "--show-toplevel"], directory: root.path)
                try expect(output.trimmingCharacters(in: .newlines) == root.path, "Git's final output must be drained when a short command exits")
            }
            let branch = "feature/space-safe"
            _ = try GitWorkspaceCommandRunner.run(arguments: ["switch", "-c", branch], directory: root.path)
            let actual = try GitWorkspaceCommandRunner.run(arguments: ["branch", "--show-current"], directory: root.path)
            try expect(actual.trimmingCharacters(in: .newlines) == branch, "Git should preserve individual arguments")
        },
        CodexBarTestCase(name: "workspace Git runner reports bounded command failure output") {
            let root = try commandRunnerFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try GitWorkspaceCommandRunner.run(arguments: ["switch", "missing-branch-" + String(repeating: "x", count: 9_000)], directory: root.path)
                throw TestFailure(description: "Missing branch must fail")
            } catch GitWorkspaceServiceError.commandFailed(let message) {
                try expect(message.contains("missing-branch") && message.utf8.count <= 8_192, "Git's error should remain available and bounded")
            }
        },
        CodexBarTestCase(name: "workspace Git cancellation kills a smudge filter that ignores TERM") {
            let root = try commandRunnerFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let pidFile = root.appendingPathComponent("filter-pid")
            let marker = root.appendingPathComponent("filter-finished")
            let filter = root.appendingPathComponent("filter.sh")
            let script = "#!/bin/sh\ntrap '' TERM\necho $$ > \(commandRunnerQuote(pidFile.path))\nsleep 2\necho survived > \(commandRunnerQuote(marker.path))\ncat\n"
            try script.write(to: filter, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: filter.path)
            try "tracked.txt filter=slow\n".write(to: root.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            _ = try GitWorkspaceCommandRunner.run(arguments: ["add", ".gitattributes"], directory: root.path)
            _ = try GitWorkspaceCommandRunner.run(arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "filter"], directory: root.path)
            _ = try GitWorkspaceCommandRunner.run(arguments: ["config", "filter.slow.smudge", commandRunnerQuote(filter.path)], directory: root.path)
            _ = try GitWorkspaceCommandRunner.run(arguments: ["config", "filter.slow.clean", "cat"], directory: root.path)
            let checkout = root.appendingPathComponent("filtered checkout")
            let operation = Task.detached {
                try GitWorkspaceCommandRunner.run(arguments: ["worktree", "add", "-b", "filtered", "--", checkout.path, "HEAD"], directory: root.path)
            }
            for _ in 0..<500 where !FileManager.default.fileExists(atPath: pidFile.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
            let didStart = FileManager.default.fileExists(atPath: pidFile.path)
            let cancelledAt = ContinuousClock.now
            operation.cancel()
            do {
                _ = try await operation.value
                throw TestFailure(description: "Cancelled Git must throw")
            } catch is CancellationError {}
            try expect(didStart, "The real Git smudge filter must start before cancellation")
            try expect(cancelledAt.duration(to: .now) < .seconds(2), "Cancellation should finish promptly")
            try await Task.sleep(for: .seconds(3))
            try expect(!FileManager.default.fileExists(atPath: marker.path), "Cancelled filter descendants must not keep writing after the operation returns")
        }
    ]
}

private func commandRunnerFixture() throws -> URL {
    let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("codexbar runner \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try GitWorkspaceCommandRunner.run(arguments: ["init", "-b", "main"], directory: root.path)
    try "content\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    _ = try GitWorkspaceCommandRunner.run(arguments: ["add", "tracked.txt"], directory: root.path)
    _ = try GitWorkspaceCommandRunner.run(arguments: ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-m", "initial"], directory: root.path)
    return root
}

private func commandRunnerQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
