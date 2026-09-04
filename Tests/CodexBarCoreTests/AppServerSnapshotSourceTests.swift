import Foundation
import CodexBarCore

@MainActor
func appServerSnapshotSourceTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "loads the latest persisted VS Code turn through app-server") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarAppServerTests-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent("fake-codex")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try fakeAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let snapshots = try await CodexAppServerThreadSnapshotSource(
                executableURL: executable,
                executableValidator: { _ in true }
            ).loadSnapshots(matching: [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "empty — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 3, title: "interrupted — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 4, title: "failed — Visual Studio Code")
            ])

            try expect(
                snapshots.count == 3,
                "terminal turns were skipped or a window without turns blocked recovery"
            )
            let snapshot = try require(
                snapshots.first(where: { $0.cwd == "/work/project-alpha" }),
                "completed app-server snapshot is missing"
            )
            try expect(snapshot.sessionID == "latest-session", "source selected the older thread")
            try expect(snapshot.turnID == "latest-turn", "source did not load the latest turn id")
            try expect(snapshot.cwd == "/work/project-alpha", "source returned the wrong cwd")
            try expect(snapshot.title == "Latest task", "source returned the wrong title")
            try expect(snapshot.status == .completed, "source returned the wrong turn status")
            try expect(
                snapshot.startedAt == Date(timeIntervalSince1970: 190),
                "source returned the wrong turn start time"
            )
            try expect(
                snapshot.updatedAt == Date(timeIntervalSince1970: 200),
                "source returned the wrong thread update time"
            )
            try expect(
                snapshots.first(where: { $0.cwd == "/work/interrupted" })?.status == .interrupted,
                "source did not return an inactive interrupted turn"
            )
            try expect(
                snapshots.first(where: { $0.cwd == "/work/failed" })?.status == .failed,
                "source did not return an inactive failed turn"
            )
        },
        CodexBarTestCase(name: "loads exact CLI and VS Code turns for active Hook tasks") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CodexBarActiveAppServerTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            let executable = root.appendingPathComponent("fake-codex")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try activeTaskAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let snapshots = try await CodexAppServerThreadSnapshotSource(
                executableURL: executable,
                executableValidator: { _ in true }
            ).loadSnapshots(matchingActiveTasks: [
                activeTask(
                    session: "cli-session",
                    turn: "cli-turn",
                    cwd: "/work/terminal"
                ),
                activeTask(
                    session: "missing-session",
                    turn: "missing-turn",
                    cwd: "/work/missing"
                ),
                activeTask(
                    session: "vscode-session",
                    turn: "vscode-turn",
                    cwd: "/work/editor"
                ),
                activeTask(
                    session: "stale-session",
                    turn: "requested-turn",
                    cwd: "/work/stale"
                ),
                activeTask(
                    session: "cwd-session",
                    turn: "cwd-turn",
                    cwd: "/work/expected"
                )
            ])

            try expect(
                snapshots.count == 2,
                "active recovery accepted a stale turn or a mismatched cwd"
            )
            let cli = try require(
                snapshots.first(where: { $0.sessionID == "cli-session" }),
                "terminal CLI snapshot is missing"
            )
            try expect(cli.turnID == "cli-turn", "CLI recovery returned the wrong turn")
            try expect(cli.source == .cli, "CLI recovery lost the thread source")
            try expect(
                cli.status == .inProgress,
                "active CLI turn was treated as terminal"
            )
            try expect(
                cli.startedAt == Date(timeIntervalSince1970: 100),
                "CLI recovery did not safely reuse the Hook start time"
            )
            let vscode = try require(
                snapshots.first(where: { $0.sessionID == "vscode-session" }),
                "VS Code active snapshot is missing"
            )
            try expect(vscode.source == .vscode, "VS Code recovery lost the thread source")
            try expect(
                vscode.status == .inProgress,
                "active VS Code turn was treated as terminal"
            )
        },
        CodexBarTestCase(name: "surfaces unsupported active-task RPC methods") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CodexBarUnsupportedRPC-(UUID().uuidString)",
                isDirectory: true
            )
            let executable = root.appendingPathComponent("fake-codex")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try unsupportedActiveTaskAppServerScript.write(
                to: executable,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let didFail: Bool
            do {
                _ = try await CodexAppServerThreadSnapshotSource(
                    executableURL: executable,
                    executableValidator: { _ in true }
                ).loadSnapshots(matchingActiveTasks: [
                    activeTask(
                        session: "cli-session",
                        turn: "cli-turn",
                        cwd: "/work/terminal"
                    )
                ])
                didFail = false
            } catch {
                didFail = true
            }
            try expect(
                didFail,
                "unsupported thread/read was silently treated as a missing task"
            )
        },
        CodexBarTestCase(name: "rejects thread metadata that unexpectedly includes turns") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "CodexBarHydratedThreadTests-\(UUID().uuidString)",
                isDirectory: true
            )
            let executable = root.appendingPathComponent("fake-codex")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try hydratedThreadAppServerScript.write(
                to: executable,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let didFail: Bool
            do {
                _ = try await CodexAppServerThreadSnapshotSource(
                    executableURL: executable,
                    executableValidator: { _ in true }
                ).loadSnapshots(matching: [
                    VSCodeWindowDescriptor(
                        id: 1,
                        title: "project-alpha — Visual Studio Code"
                    )
                ])
                didFail = false
            } catch {
                didFail = true
            }
            try expect(didFail, "preloaded thread turns crossed the metadata-only boundary")
        },
        CodexBarTestCase(name: "locates the newest trusted official VS Code extension executable") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarLocatorTests-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }

            #if arch(arm64)
            let executableSubpath = "bin/macos-aarch64/codex"
            #elseif arch(x86_64)
            let executableSubpath = "bin/macos-x86_64/codex"
            #else
            let executableSubpath = "bin/unsupported/codex"
            #endif

            let older = root
                .appendingPathComponent("openai.chatgpt-26.9.0", isDirectory: true)
                .appendingPathComponent(executableSubpath)
            let newer = root
                .appendingPathComponent("openai.chatgpt-26.10.0", isDirectory: true)
                .appendingPathComponent(executableSubpath)
            for executable in [older, newer] {
                try FileManager.default.createDirectory(
                    at: executable.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data().write(to: executable)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: executable.path
                )
            }
            let olderExtension = older
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let binSymlinkExtension = root.appendingPathComponent(
                "openai.chatgpt-27.0.0",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: binSymlinkExtension,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: binSymlinkExtension.appendingPathComponent("bin"),
                withDestinationURL: olderExtension.appendingPathComponent("bin")
            )

            let executableSymlink = root
                .appendingPathComponent("openai.chatgpt-28.0.0", isDirectory: true)
                .appendingPathComponent(executableSubpath)
            try FileManager.default.createDirectory(
                at: executableSymlink.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: executableSymlink,
                withDestinationURL: older
            )

            try FileManager.default.createSymbolicLink(
                at: root.appendingPathComponent("openai.chatgpt-29.0.0"),
                withDestinationURL: olderExtension
            )

            let located = CodexExecutableLocator.visualStudioCodeExtensionExecutable(
                extensionsDirectory: root,
                signatureValidator: { candidate in
                    candidate.resolvingSymlinksInPath() == older.resolvingSymlinksInPath()
                }
            )
            try expect(
                located?.resolvingSymlinksInPath() == older.resolvingSymlinksInPath(),
                "locator did not skip an untrusted higher-version extension; got \(located?.path ?? "nil")"
            )
        },
        CodexBarTestCase(name: "does not launch an executable that fails the second signature check") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarSignatureTests-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent("fake-codex")
            let marker = root.appendingPathComponent("started")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try markerAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let didFail: Bool
            do {
                _ = try await CodexAppServerThreadSnapshotSource(
                    executableURL: executable,
                    executableValidator: { _ in false }
                ).loadSnapshots(matching: [
                    VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")
                ])
                didFail = false
            } catch {
                didFail = true
            }

            try expect(didFail, "rejected executable unexpectedly produced snapshots")
            try expect(
                !FileManager.default.fileExists(atPath: marker.path),
                "source launched an executable after signature validation failed"
            )
        },
        CodexBarTestCase(name: "fails closed when bounded thread history is incomplete") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarPaginationTests-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent("fake-codex")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try paginatedAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let didFail: Bool
            do {
                _ = try await CodexAppServerThreadSnapshotSource(
                    executableURL: executable,
                    executableValidator: { _ in true }
                ).loadSnapshots(matching: [
                    VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")
                ])
                didFail = false
            } catch {
                didFail = true
            }

            try expect(
                didFail,
                "source guessed a unique match from incomplete thread history"
            )
        },
        CodexBarTestCase(name: "times out when app-server never responds") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarTimeoutTests-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent("fake-codex")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try nonresponsiveAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let startedAt = Date()
            let didFail: Bool
            do {
                _ = try await CodexAppServerThreadSnapshotSource(
                    executableURL: executable,
                    sessionTimeout: 0.2,
                    executableValidator: { _ in true }
                ).loadSnapshots(matching: [
                    VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")
                ])
                didFail = false
            } catch {
                didFail = true
            }
            try expect(didFail, "nonresponsive app-server unexpectedly succeeded")
            try expect(
                Date().timeIntervalSince(startedAt) < 2,
                "app-server timeout did not stop the recovery promptly"
            )
        },
        CodexBarTestCase(name: "cancels a nonresponsive app-server promptly") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarCancellationTests-\(UUID().uuidString)", isDirectory: true)
            let executable = root.appendingPathComponent("fake-codex")
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try nonresponsiveAppServerScript.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: executable.path
            )

            let source = CodexAppServerThreadSnapshotSource(
                executableURL: executable,
                sessionTimeout: 2,
                executableValidator: { _ in true }
            )
            let startedAt = Date()
            let query = Task {
                try await source.loadSnapshots(matching: [
                    VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code")
                ])
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            query.cancel()

            let didFail: Bool
            do {
                _ = try await query.value
                didFail = false
            } catch {
                didFail = true
            }
            try expect(didFail, "cancelled app-server query unexpectedly succeeded")
            try expect(
                Date().timeIntervalSince(startedAt) < 1,
                "cancellation did not stop the app-server process promptly"
            )
        }
    ]
}

private func activeTask(
    session: String,
    turn: String,
    cwd: String
) -> CodexTask {
    CodexTask(
        id: "\(session):\(turn)",
        sessionID: session,
        turnID: turn,
        cwd: cwd,
        workspaceName: URL(fileURLWithPath: cwd).lastPathComponent,
        title: "Active task",
        status: .running,
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100),
        isUnread: false
    )
}

private let activeTaskAppServerScript = #"""
#!/usr/bin/ruby
require "json"
$stdout.sync = true
initialized = false

threads = [
  {
    "id" => "cli-session",
    "sessionId" => "cli-session",
    "cwd" => "/work/terminal",
    "preview" => "Terminal task",
    "name" => nil,
    "source" => "cli",
    "status" => { "type" => "active", "activeFlags" => [] },
    "createdAt" => 100,
    "updatedAt" => 120
  },
  {
    "id" => "vscode-session",
    "sessionId" => "vscode-session",
    "cwd" => "/work/editor",
    "preview" => "Editor task",
    "name" => nil,
    "source" => "vscode",
    "status" => { "type" => "active", "activeFlags" => [] },
    "createdAt" => 100,
    "updatedAt" => 121
  },
  {
    "id" => "stale-session",
    "sessionId" => "stale-session",
    "cwd" => "/work/stale",
    "preview" => "Newer turn",
    "name" => nil,
    "source" => "cli",
    "status" => { "type" => "active", "activeFlags" => [] },
    "createdAt" => 100,
    "updatedAt" => 122
  },
  {
    "id" => "cwd-session",
    "sessionId" => "cwd-session",
    "cwd" => "/work/actual",
    "preview" => "Wrong cwd",
    "name" => nil,
    "source" => "cli",
    "status" => { "type" => "active", "activeFlags" => [] },
    "createdAt" => 100,
    "updatedAt" => 123
  }
]

STDIN.each_line do |line|
  request = JSON.parse(line)
  case request["method"]
  when "initialize"
    puts JSON.generate("id" => request["id"], "result" => {})
  when "initialized"
    initialized = true
  when "thread/read"
    params = request["params"]
    thread = threads.find { |candidate| candidate["id"] == params["threadId"] }
    unless initialized && params["includeTurns"] == false && thread
      puts JSON.generate(
        "id" => request["id"],
        "error" => { "code" => -32600, "message" => "not found" }
      )
      next
    end
    puts JSON.generate(
      "id" => request["id"],
      "result" => { "thread" => thread.merge("turns" => []) }
    )
  when "thread/list"
    puts JSON.generate(
      "id" => request["id"],
      "error" => { "code" => -32601, "message" => "unexpected global scan" }
    )
  when "thread/turns/list"
    thread_id = request.dig("params", "threadId")
    turn_id = case thread_id
              when "cli-session" then "cli-turn"
              when "vscode-session" then "vscode-turn"
              when "stale-session" then "newer-turn"
              else "cwd-turn"
              end
    status = thread_id == "vscode-session" ? "failed" : "interrupted"
    puts JSON.generate(
      "id" => request["id"],
      "result" => {
        "data" => [{
          "id" => turn_id,
          "items" => [],
          "itemsView" => "notLoaded",
          "status" => status,
          "startedAt" => (thread_id == "cli-session" ? nil : 110),
          "completedAt" => (thread_id == "vscode-session" ? 121 : nil)
        }]
      }
    )
  end
end
"""#

private let unsupportedActiveTaskAppServerScript = #"""
#!/usr/bin/ruby
require "json"
$stdout.sync = true

STDIN.each_line do |line|
  request = JSON.parse(line)
  case request["method"]
  when "initialize"
    puts JSON.generate("id" => request["id"], "result" => {})
  when "thread/read"
    puts JSON.generate(
      "id" => request["id"],
      "error" => { "code" => -32601, "message" => "method not found" }
    )
  end
end
"""#

private let hydratedThreadAppServerScript = #"""
#!/usr/bin/ruby
require "json"
$stdout.sync = true

STDIN.each_line do |line|
  request = JSON.parse(line)
  case request["method"]
  when "initialize"
    puts JSON.generate("id" => request["id"], "result" => {})
  when "thread/list"
    puts JSON.generate(
      "id" => request["id"],
      "result" => {
        "data" => [{
          "id" => "hydrated-session",
          "sessionId" => "hydrated-session",
          "cwd" => "/work/project-alpha",
          "preview" => "Metadata only",
          "name" => nil,
          "source" => "vscode",
          "createdAt" => 100,
          "updatedAt" => 110,
          "turns" => [{ "id" => "unexpected-turn" }]
        }],
        "nextCursor" => nil
      }
    )
  when "thread/turns/list"
    puts JSON.generate(
      "id" => request["id"],
      "result" => {
        "data" => [{
          "id" => "hydrated-turn",
          "items" => [],
          "itemsView" => "notLoaded",
          "status" => "completed",
          "startedAt" => 105,
          "completedAt" => 110
        }]
      }
    )
  end
end
"""#

private let fakeAppServerScript = #"""
#!/usr/bin/ruby
require "json"
$stdout.sync = true
initialized = false

threads = [
  {
    "id" => "old-session",
    "sessionId" => "old-session",
    "cwd" => "/work/project-alpha",
    "preview" => "Old preview",
    "name" => "Old task",
    "source" => "vscode",
    "createdAt" => 90,
    "updatedAt" => 100
  },
  {
    "id" => "latest-session",
    "sessionId" => "latest-session",
    "cwd" => "/work/project-alpha",
    "preview" => "Latest preview",
    "name" => "Latest task",
    "source" => "vscode",
    "createdAt" => 180,
    "updatedAt" => 200
  },
  {
    "id" => "closed-session",
    "sessionId" => "closed-session",
    "cwd" => "/work/closed",
    "preview" => "Closed preview",
    "name" => "Closed task",
    "source" => "vscode",
    "createdAt" => 290,
    "updatedAt" => 300
  },
  {
    "id" => "empty-session",
    "sessionId" => "empty-session",
    "cwd" => "/work/empty",
    "preview" => "No turns",
    "name" => "No turns",
    "source" => "vscode",
    "createdAt" => 390,
    "updatedAt" => 400
  },
  {
    "id" => "interrupted-session",
    "sessionId" => "interrupted-session",
    "cwd" => "/work/interrupted",
    "preview" => "Interrupted preview",
    "name" => "Interrupted task",
    "source" => "vscode",
    "createdAt" => 200,
    "updatedAt" => 210
  },
  {
    "id" => "failed-session",
    "sessionId" => "failed-session",
    "cwd" => "/work/failed",
    "preview" => "Failed preview",
    "name" => "Failed task",
    "source" => "vscode",
    "createdAt" => 210,
    "updatedAt" => 220
  }
]

STDIN.each_line do |line|
  request = JSON.parse(line)
  case request["method"]
  when "initialize"
    unless request.dig("params", "capabilities", "experimentalApi") == true
      puts JSON.generate("id" => request["id"], "error" => { "code" => -32602 })
      next
    end
    puts JSON.generate("id" => request["id"], "result" => {})
  when "initialized"
    initialized = true
  when "thread/list"
    params = request["params"]
    valid = initialized &&
      params["sourceKinds"] == ["vscode"] &&
      params["useStateDbOnly"] == true &&
      params["sortKey"] == "updated_at" &&
      params["sortDirection"] == "desc" &&
      params["limit"] == 100
    unless valid
      puts JSON.generate("id" => request["id"], "error" => { "code" => -32602 })
      next
    end
    puts JSON.generate(
      "id" => request["id"],
      "result" => { "data" => threads, "nextCursor" => nil }
    )
  when "thread/turns/list"
    params = request["params"]
    valid = params["limit"] == 1 &&
      params["sortDirection"] == "desc" &&
      params["itemsView"] == "notLoaded"
    unless valid
      puts JSON.generate("id" => request["id"], "error" => { "code" => -32602 })
      next
    end
    if request.dig("params", "threadId") == "empty-session"
      puts JSON.generate("id" => request["id"], "result" => { "data" => [] })
    elsif request.dig("params", "threadId") == "latest-session"
      puts JSON.generate(
        "id" => request["id"],
        "result" => {
          "data" => [{
            "id" => "latest-turn",
            "items" => [],
            "itemsView" => "notLoaded",
            "status" => "completed",
            "startedAt" => 190,
            "completedAt" => 200
          }]
        }
      )
    elsif request.dig("params", "threadId") == "interrupted-session"
      puts JSON.generate(
        "id" => request["id"],
        "result" => {
          "data" => [{
            "id" => "interrupted-turn",
            "items" => [],
            "itemsView" => "notLoaded",
            "status" => "interrupted",
            "startedAt" => 205
          }]
        }
      )
    elsif request.dig("params", "threadId") == "failed-session"
      puts JSON.generate(
        "id" => request["id"],
        "result" => {
          "data" => [{
            "id" => "failed-turn",
            "items" => [],
            "itemsView" => "notLoaded",
            "status" => "failed",
            "startedAt" => 215
          }]
        }
      )
    end
  end
end
"""#

private let paginatedAppServerScript = #"""
#!/usr/bin/ruby
require "json"
$stdout.sync = true

STDIN.each_line do |line|
  request = JSON.parse(line)
  case request["method"]
  when "initialize"
    puts JSON.generate("id" => request["id"], "result" => {})
  when "thread/list"
    page = (request.dig("params", "cursor") || "0").to_i
    threads = 100.times.map do |index|
      number = page * 100 + index
      cwd = number == 0 ? "/work/project-alpha" : "/work/closed-#{number}"
      id = number == 0 ? "bounded-session" : "closed-#{number}"
      {
        "id" => id,
        "sessionId" => id,
        "cwd" => cwd,
        "preview" => "Task #{number}",
        "name" => nil,
        "source" => "vscode",
        "createdAt" => 1_000 - number,
        "updatedAt" => 1_000 - number
      }
    end
    puts JSON.generate(
      "id" => request["id"],
      "result" => { "data" => threads, "nextCursor" => (page + 1).to_s }
    )
  when "thread/turns/list"
    puts JSON.generate(
      "id" => request["id"],
      "result" => {
        "data" => [{
          "id" => "bounded-turn",
          "items" => [],
          "itemsView" => "notLoaded",
          "status" => "completed",
          "startedAt" => 900,
          "completedAt" => 1_000
        }]
      }
    )
  end
end
"""#

private let nonresponsiveAppServerScript = #"""
#!/usr/bin/ruby
STDIN.each_line do |_line|
  sleep 60
end
"""#

private let markerAppServerScript = #"""
#!/usr/bin/ruby
File.write(File.join(File.dirname(__FILE__), "started"), "")
"""#
