public struct GitWorkspaceGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let repositoryName: String?
    public let rows: [GitWorkspaceTreeRow]
}

public struct GitWorkspaceTreeRow: Identifiable, Equatable, Sendable {
    public var id: String { row.id }
    public let row: VSCodeTaskRow
    public let label: GitWorkspaceLabel?
    public let depth: Int
    public let parentRowID: String?
    public let isLastSibling: Bool
    /// Ancestor depths with a later sibling, excluding the root and this row's depth.
    public let ancestorContinuationLevels: [Int]
}

public enum GitWorkspaceTree {
    /// Keeps each repository at its first task's priority position and each actual row intact.
    public static func groups(
        rows: [VSCodeTaskRow], labels: [String: GitWorkspaceLabel]
    ) -> [GitWorkspaceGroup] {
        var groupedRows: [[VSCodeTaskRow]] = []
        var repositoryIndices: [String: Int] = [:]
        for row in rows {
            guard !row.isMultiRoot, let label = labels[row.rootPath], !label.repositoryID.isEmpty else {
                groupedRows.append([row])
                continue
            }
            if let index = repositoryIndices[label.repositoryID] {
                groupedRows[index].append(row)
            } else {
                repositoryIndices[label.repositoryID] = groupedRows.count
                groupedRows.append([row])
            }
        }
        return groupedRows.map { rows in
            let first = rows[0]
            guard !first.isMultiRoot, let label = labels[first.rootPath], !label.repositoryID.isEmpty else {
                return GitWorkspaceGroup(
                    id: "row:\(first.id)", repositoryName: nil,
                    rows: [GitWorkspaceTreeRow(
                        row: first, label: nil, depth: 0, parentRowID: nil,
                        isLastSibling: true, ancestorContinuationLevels: []
                    )]
                )
            }
            let treeRows = tree(rows: rows, labels: labels)
            return GitWorkspaceGroup(
                id: "repository:\(label.repositoryID)",
                repositoryName: treeRows.first?.label?.repositoryName,
                rows: treeRows
            )
        }
    }

    private static func tree(
        rows: [VSCodeTaskRow], labels: [String: GitWorkspaceLabel]
    ) -> [GitWorkspaceTreeRow] {
        let nodes = rows.compactMap { row -> (row: VSCodeTaskRow, label: GitWorkspaceLabel)? in
            labels[row.rootPath].map { (row, $0) }
        }.sorted {
            if $0.label.branch != $1.label.branch { return $0.label.branch < $1.label.branch }
            if $0.label.workspaceRoot != $1.label.workspaceRoot {
                return $0.label.workspaceRoot < $1.label.workspaceRoot
            }
            return $0.row.id < $1.row.id
        }
        let branches = Dictionary(grouping: nodes.indices, by: { nodes[$0].label.branch })
        var candidateParents: [Int: Int] = [:]
        for index in nodes.indices {
            let label = nodes[index].label
            guard branches[label.branch]?.count == 1,
                  let sourceBranch = label.sourceBranch,
                  let candidates = branches[sourceBranch], candidates.count == 1,
                  let parent = candidates.first, parent != index,
                  nodes[parent].label.workspaceRoot != label.workspaceRoot else { continue }
            candidateParents[index] = parent
        }

        var parents: [Int: Int] = [:]
        for (index, parent) in candidateParents {
            var visited: Set<Int> = [index]
            var cursor: Int? = parent
            var depth = 0
            var cyclic = false
            while let ancestor = cursor {
                guard visited.insert(ancestor).inserted else {
                    cyclic = true
                    break
                }
                depth += 1
                cursor = candidateParents[ancestor]
            }
            // Cycles and rows beyond three levels stay flat, retaining sourceBranch as text.
            if !cyclic && depth <= 3 { parents[index] = parent }
        }
        var children: [Int: [Int]] = [:]
        for index in nodes.indices {
            if let parent = parents[index] { children[parent, default: []].append(index) }
        }
        let roots = nodes.indices.filter { parents[$0] == nil }
        var result: [GitWorkspaceTreeRow] = []
        func append(_ siblings: [Int], depth: Int, continuationLevels: [Int]) {
            for (position, index) in siblings.enumerated() {
                let last = position == siblings.count - 1
                result.append(GitWorkspaceTreeRow(
                    row: nodes[index].row, label: nodes[index].label, depth: depth,
                    parentRowID: parents[index].map { nodes[$0].row.id },
                    isLastSibling: last, ancestorContinuationLevels: continuationLevels
                ))
                let descendantLevels = depth > 0 && !last ? continuationLevels + [depth] : continuationLevels
                append(children[index] ?? [], depth: depth + 1, continuationLevels: descendantLevels)
            }
        }
        append(roots, depth: 0, continuationLevels: [])
        return result
    }
}
