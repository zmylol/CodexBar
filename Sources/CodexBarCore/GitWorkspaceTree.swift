public struct GitWorkspaceGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let repositoryName: String?
    public let rows: [GitWorkspaceTreeRow]
    public var projectName: String { repositoryName ?? "普通项目" }
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
    /// Preserves repository priority and places ordinary projects in a separate section below them.
    public static func groups(
        rows: [VSCodeTaskRow], labels: [String: GitWorkspaceLabel],
        creationRecords: [GitWorkspaceRecord] = []
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
        let groups = groupedRows.map { rows in
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
            let treeRows = tree(rows: rows, labels: labels, creationRecords: creationRecords)
            return GitWorkspaceGroup(
                id: "repository:\(label.repositoryID)",
                repositoryName: treeRows.first?.label?.repositoryName,
                rows: treeRows
            )
        }
        let ordinaryRows = groups.filter { $0.repositoryName == nil }.flatMap(\.rows)
        let repositories = groups.filter { $0.repositoryName != nil }
        return ordinaryRows.isEmpty ? repositories : repositories + [
            GitWorkspaceGroup(id: "ordinary-projects", repositoryName: nil, rows: ordinaryRows)
        ]
    }

    private static func tree(
        rows: [VSCodeTaskRow], labels: [String: GitWorkspaceLabel],
        creationRecords: [GitWorkspaceRecord]
    ) -> [GitWorkspaceTreeRow] {
        let recordsByRoot = Dictionary(grouping: creationRecords, by: \.workspaceRoot)
        func record(for label: GitWorkspaceLabel) -> GitWorkspaceRecord? {
            guard let candidates = recordsByRoot[label.workspaceRoot], candidates.count == 1,
                  let record = candidates.first, record.repositoryID == label.repositoryID
            else { return nil }
            return record
        }
        let nodes = rows.compactMap { row -> (row: VSCodeTaskRow, label: GitWorkspaceLabel)? in
            labels[row.rootPath].map { (row, $0) }
        }.sorted {
            let first = record(for: $0.label), second = record(for: $1.label)
            let firstIsMain = first?.isMainWorkspace ?? !$0.label.isLinkedWorktree
            let secondIsMain = second?.isMainWorkspace ?? !$1.label.isLinkedWorktree
            if firstIsMain != secondIsMain { return firstIsMain }
            let firstOrder = first?.order ?? .max, secondOrder = second?.order ?? .max
            if firstOrder != secondOrder { return firstOrder < secondOrder }
            if $0.label.workspaceRoot != $1.label.workspaceRoot {
                return $0.label.workspaceRoot < $1.label.workspaceRoot
            }
            return $0.row.id < $1.row.id
        }
        let directories = Dictionary(grouping: nodes.indices, by: { nodes[$0].label.workspaceRoot })
        var parents: [Int: Int] = [:]
        for index in nodes.indices {
            let label = nodes[index].label
            guard directories[label.workspaceRoot]?.count == 1,
                  let source = record(for: label), !source.isMainWorkspace,
                  let parentRoot = source.parentWorkspaceRoot,
                  let candidates = directories[parentRoot], candidates.count == 1,
                  let parent = candidates.first, parent != index
            else { continue }

            // Validate the persisted chain even if some ancestor windows are closed.
            var visited = Set<String>()
            var cursor: String? = label.workspaceRoot
            var valid = true
            while let root = cursor {
                guard visited.insert(root).inserted else {
                    valid = false
                    break
                }
                guard let records = recordsByRoot[root] else { break }
                guard records.count == 1, let ancestor = records.first,
                      ancestor.repositoryID == label.repositoryID
                else {
                    valid = false
                    break
                }
                cursor = ancestor.parentWorkspaceRoot
            }
            if valid { parents[index] = parent }
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
