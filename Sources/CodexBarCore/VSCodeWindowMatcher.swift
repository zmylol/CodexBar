import Foundation

public struct VSCodeWindowDescriptor: Equatable, Sendable {
    public let id: Int
    public let title: String

    public init(id: Int, title: String) {
        self.id = id
        self.title = title
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
        cwd: String,
        windows: [VSCodeWindowDescriptor]
    ) -> VSCodeWindowMatchResult {
        guard let normalizedPath = PathNormalizer.normalize(cwd) else {
            return .notFound
        }

        return match(normalizedCWD: normalizedPath, windows: windows)
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

        let candidates = windows.filter {
            title($0.title, containsWorkspaceNameAtBoundary: workspaceName)
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
        cwd: String,
        windows: [VSCodeWindowDescriptor],
        minimizeOtherWindows: Bool = false
    ) -> VSCodeWindowFocusPlanResult {
        switch match(cwd: cwd, windows: windows) {
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

    private func title(
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
