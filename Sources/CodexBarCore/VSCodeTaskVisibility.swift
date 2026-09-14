public struct VSCodeTaskRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let rootPath: String
    public let isMultiRoot: Bool
    public let task: CodexTask?
    public let workspace: VSCodeWorkspaceIdentity?

    public init(
        id: String, displayName: String, rootPath: String, isMultiRoot: Bool, task: CodexTask,
        workspace: VSCodeWorkspaceIdentity? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.isMultiRoot = isMultiRoot
        self.task = task
        self.workspace = workspace
    }

    /// An opened workspace can exist before its first task or after a task is removed.
    public init(workspace: VSCodeWorkspaceIdentity) {
        self.id = "workspace:\(workspace.path)"
        self.displayName = workspace.displayName
        self.rootPath = workspace.path
        self.isMultiRoot = workspace.isMultiRoot
        self.task = nil
        self.workspace = workspace
    }
}

public struct VSCodeTaskVisibility: Sendable {
    private var windows: [VSCodeWindowDescriptor]?

    public init() {}

    public var hasNoOpenWindows: Bool {
        windows?.isEmpty == true
    }

    /// A failed scan keeps the last known inventory; an empty scan closes all rows.
    @discardableResult
    public mutating func update(windows: [VSCodeWindowDescriptor]?) -> Bool {
        guard let windows else {
            return false
        }
        let orderedWindows = windows.sorted {
            $0.id == $1.id ? $0.title < $1.title : $0.id < $1.id
        }
        guard self.windows != orderedWindows else {
            return false
        }
        self.windows = orderedWindows
        return true
    }

    public func visibleTasks(in tasks: [CodexTask]) -> [CodexTask] {
        guard let windows else {
            return []
        }
        let matcher = VSCodeWindowMatcher()
        return tasks.filter { task in
            if case .notFound = matcher.match(normalizedCWD: task.cwd, windows: windows) {
                return false
            }
            return true
        }
    }

    /// Preserves task priority order, using the first task for each opened root.
    /// The underlying tasks retain their actual cwd and session identities.
    public func visibleRows(in tasks: [CodexTask]) -> [VSCodeTaskRow] {
        guard let windows else { return [] }
        let matcher = VSCodeWindowMatcher()
        let knownWindows = windows.filter { $0.workspace != nil }
        let unknownWindows = windows.filter { $0.workspace == nil }
        var seen = Set<String>()
        var rows: [VSCodeTaskRow] = []
        for task in tasks {
            var hasKnownWorkspace = false
            for window in knownWindows {
                guard let workspace = window.workspace,
                      case .matched = matcher.match(normalizedCWD: task.cwd, windows: [window]) else { continue }
                hasKnownWorkspace = true
                let id = "workspace:\(workspace.path)"
                guard seen.insert(id).inserted else { continue }
                rows.append(VSCodeTaskRow(
                    id: id,
                    displayName: workspace.displayName,
                    rootPath: workspace.path,
                    isMultiRoot: workspace.isMultiRoot,
                    task: task,
                    workspace: workspace
                ))
            }
            guard !hasKnownWorkspace else { continue }

            let row: VSCodeTaskRow
            switch matcher.match(normalizedCWD: task.cwd, windows: unknownWindows) {
            case .notFound:
                continue
            case let .matched(window):
                row = VSCodeTaskRow(
                    id: "window:\(window.id)",
                    displayName: task.workspaceName,
                    rootPath: task.cwd,
                    isMultiRoot: false,
                    task: task
                )
            case .ambiguous:
                // Keep existing task visibility without claiming a particular window.
                row = VSCodeTaskRow(
                    id: "task:\(task.cwd)",
                    displayName: task.workspaceName,
                    rootPath: task.cwd,
                    isMultiRoot: false,
                    task: task
                )
            }
            if seen.insert(row.id).inserted { rows.append(row) }
        }
        for workspace in knownWindows.compactMap(\.workspace).sorted(by: { $0.path < $1.path }) {
            let row = VSCodeTaskRow(workspace: workspace)
            if seen.insert(row.id).inserted { rows.append(row) }
        }
        return rows
    }
}
