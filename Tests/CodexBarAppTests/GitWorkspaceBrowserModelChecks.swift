import CodexBarCore
import Foundation

@main
@MainActor
struct GitWorkspaceBrowserModelChecks {
    static func main() async throws {
        let suite = "CodexBar.workspace-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = BrowserServiceFixture()
        let model = GitWorkspaceBrowserModel(service: service, defaults: defaults)
        model.start()
        try await eventually { model.snapshot.records.count == 3 }
        model.selectDirectory("/repo/A")
        try await eventuallyAsync { await service.hasBranchRequest("/repo/A") }
        model.selectDirectory("/repo/B")
        try await eventuallyAsync { await service.hasBranchRequest("/repo/B") }
        await service.completeBranches("/repo/B", with: ["b", "b-other"])
        try await eventually { model.branches == ["b", "b-other"] }
        await service.completeBranches("/repo/A", with: ["a", "a-old"])
        try await Task.sleep(for: .milliseconds(20))
        precondition(model.activeDirectory == "/repo/B" && model.branches == ["b", "b-other"], "Late branch lookup replaced the selected workspace")

        model.selectDirectory("/repo/A")
        let switching = Task { await model.switchBranch("feature-x") }
        try await eventuallyAsync { await service.isSwitchWaiting }
        model.selectDirectory("/repo/B")
        await service.completeSwitch()
        await switching.value
        precondition(model.activeDirectory == "/repo/B", "Completed Git command changed a newer selection")
        precondition(model.snapshot.identities["/repo/A"]?.branch == "feature-x")
        precondition(model.snapshot.records.first(where: { $0.workspaceRoot == "/repo/B" })?.parentWorkspaceRoot == "/repo/A")
        model.selectDirectory("/repo/A")
        await service.refuseNextSwitch()
        await model.switchBranch("refused")
        precondition(model.errorMessage?.contains("未提交") == true, "Git's branch switch error was hidden")
        precondition(model.activeDirectory == "/repo/A" && model.activeIdentity?.branch == "feature-x", "Failed switch changed the active directory or displayed branch")
        precondition(model.snapshot.records.first(where: { $0.workspaceRoot == "/repo/B" })?.parentWorkspaceRoot == "/repo/A")
        model.followDirectory("/repo/B/Sources")
        try await eventually { model.activeDirectory == "/repo/B" }
        model.followDirectory("/repo/AnotherProject")
        try await eventually { model.activeDirectory == "/repo" }
        let restored = GitWorkspaceBrowserModel(service: service, defaults: defaults)
        precondition(restored.activeDirectory == "/repo", "Selected directory was not restored")
        await service.makeUnavailable("/repo/A")
        model.refresh()
        try await eventually { model.snapshot.identities["/repo/A"] == nil && !model.isRefreshing }
        model.selectDirectory("/repo/B")
        model.followDirectory("/repo/A")
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.activeDirectory == "/repo/A" && model.activeIdentity == nil, "Registered unavailable checkout selected its containing repository")
        precondition(model.branches.isEmpty, "Unavailable checkout exposed another directory's branches")
        model.selectDirectory("/repo/B")
        model.followDirectory("/repo/A/Sources")
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.activeDirectory == "/repo/A" && model.activeIdentity == nil, "Unavailable checkout's subdirectory fell back to the outer repository")
        model.followDirectory("/repo/A/nested/Sources")
        try await eventually { model.activeDirectory == "/repo/A/nested" }
        precondition(model.activeIdentity?.repositoryID == "nested-repo", "Unavailable containing checkout hid a valid nested independent repository")
        model.stop()
        await service.finishAllBranches()

        let tree = GitWorkspaceBrowserModel.rows(for: deepSnapshot())
        precondition(tree.count == 8 && tree.first(where: { $0.record.workspaceRoot == "/deep/6" })?.depth == 6, "Tree depth was truncated")
        precondition(tree.last?.record.workspaceRoot == "/unknown" && tree.last?.hasUnknownOrigin == true, "Imported worktree acquired an invented parent")
        print("PASS worktree browser branch races, operation targeting, active directory following and unbounded creation hierarchy")
    }

    static func deepSnapshot() -> GitWorkspaceSnapshot {
        var records = [GitWorkspaceRecord(workspaceRoot: "/deep", repositoryID: "repo", parentWorkspaceRoot: nil, order: 0, isMainWorkspace: true)]
        for depth in 1...6 {
            records.append(GitWorkspaceRecord(workspaceRoot: "/deep/\(depth)", repositoryID: "repo", parentWorkspaceRoot: depth == 1 ? "/deep" : "/deep/\(depth - 1)", order: depth, isMainWorkspace: false))
        }
        records.append(GitWorkspaceRecord(workspaceRoot: "/unknown", repositoryID: "repo", parentWorkspaceRoot: nil, order: 7, isMainWorkspace: false))
        return GitWorkspaceSnapshot(records: records, identities: [:])
    }

    static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Worktree browser condition timed out")
    }

    static func eventuallyAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Worktree browser service condition timed out")
    }
}

private actor BrowserServiceFixture: GitWorkspaceBrowserService {
    private var branch = "a"
    private var branchRequests: [String: [CheckedContinuation<[String], Never>]] = [:]
    private var switchRequest: CheckedContinuation<Void, Never>?
    private var shouldRefuseSwitch = false
    private var unavailable = Set<String>()
    private var hasNestedProject = false
    var isSwitchWaiting: Bool { switchRequest != nil }

    func snapshot() -> GitWorkspaceSnapshot {
        let paths = ["/repo", "/repo/A", "/repo/B"]
        let names = ["main", branch, "b"]
        var records = paths.enumerated().map { index, path in
            GitWorkspaceRecord(workspaceRoot: path, repositoryID: "repo", parentWorkspaceRoot: index == 0 ? nil : paths[index - 1], order: index, isMainWorkspace: index == 0)
        }
        var identities = Dictionary(uniqueKeysWithValues: paths.enumerated().map { index, path in
            (path, GitWorkspaceIdentity(repositoryID: "repo", workspaceRoot: path, repositoryName: "repo", branch: names[index], isLinkedWorktree: index != 0, headPath: path + "/.git/HEAD"))
        })
        for path in unavailable { identities.removeValue(forKey: path) }
        if hasNestedProject {
            let path = "/repo/A/nested"
            records.append(GitWorkspaceRecord(workspaceRoot: path, repositoryID: "nested-repo", parentWorkspaceRoot: nil, order: 3, isMainWorkspace: true))
            identities[path] = GitWorkspaceIdentity(repositoryID: "nested-repo", workspaceRoot: path, repositoryName: "nested", branch: "nested-main", isLinkedWorktree: false, headPath: path + "/.git/HEAD")
        }
        return GitWorkspaceSnapshot(records: records, identities: identities)
    }
    func addProject(directory: URL) -> GitWorkspaceSnapshot {
        if directory.path == "/repo/A/nested" { hasNestedProject = true }
        return snapshot()
    }
    func createWorktree(from: String, at: URL, branch: String) -> GitWorkspaceSnapshot { snapshot() }
    func switchBranch(in directory: String, to branch: String) async throws -> GitWorkspaceSnapshot {
        precondition(directory == "/repo/A")
        if shouldRefuseSwitch {
            shouldRefuseSwitch = false
            throw FixtureError.uncommittedChanges
        }
        await withCheckedContinuation { switchRequest = $0 }
        self.branch = branch
        return snapshot()
    }
    func localBranches(in directory: String) async -> [String] {
        await withCheckedContinuation { branchRequests[directory, default: []].append($0) }
    }
    func workspaceRoot(for directory: String) -> String? {
        ["/repo", "/repo/A", "/repo/B", "/repo/A/nested"].filter {
            !unavailable.contains($0) && (directory == $0 || directory.hasPrefix($0 + "/"))
        }.max { $0.count < $1.count }
    }
    func hasBranchRequest(_ directory: String) -> Bool { !(branchRequests[directory]?.isEmpty ?? true) }
    func completeBranches(_ directory: String, with names: [String]) {
        let waiting = branchRequests.removeValue(forKey: directory) ?? []
        for request in waiting { request.resume(returning: names) }
    }
    func completeSwitch() { switchRequest?.resume(); switchRequest = nil }
    func refuseNextSwitch() { shouldRefuseSwitch = true }
    func makeUnavailable(_ directory: String) { unavailable.insert(directory) }
    func finishAllBranches() {
        for directory in Array(branchRequests.keys) { completeBranches(directory, with: []) }
    }
}

private enum FixtureError: LocalizedError {
    case uncommittedChanges
    var errorDescription: String? { "未提交的更改会被覆盖" }
}
