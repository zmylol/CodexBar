import CodexBarCore
import Foundation

@MainActor
func gitWorkspaceTreeTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "Git tree groups repositories at their first task priority position") {
            let child = gitTreeRow("child")
            let neighbor = gitTreeRow("neighbor")
            let parent = gitTreeRow("parent")
            let last = gitTreeRow("last")
            let labels = [
                child.rootPath: gitTreeLabel(child, branch: "graph-runtime", source: "main"),
                parent.rootPath: gitTreeLabel(parent, branch: "main")
            ]
            let groups = GitWorkspaceTree.groups(rows: [child, neighbor, parent, last], labels: labels)
            try expect(groups.count == 3, "related checkouts did not become a single contiguous group")
            try expect(groups[0].repositoryName == "arbitrary-project", "repository heading missing")
            try expect(groups[0].rows.map(\.id) == [parent.id, child.id], "parent did not precede child")
            try expect(groups[1].rows.map(\.id) == [neighbor.id] && groups[2].rows.map(\.id) == [last.id], "unrelated task priority changed")
            try expect(groups[1].repositoryName == nil, "ordinary row gained a repository heading")
        },
        CodexBarTestCase(name: "Git tree connects proven origins without hardcoded branch names") {
            let parent = gitTreeRow("stable")
            let child = gitTreeRow("compiler")
            let labels = [
                parent.rootPath: gitTreeLabel(parent, branch: "z-release"),
                child.rootPath: gitTreeLabel(child, branch: "a-compiler", source: "z-release", linked: true)
            ]
            let rows = GitWorkspaceTree.groups(rows: [child, parent], labels: labels).flatMap(\.rows)
            try expect(rows.map(\.id) == [parent.id, child.id], "alphabetical order displaced the parent")
            try expect(rows[0].depth == 0 && rows[0].parentRowID == nil, "parent is incorrectly indented")
            try expect(rows[1].depth == 1 && rows[1].parentRowID == parent.id, "proven source did not produce a child connection")
        },
        CodexBarTestCase(name: "Git tree keeps unknown origins flat even beside a main branch") {
            let main = gitTreeRow("main")
            let feature = gitTreeRow("feature")
            let labels = [
                main.rootPath: gitTreeLabel(main, branch: "main"),
                feature.rootPath: gitTreeLabel(feature, branch: "feature", linked: true)
            ]
            let rows = GitWorkspaceTree.groups(rows: [main, feature], labels: labels).flatMap(\.rows)
            try expect(rows.allSatisfy { $0.depth == 0 && $0.parentRowID == nil }, "common Git directory was mistaken for creation evidence")
        },
        CodexBarTestCase(name: "Git tree keeps a closed parent's origin text without inventing a task") {
            let child = gitTreeRow("child")
            let label = gitTreeLabel(child, branch: "feature", source: "release", linked: true)
            let groups = GitWorkspaceTree.groups(rows: [child], labels: [child.rootPath: label])
            let rows = groups.flatMap(\.rows)
            try expect(groups.count == 1 && groups[0].repositoryName == label.repositoryName, "single proven checkout lost its repository group")
            try expect(rows.count == 1 && rows[0].row == child, "closed parent created a synthetic task")
            try expect(rows[0].parentRowID == nil && rows[0].depth == 0, "child connects to a nonexistent row")
            try expect(rows[0].label?.sourceBranch == "release", "closed parent origin cannot be displayed")
        },
        CodexBarTestCase(name: "Git tree separates unrelated repositories and ignores untrusted or multi-root labels") {
            let first = gitTreeRow("first")
            let second = gitTreeRow("second")
            let unknown = gitTreeRow("unknown")
            let workspace = gitTreeRow("workspace", multiRoot: true)
            let labels = [
                first.rootPath: gitTreeLabel(first, branch: "main", repository: "/one/.git"),
                second.rootPath: gitTreeLabel(second, branch: "child", source: "main", repository: "/two/.git"),
                unknown.rootPath: gitTreeLabel(unknown, branch: "main", repository: ""),
                workspace.rootPath: gitTreeLabel(workspace, branch: "workspace", source: "main", repository: "/one/.git")
            ]
            let groups = GitWorkspaceTree.groups(rows: [first, second, unknown, workspace], labels: labels)
            try expect(groups.count == 4 && Set(groups.map(\.id)).count == 4, "same display name merged unrelated repositories")
            try expect(groups[0].id != groups[1].id && groups[1].rows[0].parentRowID == nil, "cross-repository parent connection appeared")
            try expect(groups[2].repositoryName == nil && groups[2].rows[0].label == nil, "missing repository identity was trusted")
            try expect(groups[3].repositoryName == nil && groups[3].rows[0].label == nil, "multi-project workspace was grouped under a contained repository")
        },
        CodexBarTestCase(name: "Git tree flattens cyclic origins and their descendants") {
            let a = gitTreeRow("a")
            let b = gitTreeRow("b")
            let child = gitTreeRow("child")
            let selfReference = gitTreeRow("self")
            let labels = [
                a.rootPath: gitTreeLabel(a, branch: "a", source: "b"),
                b.rootPath: gitTreeLabel(b, branch: "b", source: "a"),
                child.rootPath: gitTreeLabel(child, branch: "child", source: "a"),
                selfReference.rootPath: gitTreeLabel(selfReference, branch: "self", source: "self")
            ]
            let rows = GitWorkspaceTree.groups(rows: [a, b, child, selfReference], labels: labels).flatMap(\.rows)
            try expect(rows.count == 4, "cycle dropped or duplicated a task")
            try expect(rows.allSatisfy { $0.depth == 0 && $0.parentRowID == nil }, "cyclic branch names created a guessed hierarchy")
            try expect(rows.allSatisfy { $0.label?.sourceBranch != nil }, "flattening removed creation evidence")
        },
        CodexBarTestCase(name: "Git tree rejects ambiguous branch parents and duplicate branch children") {
            let parentOne = gitTreeRow("parent-one")
            let parentTwo = gitTreeRow("parent-two")
            let child = gitTreeRow("child")
            let base = gitTreeRow("base")
            let labels = [
                parentOne.rootPath: gitTreeLabel(parentOne, branch: "parent", source: "base"),
                parentTwo.rootPath: gitTreeLabel(parentTwo, branch: "parent", source: "base"),
                child.rootPath: gitTreeLabel(child, branch: "child", source: "parent"),
                base.rootPath: gitTreeLabel(base, branch: "base")
            ]
            let rows = GitWorkspaceTree.groups(rows: [parentOne, parentTwo, child, base], labels: labels).flatMap(\.rows)
            try expect(rows.count == 4, "duplicate branch names merged actual windows")
            try expect(rows.allSatisfy { $0.depth == 0 && $0.parentRowID == nil }, "ambiguous branches participated in the tree")
        },
        CodexBarTestCase(name: "Git tree never connects two windows of the same checkout") {
            let parent = gitTreeRow("parent-window")
            let child = gitTreeRow("nested-window")
            let labels = [
                parent.rootPath: gitTreeLabel(parent, branch: "parent", workspaceRoot: "/shared-checkout"),
                child.rootPath: gitTreeLabel(child, branch: "child", source: "parent", workspaceRoot: "/shared-checkout")
            ]
            let rows = GitWorkspaceTree.groups(rows: [parent, child], labels: labels).flatMap(\.rows)
            try expect(rows.count == 2 && rows.allSatisfy { $0.parentRowID == nil }, "checkout alias became a branch child")
        },
        CodexBarTestCase(name: "Git tree row and group identities survive task status priority changes") {
            let main = gitTreeRow("main")
            let one = gitTreeRow("one")
            let two = gitTreeRow("two")
            let labels = [
                main.rootPath: gitTreeLabel(main, branch: "main"),
                one.rootPath: gitTreeLabel(one, branch: "feature", workspaceRoot: "/one"),
                two.rootPath: gitTreeLabel(two, branch: "feature", workspaceRoot: "/two")
            ]
            let initial = GitWorkspaceTree.groups(rows: [two, main, one], labels: labels)
            let activeMain = gitTreeRow("main", status: .running)
            let changed = GitWorkspaceTree.groups(rows: [activeMain, one, two], labels: labels)
            try expect(initial.map(\.id) == changed.map(\.id), "group identity depends on first active task")
            try expect(initial.flatMap(\.rows).map(\.id) == changed.flatMap(\.rows).map(\.id), "branch order depends on task activity")
            try expect(changed[0].rows.map(\.id) == [one.id, two.id, main.id], "equal branches are not stably ordered by checkout")
            try expect(changed.flatMap(\.rows).first { $0.id == main.id }?.row == activeMain, "projection changed the task cwd, session, or state")
            let actualRows = changed.flatMap(\.rows).map(\.row).sorted { $0.id < $1.id }
            let expectedRows = [activeMain, one, two].sorted { $0.id < $1.id }
            try expect(actualRows == expectedRows, "projection changed rows")
        },
        CodexBarTestCase(name: "Git tree supplies sibling and ancestor continuation lines") {
            let root = gitTreeRow("root")
            let a = gitTreeRow("a")
            let b = gitTreeRow("b")
            let grandchild = gitTreeRow("grandchild")
            let labels = [
                root.rootPath: gitTreeLabel(root, branch: "root"),
                a.rootPath: gitTreeLabel(a, branch: "a", source: "root"),
                b.rootPath: gitTreeLabel(b, branch: "b", source: "root"),
                grandchild.rootPath: gitTreeLabel(grandchild, branch: "grandchild", source: "a")
            ]
            let rows = GitWorkspaceTree.groups(rows: [b, grandchild, a, root], labels: labels).flatMap(\.rows)
            try expect(rows.map(\.id) == [root.id, a.id, grandchild.id, b.id], "tree is not in depth-first parent order")
            try expect(!rows[1].isLastSibling && rows[3].isLastSibling, "sibling elbow markers are incorrect")
            try expect(rows[2].depth == 2 && rows[2].parentRowID == a.id, "grandchild parent or depth is incorrect")
            try expect(rows[2].ancestorContinuationLevels == [1], "later parent's sibling lost its continuing vertical line")
            try expect(rows[3].ancestorContinuationLevels.isEmpty, "completed ancestor line leaked into another sibling")
        },
        CodexBarTestCase(name: "Git tree flattens origins beyond three indentation levels") {
            let inputs = (0..<6).map { gitTreeRow("branch-\($0)") }
            let labels = Dictionary(uniqueKeysWithValues: inputs.enumerated().map { index, row in
                (row.rootPath, gitTreeLabel(row, branch: "branch-\(index)", source: index > 0 ? "branch-\(index - 1)" : nil))
            })
            let rows = GitWorkspaceTree.groups(rows: Array(inputs.reversed()), labels: labels).flatMap(\.rows)
            try expect(rows.count == inputs.count && rows.map(\.depth).max() == 3, "deep tree exceeds the narrow panel's indentation limit")
            for index in 4..<6 {
                let row = try require(rows.first { $0.id == inputs[index].id }, "deep branch disappeared")
                try expect(row.depth == 0 && row.parentRowID == nil && row.ancestorContinuationLevels.isEmpty, "deep branch was attached to a false ancestor")
                try expect(row.label?.sourceBranch == "branch-\(index - 1)", "deep branch lost its source explanation")
            }
        }
    ]
}

private func gitTreeRow(
    _ id: String, multiRoot: Bool = false, status: CodexTaskStatus = .ready
) -> VSCodeTaskRow {
    let root = "/work/\(id)"
    let date = Date(timeIntervalSince1970: 100)
    return VSCodeTaskRow(
        id: "window:\(id)", displayName: id, rootPath: root, isMultiRoot: multiRoot,
        task: CodexTask(
            id: "task:\(id)", sessionID: "session:\(id)", turnID: "turn:\(id)",
            cwd: root + "/src", workspaceName: id, title: "Task \(id)", status: status,
            startedAt: date, updatedAt: date, isUnread: false
        )
    )
}

private func gitTreeLabel(
    _ row: VSCodeTaskRow, branch: String, source: String? = nil, linked: Bool = false,
    repository: String = "/work/repository/.git", workspaceRoot: String? = nil
) -> GitWorkspaceLabel {
    GitWorkspaceLabel(
        repositoryName: "arbitrary-project", branch: branch, shortBranch: branch,
        isLinkedWorktree: linked, workspaceRoot: workspaceRoot ?? row.rootPath,
        sourceBranch: source, repositoryID: repository
    )
}
