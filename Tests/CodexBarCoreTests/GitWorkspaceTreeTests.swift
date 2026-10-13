import CodexBarCore
import Foundation

@MainActor
func gitWorkspaceTreeTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "ordinary projects sink below Git repositories with one separate heading") {
            let plain = gitTreeRow("简历"), english = gitTreeRow("documents")
            let repository = gitTreeRow("中文仓库"), multiRoot = gitTreeRow("多项目工作区", multiRoot: true)
            let idle = VSCodeTaskRow(workspace: .folder("/work/虚拟商品聚合系统"))
            let inputs = [plain, repository, english, multiRoot, idle]
            let groups = GitWorkspaceTree.groups(rows: inputs, labels: [
                repository.rootPath: gitTreeLabel(repository, branch: "main")
            ])
            try expect(groups.map(\.projectName) == ["arbitrary-project", "普通项目"],
                       "ordinary projects did not move below Git repositories with their own heading")
            try expect(groups.flatMap(\.rows).map(\.row) == [repository, plain, english, multiRoot, idle]
                       && Set(groups.map(\.id)).count == 2,
                       "moving ordinary projects changed their relative order or lost a row")
            try expect(groups.last?.repositoryName == nil && groups.last?.rows.allSatisfy { $0.label == nil } == true,
                       "ordinary project headings fabricated Git identity or branch labels")
            try expect(CodexBarPanelLayout.rowHeights(groups: groups) == [58, 46, 28, 28, 40],
                       "plain project headers or idle rows did not receive enough vertical space")
            try expect(GitWorkspaceTree.groups(rows: [], labels: [:]).isEmpty, "empty input created an ordinary section")
            let onlyGit = GitWorkspaceTree.groups(rows: [repository], labels: [repository.rootPath: gitTreeLabel(repository, branch: "main")])
            try expect(onlyGit.count == 1 && onlyGit[0].repositoryName != nil, "Git-only input created an empty ordinary section")
            let onlyPlain = GitWorkspaceTree.groups(rows: [plain, english], labels: [:])
            try expect(onlyPlain.count == 1 && onlyPlain[0].rows.map(\.row) == [plain, english],
                       "ordinary-only input did not retain its rows in one section")
        },
        CodexBarTestCase(name: "Git tree preserves directory ancestry when the root and parent change branches") {
            let primary = gitTreeRow("primary"), a = gitTreeRow("a"), b = gitTreeRow("b"), c = gitTreeRow("c")
            let inputs = [c, b, a, primary]
            let records = [gitTreeRecord(primary, main: true), gitTreeRecord(a, parent: primary, order: 1),
                           gitTreeRecord(b, parent: primary, order: 2), gitTreeRecord(c, parent: a, order: 3)]
            var labels = [primary.rootPath: gitTreeLabel(primary, branch: "main"),
                          a.rootPath: gitTreeLabel(a, branch: "a", source: "main", linked: true),
                          b.rootPath: gitTreeLabel(b, branch: "b", source: "main", linked: true),
                          c.rootPath: gitTreeLabel(c, branch: "c", source: "a", linked: true)]
            let initial = GitWorkspaceTree.groups(rows: inputs, labels: labels, creationRecords: records)
            labels[primary.rootPath] = gitTreeLabel(primary, branch: "dev")
            labels[a.rootPath] = gitTreeLabel(a, branch: "z-feature", source: "main", linked: true)
            let switched = GitWorkspaceTree.groups(rows: inputs.reversed(), labels: labels, creationRecords: records)
            let rows = switched.flatMap(\.rows)
            try expect(rows.map(\.id) == [primary.id, a.id, c.id, b.id], "branch labels reordered directory nodes")
            try expect(rows.map(\.depth) == [0, 1, 2, 1], "branch switch changed nesting")
            try expect(rows.map(\.parentRowID) == [nil, primary.id, a.id, primary.id], "branch switch changed parents")
            try expect(rows.map(\.parentRowID) == initial.flatMap(\.rows).map(\.parentRowID), "creation ancestry changed")
            try expect(initial.map(\.id) == switched.map(\.id), "branch switch changed repository identity")
            try expect(rows[0].label?.branch == "dev" && rows[1].label?.branch == "z-feature", "branch labels were frozen")
        },
        CodexBarTestCase(name: "Git workspace roles retain caption space at every tree depth") {
            let primary = gitTreeRow("primary"), child = gitTreeRow("child"), nested = gitTreeRow("nested")
            let idle = VSCodeTaskRow(workspace: .folder("/work/idle")), plain = gitTreeRow("plain")
            let labels = [primary.rootPath: gitTreeLabel(primary, branch: "main"),
                          child.rootPath: gitTreeLabel(child, branch: "feature", linked: true),
                          nested.rootPath: gitTreeLabel(nested, branch: "feature-child", linked: true),
                          idle.rootPath: gitTreeLabel(idle, branch: "idle", linked: true)]
            let records = [gitTreeRecord(primary, main: true), gitTreeRecord(child, parent: primary),
                           gitTreeRecord(nested, parent: child)]
            let rows = GitWorkspaceTree.groups(rows: [primary, child, nested, idle, plain], labels: labels,
                                               creationRecords: records).flatMap(\.rows)
            for (row, expectedHeight) in [(primary, 40.0), (child, 40.0), (nested, 52.0), (idle, 52.0), (plain, 28.0)] {
                let projected = try require(rows.first { $0.id == row.id }, "workspace disappeared")
                try expect(CodexBarPanelLayout.rowHeight(for: projected) == expectedHeight, "workspace caption was clipped")
            }
        },
        CodexBarTestCase(name: "an opened idle directory remains the parent of its active child") {
            let parent = VSCodeTaskRow(workspace: .folder("/work/main")), child = gitTreeRow("feature", status: .running)
            let labels = [parent.rootPath: gitTreeLabel(parent, branch: "dev"),
                          child.rootPath: gitTreeLabel(child, branch: "feature", linked: true)]
            let records = [gitTreeRecord(parent, main: true), gitTreeRecord(child, parent: parent)]
            let rows = GitWorkspaceTree.groups(rows: [child, parent], labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.map(\.id) == [parent.id, child.id], "idle parent was dropped or moved below its child")
            try expect(rows[0].row.task == nil && rows[1].row.task == child.task, "grouping fabricated or changed a task")
            try expect(rows[1].parentRowID == parent.id && rows[1].depth == 1, "task absence removed directory ancestry")
            try expect(CodexBarPanelLayout.rowHeight(for: rows[0]) == CodexBarPanelLayout.branchRowHeight + 12,
                       "idle caption has no layout space")
        },
        CodexBarTestCase(name: "Git tree keeps repository priority and ordinary row order within separate regions") {
            let child = gitTreeRow("child"), neighbor = gitTreeRow("neighbor"), parent = gitTreeRow("parent"), last = gitTreeRow("last")
            let labels = [child.rootPath: gitTreeLabel(child, branch: "child", linked: true),
                          parent.rootPath: gitTreeLabel(parent, branch: "main")]
            let groups = GitWorkspaceTree.groups(rows: [child, neighbor, parent, last], labels: labels,
                creationRecords: [gitTreeRecord(parent, main: true), gitTreeRecord(child, parent: parent)])
            try expect(groups.count == 2 && groups[0].repositoryName == "arbitrary-project", "repository group changed")
            try expect(groups[0].rows.map(\.id) == [parent.id, child.id], "parent did not precede child")
            try expect(groups[1].rows.map(\.id) == [neighbor.id, last.id],
                       "unrelated task priority changed")
            try expect(groups[1].repositoryName == nil, "ordinary row gained a repository heading")
        },
        CodexBarTestCase(name: "Git tree keeps branch-derived origins flat without recorded directory ancestry") {
            let parent = gitTreeRow("main"), child = gitTreeRow("feature")
            let labels = [parent.rootPath: gitTreeLabel(parent, branch: "main"),
                          child.rootPath: gitTreeLabel(child, branch: "feature", source: "main", linked: true)]
            let rows = GitWorkspaceTree.groups(rows: [parent, child], labels: labels).flatMap(\.rows)
            try expect(rows.allSatisfy { $0.depth == 0 && $0.parentRowID == nil }, "sourceBranch guessed a directory parent")
        },
        CodexBarTestCase(name: "Git tree does not fabricate a task for a closed parent directory") {
            let parent = gitTreeRow("closed"), child = gitTreeRow("child"), grandchild = gitTreeRow("grandchild")
            let labels = [child.rootPath: gitTreeLabel(child, branch: "feature", linked: true),
                          grandchild.rootPath: gitTreeLabel(grandchild, branch: "nested", linked: true)]
            let records = [gitTreeRecord(parent, main: true), gitTreeRecord(child, parent: parent),
                           gitTreeRecord(grandchild, parent: child)]
            let rows = GitWorkspaceTree.groups(rows: [grandchild, child], labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.map(\.row) == [child, grandchild], "closed parent fabricated a task or removed an actual row")
            try expect(rows[0].depth == 0 && rows[0].parentRowID == nil, "child connects to a nonexistent row")
            try expect(rows[1].depth == 1 && rows[1].parentRowID == child.id, "existing descendant lost its real parent")
        },
        CodexBarTestCase(name: "Git tree separates repositories and ignores untrusted or multi-root labels") {
            let first = gitTreeRow("first"), second = gitTreeRow("second"), unknown = gitTreeRow("unknown")
            let multiRoot = gitTreeRow("workspace", multiRoot: true)
            let labels = [first.rootPath: gitTreeLabel(first, branch: "main", repository: "/one/.git"),
                          second.rootPath: gitTreeLabel(second, branch: "child", repository: "/two/.git"),
                          unknown.rootPath: gitTreeLabel(unknown, branch: "main", repository: ""),
                          multiRoot.rootPath: gitTreeLabel(multiRoot, branch: "workspace", repository: "/one/.git")]
            let groups = GitWorkspaceTree.groups(rows: [unknown, second, multiRoot, first], labels: labels,
                creationRecords: [gitTreeRecord(first, repository: "/one/.git", main: true),
                                  gitTreeRecord(second, parent: first, repository: "/two/.git")])
            try expect(groups.count == 3 && Set(groups.map(\.id)).count == 3, "unrelated repositories merged")
            try expect(groups[0].rows[0].row == second && groups[1].rows[0].row == first,
                       "moving ordinary rows changed Git repository priority")
            try expect(groups[0].rows[0].parentRowID == nil, "cross-repository connection appeared")
            try expect(groups[2].rows.map(\.row) == [unknown, multiRoot] && groups[2].rows.allSatisfy { $0.label == nil },
                       "untrusted labels were used or ordinary row order changed")
        },
        CodexBarTestCase(name: "Git tree rejects a parent record whose repository conflicts with the actual row") {
            let parent = gitTreeRow("parent"), child = gitTreeRow("child")
            let labels = [parent.rootPath: gitTreeLabel(parent, branch: "parent"),
                          child.rootPath: gitTreeLabel(child, branch: "child", linked: true)]
            let records = [gitTreeRecord(parent, repository: "/foreign/.git"), gitTreeRecord(child, parent: parent)]
            let rows = GitWorkspaceTree.groups(rows: [parent, child], labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.allSatisfy { $0.parentRowID == nil }, "a stale cross-repository record connected rows")
        },
        CodexBarTestCase(name: "Git tree flattens cyclic directory records and their descendants") {
            let a = gitTreeRow("a"), b = gitTreeRow("b"), child = gitTreeRow("child"), selfReference = gitTreeRow("self")
            let inputs = [a, b, child, selfReference]
            let labels = Dictionary(uniqueKeysWithValues: inputs.map { ($0.rootPath, gitTreeLabel($0, branch: "same", linked: true)) })
            let records = [gitTreeRecord(a, parent: b), gitTreeRecord(b, parent: a),
                           gitTreeRecord(child, parent: a), gitTreeRecord(selfReference, parent: selfReference)]
            let rows = GitWorkspaceTree.groups(rows: inputs, labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.count == inputs.count, "cycle dropped or duplicated a task")
            try expect(rows.allSatisfy { $0.depth == 0 && $0.parentRowID == nil }, "cycle created a false hierarchy")
        },
        CodexBarTestCase(name: "Git tree keeps separate directories on the same branch in their recorded positions") {
            let root = gitTreeRow("root"), a = gitTreeRow("a"), b = gitTreeRow("b"), child = gitTreeRow("child")
            let inputs = [b, child, root, a]
            let labels = Dictionary(uniqueKeysWithValues: inputs.map {
                ($0.rootPath, gitTreeLabel($0, branch: "same", linked: $0.id != root.id))
            })
            let records = [gitTreeRecord(root, main: true), gitTreeRecord(a, parent: root, order: 1),
                           gitTreeRecord(b, parent: root, order: 2), gitTreeRecord(child, parent: b, order: 3)]
            let rows = GitWorkspaceTree.groups(rows: inputs, labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.map(\.id) == [root.id, a.id, b.id, child.id], "same branch merged or relocated workspaces")
            try expect(rows.map(\.parentRowID) == [nil, root.id, root.id, b.id], "branch equality changed parents")
        },
        CodexBarTestCase(name: "Git tree never chooses an arbitrary window of a duplicated checkout as parent") {
            let first = gitTreeRow("first"), second = gitTreeRow("second"), child = gitTreeRow("child")
            let labels = [first.rootPath: gitTreeLabel(first, branch: "main", workspaceRoot: "/shared"),
                          second.rootPath: gitTreeLabel(second, branch: "main", workspaceRoot: "/shared"),
                          child.rootPath: gitTreeLabel(child, branch: "child", linked: true)]
            let records = [gitTreeRecord(first, workspaceRoot: "/shared", main: true),
                           gitTreeRecord(child, parentWorkspaceRoot: "/shared")]
            let rows = GitWorkspaceTree.groups(rows: [child, second, first], labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.count == 3 && rows.allSatisfy { $0.parentRowID == nil }, "duplicate windows were guessed or merged")
        },
        CodexBarTestCase(name: "Git tree ignores duplicate creation records instead of choosing an arbitrary parent") {
            let root = gitTreeRow("root"), a = gitTreeRow("a"), child = gitTreeRow("child")
            let inputs = [root, a, child]
            let labels = Dictionary(uniqueKeysWithValues: inputs.map { ($0.rootPath, gitTreeLabel($0, branch: "same", linked: true)) })
            let records = [gitTreeRecord(root), gitTreeRecord(a, parent: root), gitTreeRecord(a), gitTreeRecord(child, parent: a)]
            let rows = GitWorkspaceTree.groups(rows: inputs, labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.count == inputs.count && rows.allSatisfy { $0.parentRowID == nil }, "duplicate records guessed ancestry")
        },
        CodexBarTestCase(name: "Git tree sorts by creation order then directory without following branch or task priority") {
            let root = gitTreeRow("root"), early = gitTreeRow("z-early"), late = gitTreeRow("a-late")
            let records = [gitTreeRecord(root, order: 99, main: true), gitTreeRecord(early, order: 1), gitTreeRecord(late, order: 2)]
            let labels = [root.rootPath: gitTreeLabel(root, branch: "z-main"),
                          early.rootPath: gitTreeLabel(early, branch: "z-feature", linked: true),
                          late.rootPath: gitTreeLabel(late, branch: "a-feature", linked: true)]
            let initial = GitWorkspaceTree.groups(rows: [late, early, root], labels: labels, creationRecords: records)
            let activeRoot = gitTreeRow("root", status: .running)
            let changed = GitWorkspaceTree.groups(rows: [activeRoot, late, early], labels: labels, creationRecords: records)
            try expect(initial.map(\.id) == changed.map(\.id), "group identity depends on task status")
            try expect(initial.flatMap(\.rows).map(\.id) == [root.id, early.id, late.id], "creation order or main priority was ignored")
            try expect(changed.flatMap(\.rows).map(\.id) == initial.flatMap(\.rows).map(\.id), "task priority changed sibling order")
            try expect(changed[0].rows[0].row == activeRoot, "projection changed the actual task state")
            let tied = [gitTreeRecord(root, main: true), gitTreeRecord(early, order: 1), gitTreeRecord(late, order: 1)]
            let tieRows = GitWorkspaceTree.groups(rows: [early, root, late], labels: labels, creationRecords: tied).flatMap(\.rows)
            try expect(tieRows.map(\.id) == [root.id, late.id, early.id], "creation ties were not sorted by directory")
            let lastOrder = [gitTreeRecord(root, main: true), gitTreeRecord(early, order: .max)]
            let unknownOrder = GitWorkspaceTree.groups(rows: [early, late, root], labels: labels,
                                                       creationRecords: lastOrder).flatMap(\.rows)
            try expect(unknownOrder.map(\.id) == [root.id, late.id, early.id], "unknown creation order broke directory tie ordering")
        },
        CodexBarTestCase(name: "Git tree supplies sibling and ancestor continuation lines for directory ancestry") {
            let root = gitTreeRow("root"), a = gitTreeRow("z-first"), b = gitTreeRow("a-second"), grandchild = gitTreeRow("grandchild")
            let inputs = [b, grandchild, a, root]
            let labels = Dictionary(uniqueKeysWithValues: inputs.map { ($0.rootPath, gitTreeLabel($0, branch: $0.id, linked: $0.id != root.id)) })
            let records = [gitTreeRecord(root, main: true), gitTreeRecord(a, parent: root, order: 1),
                           gitTreeRecord(b, parent: root, order: 2), gitTreeRecord(grandchild, parent: a, order: 3)]
            let rows = GitWorkspaceTree.groups(rows: inputs, labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.map(\.id) == [root.id, a.id, grandchild.id, b.id], "tree is not in creation-ordered depth-first order")
            try expect(!rows[1].isLastSibling && rows[3].isLastSibling, "sibling elbow markers are incorrect")
            try expect(rows[2].depth == 2 && rows[2].parentRowID == a.id, "grandchild parent or depth is incorrect")
            try expect(rows[2].ancestorContinuationLevels == [1] && rows[3].ancestorContinuationLevels.isEmpty,
                       "ancestor continuation lines are incorrect")
        },
        CodexBarTestCase(name: "Git tree preserves eight nested worktrees without flattening deep directories") {
            let inputs = (0...8).map { gitTreeRow("directory-\($0)") }
            let labels = Dictionary(uniqueKeysWithValues: inputs.enumerated().map { index, row in
                (row.rootPath, gitTreeLabel(row, branch: "same", linked: index != 0))
            })
            let records = inputs.enumerated().map { index, row in
                gitTreeRecord(row, parent: index > 0 ? inputs[index - 1] : nil, order: index, main: index == 0)
            }
            let rows = GitWorkspaceTree.groups(rows: inputs.reversed(), labels: labels, creationRecords: records).flatMap(\.rows)
            try expect(rows.map(\.id) == inputs.map(\.id) && rows.map(\.depth) == Array(0...8), "deep directories were flattened or reordered")
            try expect(rows.last?.parentRowID == inputs[7].id, "deep directory lost its direct parent")
        }
    ]
}

private func gitTreeRow(_ id: String, multiRoot: Bool = false, status: CodexTaskStatus = .ready) -> VSCodeTaskRow {
    let root = "/work/\(id)", date = Date(timeIntervalSince1970: 100)
    return VSCodeTaskRow(
        id: "window:\(id)", displayName: id, rootPath: root, isMultiRoot: multiRoot,
        task: CodexTask(id: "task:\(id)", sessionID: "session:\(id)", turnID: "turn:\(id)", cwd: root + "/src",
                       workspaceName: id, title: "Task \(id)", status: status, startedAt: date, updatedAt: date, isUnread: false)
    )
}

private func gitTreeLabel(
    _ row: VSCodeTaskRow, branch: String, source: String? = nil, linked: Bool = false,
    repository: String = "/work/repository/.git", workspaceRoot: String? = nil
) -> GitWorkspaceLabel {
    GitWorkspaceLabel(repositoryName: "arbitrary-project", branch: branch, shortBranch: branch,
                      isLinkedWorktree: linked, workspaceRoot: workspaceRoot ?? row.rootPath,
                      sourceBranch: source, repositoryID: repository)
}

private func gitTreeRecord(
    _ row: VSCodeTaskRow, parent: VSCodeTaskRow? = nil, order: Int = 0,
    repository: String = "/work/repository/.git", workspaceRoot: String? = nil,
    parentWorkspaceRoot: String? = nil, main: Bool = false
) -> GitWorkspaceRecord {
    GitWorkspaceRecord(workspaceRoot: workspaceRoot ?? row.rootPath, repositoryID: repository,
                       parentWorkspaceRoot: parentWorkspaceRoot ?? parent?.rootPath, order: order, isMainWorkspace: main)
}
