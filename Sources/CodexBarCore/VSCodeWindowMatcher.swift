import Foundation

public enum VSCodeWorkspaceIdentity: Equatable, Sendable {
    case folder(String)
    case workspace(String)
    case untitledWorkspace(String)

    public var path: String {
        switch self {
        case let .folder(path), let .workspace(path), let .untitledWorkspace(path): return path
        }
    }

    public var displayName: String {
        if case .untitledWorkspace = self { return "未命名工作区" }
        let url = URL(fileURLWithPath: path)
        return isMultiRoot ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    public var isMultiRoot: Bool {
        if case .folder = self { return false }
        return true
    }
}

public struct VSCodeWindowDescriptor: Equatable, Sendable {
    public let id: Int
    public let title: String
    /// Canonical workspace folders; nil permits title matching, while an empty list does not.
    public let workspaceFolderPaths: [String]?
    public let workspace: VSCodeWorkspaceIdentity?

    public init(
        id: Int, title: String, workspaceFolderPaths: [String]? = nil,
        workspace: VSCodeWorkspaceIdentity? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceFolderPaths = workspaceFolderPaths
        self.workspace = workspace
    }
}

public enum VSCodeWindowMatchResult: Equatable, Sendable {
    case matched(VSCodeWindowDescriptor)
    case ambiguous([VSCodeWindowDescriptor])
    case notFound
}

package struct VSCodeWindowFocusPlan: Equatable, Sendable {
    package let target: VSCodeWindowDescriptor
    package let windowsToMinimize: [VSCodeWindowDescriptor]

    package init(
        target: VSCodeWindowDescriptor,
        windowsToMinimize: [VSCodeWindowDescriptor]
    ) {
        self.target = target
        self.windowsToMinimize = windowsToMinimize
    }
}

package enum VSCodeWindowFocusPlanResult: Equatable, Sendable {
    case planned(VSCodeWindowFocusPlan)
    case ambiguous([VSCodeWindowDescriptor])
    case notFound
}

public struct VSCodeWindowMatcher: Sendable {
    public init() {}

    public func match(
        cwd: String?,
        windows: [VSCodeWindowDescriptor],
        workspace: VSCodeWorkspaceIdentity? = nil
    ) -> VSCodeWindowMatchResult {
        let candidates = workspace.map { identity in windows.filter { $0.workspace == identity } } ?? windows
        guard let cwd else {
            guard let workspace, PathNormalizer.normalize(workspace.path) != nil else { return .notFound }
            switch candidates.count {
            case 0: return .notFound
            case 1: return .matched(candidates[0])
            default: return .ambiguous(candidates)
            }
        }
        guard let normalizedPath = PathNormalizer.normalize(cwd) else {
            return .notFound
        }
        return match(normalizedCWD: normalizedPath, windows: candidates)
    }

    /// TaskStore paths are already canonical; presentation must not resolve them on disk again.
    package func match(
        normalizedCWD: String,
        windows: [VSCodeWindowDescriptor]
    ) -> VSCodeWindowMatchResult {
        let workspaceName = URL(fileURLWithPath: normalizedCWD).lastPathComponent
        guard !workspaceName.isEmpty else {
            return .notFound
        }

        let candidates = windows.filter { window in
            if let folders = window.workspaceFolderPaths {
                return folders.contains { folder in
                    normalizedCWD == folder
                        || normalizedCWD.hasPrefix(folder == "/" ? folder : folder + "/")
                }
            }
            return title(workspaceTitle(window.title), containsWorkspaceNameAtBoundary: workspaceName)
        }

        switch candidates.count {
        case 0:
            return .notFound
        case 1:
            return .matched(candidates[0])
        default:
            return .ambiguous(candidates)
        }
    }

    package func focusPlan(
        cwd: String?,
        windows: [VSCodeWindowDescriptor],
        workspace: VSCodeWorkspaceIdentity? = nil,
        minimizeOtherWindows: Bool = false
    ) -> VSCodeWindowFocusPlanResult {
        switch match(cwd: cwd, windows: windows, workspace: workspace) {
        case .notFound:
            return .notFound
        case let .ambiguous(candidates):
            return .ambiguous(candidates)
        case let .matched(target):
            return .planned(VSCodeWindowFocusPlan(
                target: target,
                windowsToMinimize: minimizeOtherWindows ? windows.filter { $0.id != target.id } : []
            ))
        }
    }

    package func workspaceTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let productName = "Visual Studio Code"
        guard trimmed.caseInsensitiveCompare(productName) != .orderedSame else { return "" }
        for separator in [" — ", " – ", " - "] {
            if let suffix = trimmed.range(
                of: separator + productName,
                options: [.backwards, .anchored, .caseInsensitive]
            ) {
                return String(trimmed[..<suffix.lowerBound])
            }
        }
        return trimmed
    }

    package func title(
        _ title: String,
        containsWorkspaceNameAtBoundary workspaceName: String
    ) -> Bool {
        var searchStart = title.startIndex

        while searchStart < title.endIndex,
              let range = title.range(
                  of: workspaceName,
                  options: [.caseInsensitive],
                  range: searchStart..<title.endIndex
              ) {
            let hasJoinedPrefix = range.lowerBound > title.startIndex
                && isJoinedToWorkspaceName(title[title.index(before: range.lowerBound)])
            let hasJoinedSuffix = range.upperBound < title.endIndex
                && isJoinedToWorkspaceName(title[range.upperBound])

            if !hasJoinedPrefix && !hasJoinedSuffix {
                return true
            }

            searchStart = range.upperBound
        }

        return false
    }

    private func isJoinedToWorkspaceName(_ character: Character) -> Bool {
        if character == "." || character == "_" || character == "-" {
            return true
        }

        return character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}
