import CodexBarCore
import Foundation

@MainActor
func gitWorkspaceIdentityTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "Git identity joins a main checkout and its linked worktree") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            let main = try require(GitWorkspaceIdentityReader.read(cwd: fixture.main.path), "main checkout missing")
            let linked = try require(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path), "worktree missing")
            try expect(main.repositoryID == linked.repositoryID, "linked worktree has a different repository identity")
            try expect(main.repositoryName == "sample-project" && linked.repositoryName == "sample-project", "repository names differ")
            try expect(main.branch == "develop" && linked.branch == "graph-runtime", "branches were not read from their own HEAD")
            try expect(!main.isLinkedWorktree && linked.isLinkedWorktree, "worktree marker is incorrect")
            try expect(main.headPath != linked.headPath, "worktrees share a watched HEAD path")
        },
        CodexBarTestCase(name: "Git identity resolves workspace subdirectories and symlinks") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            let subdirectory = fixture.linked.appendingPathComponent("Sources/Graph")
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let alias = fixture.root.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.linked)
            let nested = try require(GitWorkspaceIdentityReader.read(cwd: subdirectory.path), "subdirectory identity missing")
            try expect(nested == GitWorkspaceIdentityReader.read(cwd: alias.path), "canonical checkout identity differs")
            try expect(nested.workspaceRoot == fixture.linked.resolvingSymlinksInPath().path, "root points at subdirectory")
        },
        CodexBarTestCase(name: "Git identity reads branch changes and detached HEAD") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.write("ref: refs/heads/feature/new-graph\n", at: fixture.linkedGit.appendingPathComponent("HEAD"))
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.branch == "feature/new-graph", "branch change stayed stale")
            try fixture.write(String(repeating: "a", count: 40) + "\n", at: fixture.linkedGit.appendingPathComponent("HEAD"))
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.branch == "HEAD·aaaaaaa", "detached checkout has no usable label")
        },
        CodexBarTestCase(name: "Git identity accepts absolute gitfile and common-directory paths") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.write("gitdir: \(fixture.linkedGit.path)\n", at: fixture.linked.appendingPathComponent(".git"))
            try fixture.write(fixture.main.appendingPathComponent(".git").path + "\n", at: fixture.linkedGit.appendingPathComponent("commondir"))
            let main = try require(GitWorkspaceIdentityReader.read(cwd: fixture.main.path), "main checkout missing")
            let linked = try require(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path), "absolute gitfile missing")
            try expect(
                main.repositoryID == linked.repositoryID,
                "absolute Git metadata paths broke worktree grouping"
            )
        },
        CodexBarTestCase(name: "Git identity confirms creation from a local branch without assuming main") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.recordCreation(from: "develop")
            let identity = try require(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path), "worktree missing")
            try expect(identity.sourceBranch == "develop", "local creation branch was not retained")
            try expect(identity.metadataWatchPaths.contains(fixture.branchLog.resolvingSymlinksInPath().path), "current branch reflog is not watched")
            let labels = GitWorkspaceIdentityReader.labels(identities: [fixture.linked.path: identity])
            try expect(labels[fixture.linked.path]?.sourceBranch == "develop", "single worktree lost its creation source")
            try expect(labels[fixture.linked.path]?.repositoryID == identity.repositoryID, "label lost stable repository identity")
        },
        CodexBarTestCase(name: "Git creation source supports local packed refs and nested branch names") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.recordCreation(from: "refs/heads/release/stable")
            try FileManager.default.removeItem(at: fixture.main.appendingPathComponent(".git/refs/heads/release/stable"))
            try fixture.write("# pack-refs with: peeled fully-peeled sorted\n\(fixture.oid) refs/heads/release/stable\n", at: fixture.main.appendingPathComponent(".git/packed-refs"))
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == "release/stable", "packed local source ref was not recognized")
        },
        CodexBarTestCase(name: "Git creation source rejects HEAD commits remote refs and missing branches") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.recordCreation(from: "develop")
            for source in ["HEAD", "HEAD~1", fixture.oid, "origin/main", "refs/remotes/origin/main", "missing"] {
                try fixture.write(fixture.logEntry(from: String(repeating: "0", count: 40), message: "branch: Created from \(source)"), at: fixture.branchLog)
                try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "unconfirmed source \(source) was treated as a local parent")
            }
        },
        CodexBarTestCase(name: "Git creation source stays unknown when the initial record expired or changed") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.recordCreation(from: "develop")
            for contents in [
                fixture.logEntry(from: fixture.oid, message: "branch: Created from develop"),
                fixture.logEntry(from: String(repeating: "0", count: 40), message: "commit (initial): start"),
                "not a reflog\n",
                fixture.logEntry(from: String(repeating: "0", count: 40), message: "branch: Created from develop").replacingOccurrences(of: " +0800\t", with: " invalid\t")
            ] {
                try fixture.write(contents, at: fixture.branchLog)
                try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "invalid or incomplete creation evidence was accepted")
            }
        },
        CodexBarTestCase(name: "Git creation source rejects ambiguous shorthand but accepts explicit local refs") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.recordCreation(from: "develop")
            try fixture.write(fixture.oid + "\n", at: fixture.main.appendingPathComponent(".git/refs/tags/develop"))
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "a tag could be mistaken for the same-named local branch")
            try fixture.recordCreation(from: "refs/heads/develop")
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == "develop", "explicit local ref was treated as ambiguous")
            try fixture.recordCreation(from: "abcdef0")
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "hex shorthand could be mistaken for a commit")
        },
        CodexBarTestCase(name: "Git creation source rejects reflog histories inherited by copied or renamed branches") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            let creation = fixture.logEntry(from: String(repeating: "0", count: 40), message: "branch: Created from develop")
            for change in ["Branch: copied refs/heads/original to refs/heads/graph-runtime", "Branch: renamed refs/heads/original to refs/heads/graph-runtime"] {
                try fixture.recordCreation(from: "develop")
                try fixture.write(creation + fixture.logEntry(from: fixture.oid, message: change), at: fixture.branchLog)
                try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "copied or renamed branch claimed the old branch's creation source")
            }
        },
        CodexBarTestCase(name: "Git creation source rejects oversized reflogs and unsafe branch paths") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.recordCreation(from: "develop")
            let creation = fixture.logEntry(from: String(repeating: "0", count: 40), message: "branch: Created from develop")
            try fixture.write(creation + String(repeating: fixture.logEntry(from: fixture.oid, message: "commit: more"), count: 2_000), at: fixture.branchLog)
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "oversized history was partially trusted")
            for branch in ["../outside", "feature/../../outside", "feature.lock", "feature@{1}", "/absolute"] {
                try fixture.write("ref: refs/heads/\(branch)\n", at: fixture.linkedGit.appendingPathComponent("HEAD"))
                try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path) == nil, "unsafe branch ref was accepted")
            }
        },
        CodexBarTestCase(name: "Git creation metadata cannot follow reflog or ref symlinks outside the repository") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try fixture.recordCreation(from: "develop")
            let outside = fixture.root.appendingPathComponent("outside-log")
            try FileManager.default.moveItem(at: fixture.branchLog, to: outside)
            try FileManager.default.createSymbolicLink(at: fixture.branchLog, withDestinationURL: outside)
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "external reflog was read")
            try FileManager.default.removeItem(at: fixture.branchLog)
            try fixture.recordCreation(from: "develop")
            let sourceRef = fixture.main.appendingPathComponent(".git/refs/heads/develop")
            let outsideRef = fixture.root.appendingPathComponent("outside-ref")
            try FileManager.default.moveItem(at: sourceRef, to: outsideRef)
            try FileManager.default.createSymbolicLink(at: sourceRef, withDestinationURL: outsideRef)
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path)?.sourceBranch == nil, "external source ref was read")
        },
        CodexBarTestCase(name: "Git identity rejects missing and malformed metadata") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.root.path) == nil, "non-Git directory matched")
            try expect(GitWorkspaceIdentityReader.read(cwd: "") == nil, "empty path matched")
            try expect(GitWorkspaceIdentityReader.read(cwd: "relative/project") == nil, "relative path matched")
            try fixture.write("not a gitfile\n", at: fixture.linked.appendingPathComponent(".git"))
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path) == nil, "bad gitfile matched")
            try fixture.write("gitdir: missing\n", at: fixture.linked.appendingPathComponent(".git"))
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path) == nil, "missing Git directory matched")
            try fixture.write("ref: refs/heads/" + String(repeating: "x", count: 20_000), at: fixture.main.appendingPathComponent(".git/HEAD"))
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.main.path) == nil, "oversized HEAD was accepted")
        },
        CodexBarTestCase(name: "Git identity rejects broken common directories and invalid HEAD contents") {
            let fixture = try GitWorkspaceFixture()
            defer { fixture.remove() }
            let common = fixture.linkedGit.appendingPathComponent("commondir")
            try fixture.write("../../missing\n", at: common)
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path) == nil, "missing common directory matched")
            try fixture.write("../..\nextra", at: common)
            try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path) == nil, "multiline metadata matched")
            try fixture.write("../..\n", at: common)
            for contents in ["ref: refs/heads/\n", "ref: refs/heads/not a branch\n", "bad-head\n"] {
                try fixture.write(contents, at: fixture.linkedGit.appendingPathComponent("HEAD"))
                try expect(GitWorkspaceIdentityReader.read(cwd: fixture.linked.path) == nil, "invalid HEAD matched")
            }
        },
        CodexBarTestCase(name: "Git labels appear only for different workspaces in the same repository") {
            let main = gitLabelIdentity(root: "/work/repo", branch: "develop")
            let other = gitLabelIdentity(root: "/other/repo", branch: "feature", repository: "/other/repo/.git")
            try expect(GitWorkspaceIdentityReader.labels(identities: ["a": main, "b": other]).isEmpty, "unrelated repositories gained subtitles")
            try expect(GitWorkspaceIdentityReader.labels(identities: ["a": main, "a/src": main]).isEmpty, "two subdirectories counted as two worktrees")
            let linked = gitLabelIdentity(root: "/work/linked", branch: "graph-runtime", linked: true)
            let labels = GitWorkspaceIdentityReader.labels(identities: ["a": main, "b": linked])
            try expect(labels.count == 2, "paired workspaces have no labels")
            try expect(labels["a"]?.shortBranch == "develop", "main checkout was hardcoded to main")
            try expect(labels["b"]?.branch == "graph-runtime" && labels["b"]?.isLinkedWorktree == true, "full branch or worktree marker was lost")
        },
        CodexBarTestCase(name: "Git labels preserve the different parts of long branch names") {
            let first = gitLabelIdentity(root: "/work/a", branch: "feature/graph-runtime")
            let second = gitLabelIdentity(root: "/work/b", branch: "feature/graph-renderer", linked: true)
            let labels = GitWorkspaceIdentityReader.labels(identities: ["a": first, "b": second])
            let a = try require(labels["a"], "first branch label missing")
            let b = try require(labels["b"], "second branch label missing")
            try expect(a.shortBranch != b.shortBranch, "long branch labels collide")
            try expect(a.shortBranch.contains("runtime") && b.shortBranch.contains("render"), "labels lost the distinguishing branch component")
            try expect(a.shortBranch.count <= 8 && b.shortBranch.count <= 8, "labels exceeded the compact budget")
        },
        CodexBarTestCase(name: "Git label collisions have stable unique abbreviations") {
            let identities = [
                "a": gitLabelIdentity(root: "/work/a", branch: "release/abcdefgh-one"),
                "a/src": gitLabelIdentity(root: "/work/a", branch: "release/abcdefgh-one"),
                "b": gitLabelIdentity(root: "/work/b", branch: "release/abcdefgh-two", linked: true),
                "c": gitLabelIdentity(root: "/work/c", branch: "develop", linked: true),
                "d": gitLabelIdentity(root: "/work/d", branch: "develop", linked: true)
            ]
            let labels = GitWorkspaceIdentityReader.labels(identities: identities)
            let reversed = Dictionary(uniqueKeysWithValues: identities.sorted { $0.key > $1.key })
            try expect(labels == GitWorkspaceIdentityReader.labels(identities: reversed), "labels depend on dictionary insertion order")
            try expect(labels["a"] == labels["a/src"], "the same workspace gets different labels")
            let shortNames = ["a", "b", "c", "d"].compactMap { labels[$0]?.shortBranch }
            try expect(Set(shortNames).count == 4, "different workspaces have indistinguishable labels")
            try expect(shortNames.allSatisfy { $0.count <= 8 }, "collision labels exceed the compact budget")
        },
        CodexBarTestCase(name: "Git labels fit Chinese and emoji branches within eight display units") {
            let branches = [
                "功能/图运行时开发", "功能/图渲染器开发",
                "👩‍💻👩‍💻👩‍💻👩‍💻开发一", "👩‍💻👩‍💻👩‍💻👩‍💻开发二",
                "重复分支名称", "重复分支名称"
            ]
            let identities = Dictionary(uniqueKeysWithValues: branches.enumerated().map { index, branch in
                ("\(index)", gitLabelIdentity(root: "/work/\(index)", branch: branch, linked: index > 0))
            })
            let labels = GitWorkspaceIdentityReader.labels(identities: identities)
            let shortNames = labels.values.map(\.shortBranch)
            try expect(shortNames.count == branches.count && Set(shortNames).count == branches.count, "wide branch labels collide")
            try expect(shortNames.allSatisfy { branch in
                branch.reduce(0) { width, character in
                    width + (character == "…" || character.unicodeScalars.allSatisfy(\.isASCII) ? 1 : 2)
                } <= 8
            }, "wide branch text exceeds the narrow subtitle width")
            try expect(labels["0"]?.branch == branches[0] && labels["2"]?.branch == branches[2], "full Unicode branch names were changed")
        }
    ]
}

private func gitLabelIdentity(
    root: String, branch: String, linked: Bool = false, repository: String = "/work/repo/.git"
) -> GitWorkspaceIdentity {
    GitWorkspaceIdentity(
        repositoryID: repository, workspaceRoot: root, repositoryName: "repo",
        branch: branch, isLinkedWorktree: linked, headPath: root + "/.git/HEAD"
    )
}

private struct GitWorkspaceFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarGit-\(UUID().uuidString)")
    var main: URL { root.appendingPathComponent("sample-project") }
    var linked: URL { root.appendingPathComponent("sample-project-graph-runtime") }
    var linkedGit: URL { main.appendingPathComponent(".git/worktrees/graph-runtime") }
    var branchLog: URL { main.appendingPathComponent(".git/logs/refs/heads/graph-runtime") }
    let oid = String(repeating: "a", count: 40)

    init() throws {
        try write("ref: refs/heads/develop\n", at: main.appendingPathComponent(".git/HEAD"))
        try write("gitdir: ../sample-project/.git/worktrees/graph-runtime\n", at: linked.appendingPathComponent(".git"))
        try write("../..\n", at: linkedGit.appendingPathComponent("commondir"))
        try write("ref: refs/heads/graph-runtime\n", at: linkedGit.appendingPathComponent("HEAD"))
    }

    func write(_ contents: String, at path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path)
    }

    func recordCreation(from source: String) throws {
        let name = source.hasPrefix("refs/heads/") ? String(source.dropFirst(11)) : source
        try write(oid + "\n", at: main.appendingPathComponent(".git/refs/heads/\(name)"))
        try write(oid + "\n", at: main.appendingPathComponent(".git/refs/heads/graph-runtime"))
        try write(logEntry(from: String(repeating: "0", count: 40), message: "branch: Created from \(source)"), at: branchLog)
    }

    func logEntry(from oldOID: String, message: String) -> String {
        "\(oldOID) \(oid) Developer <dev@example.test> 1789372800 +0800\t\(message)\n"
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
