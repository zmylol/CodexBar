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
            return tasks
        }
        let matcher = VSCodeWindowMatcher()
        return tasks.filter { task in
            if case .notFound = matcher.match(normalizedCWD: task.cwd, windows: windows) {
                return false
            }
            return true
        }
    }
}
