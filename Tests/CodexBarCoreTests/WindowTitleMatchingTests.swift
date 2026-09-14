import Foundation
import CodexBarCore

@MainActor
func windowTitleMatchingTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "idle workspace activation uses its exact identity without a task cwd") {
            let identities: [VSCodeWorkspaceIdentity] = [
                .folder("/work/new-project"), .workspace("/work/Empty.code-workspace"),
                .untitledWorkspace("/work/Code/Workspaces/123/workspace.json")
            ]
            let windows = identities.enumerated().map { index, identity in
                VSCodeWindowDescriptor(id: index + 1, title: identity.displayName,
                                       workspaceFolderPaths: [], workspace: identity)
            }
            let matcher = VSCodeWindowMatcher()
            for (index, identity) in identities.enumerated() {
                try expect(matcher.match(cwd: nil, windows: windows, workspace: identity) == .matched(windows[index]),
                           "idle workspace incorrectly required a member cwd")
                try expect(matcher.focusPlan(cwd: nil, windows: windows, workspace: identity) == .planned(
                    VSCodeWindowFocusPlan(target: windows[index], windowsToMinimize: [])
                ), "idle workspace activation changed unrelated windows")
            }
            let duplicate = VSCodeWindowDescriptor(id: 99, title: windows[1].title,
                                                   workspaceFolderPaths: [], workspace: identities[1])
            try expect(matcher.match(cwd: nil, windows: [windows[1], duplicate], workspace: identities[1]) == .ambiguous([windows[1], duplicate]),
                       "idle activation selected an arbitrary duplicate")
            try expect(matcher.match(cwd: nil, windows: [windows[0]], workspace: identities[1]) == .notFound,
                       "closed workspace fell back to a different root")
            try expect(matcher.match(cwd: nil, windows: windows) == .notFound, "missing target matched a window")
            try expect(matcher.match(cwd: "", windows: windows, workspace: identities[1]) == .notFound,
                       "invalid explicit cwd bypassed task matching")
        },
        CodexBarTestCase(name: "workspace row activation distinguishes a shared folder from its multi-root window") {
            let folder = VSCodeWorkspaceIdentity.folder("/work/shared")
            let group = VSCodeWorkspaceIdentity.workspace("/work/group.code-workspace")
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "shared", workspaceFolderPaths: ["/work/shared"], workspace: folder),
                VSCodeWindowDescriptor(id: 2, title: "group (Workspace)", workspaceFolderPaths: ["/work/shared"], workspace: group)
            ]
            let matcher = VSCodeWindowMatcher()
            try expect(matcher.match(cwd: "/work/shared", windows: windows, workspace: folder) == .matched(windows[0]),
                       "single-folder row selected its multi-root window")
            let plan = matcher.focusPlan(cwd: "/work/shared", windows: windows, workspace: group, minimizeOtherWindows: true)
            try expect(plan == .planned(VSCodeWindowFocusPlan(target: windows[1], windowsToMinimize: [windows[0]])),
                       "workspace focus did not retain the target identity and minimize the other window")
            try expect(matcher.match(cwd: "/work/shared", windows: [windows[0]], workspace: group) == .notFound,
                       "closing the selected workspace fell back to a different open root")
        },
        CodexBarTestCase(name: "duplicate windows for one workspace remain ambiguous during explicit activation") {
            let identity = VSCodeWorkspaceIdentity.folder("/work/shared")
            let windows = [1, 2].map {
                VSCodeWindowDescriptor(id: $0, title: "shared", workspaceFolderPaths: ["/work/shared"], workspace: identity)
            }
            try expect(VSCodeWindowMatcher().match(cwd: "/work/shared", windows: windows, workspace: identity) == .ambiguous(windows),
                       "workspace identity selected an arbitrary duplicate window")
        },
        CodexBarTestCase(name: "matches multi-root workspace members and descendants by their full paths") {
            let window = VSCodeWindowDescriptor(
                id: 1, title: "Example-Workspace (Workspace) — Visual Studio Code",
                workspaceFolderPaths: ["/work/sources/project-alpha", "/work/sources/project-beta"]
            )
            let matcher = VSCodeWindowMatcher()
            for cwd in ["/work/sources/project-alpha", "/work/sources/project-beta", "/work/sources/project-alpha/src"] {
                try expect(matcher.match(cwd: cwd, windows: [window]) == .matched(window),
                           "workspace member or nested task was hidden")
            }
            for cwd in ["/other/project-alpha", "/work/sources/project-alpha-copy", "/work/sources", "/work/Example-Workspace"] {
                try expect(matcher.match(cwd: cwd, windows: [window]) == .notFound,
                           "unrelated task matched workspace metadata or title fallback")
            }
        },
        CodexBarTestCase(name: "known empty workspace membership prevents title fallback") {
            let window = VSCodeWindowDescriptor(
                id: 1, title: "project-alpha — Visual Studio Code", workspaceFolderPaths: []
            )
            try expect(VSCodeWindowMatcher().match(cwd: "/work/project-alpha", windows: [window]) == .notFound,
                       "unresolved workspace metadata fell back to its title")
        },
        CodexBarTestCase(name: "shared workspace membership remains ambiguous until its other window closes") {
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "First Workspace", workspaceFolderPaths: ["/work/project-alpha"]),
                VSCodeWindowDescriptor(id: 2, title: "Second Workspace", workspaceFolderPaths: ["/work/project-alpha"])
            ]
            let matcher = VSCodeWindowMatcher()
            try expect(matcher.match(cwd: "/work/project-alpha", windows: windows) == .ambiguous(windows),
                       "shared workspace folder selected an arbitrary window")
            try expect(matcher.match(cwd: "/work/project-alpha", windows: [windows[0]]) == .matched(windows[0]),
                       "remaining workspace window did not match")
            try expect(matcher.match(cwd: "/work/project-alpha", windows: []) == .notFound,
                       "closed workspace still matched")
        },
        CodexBarTestCase(name: "normalizes paths and resolves symlinks") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexBarPathTests-\(UUID().uuidString)", isDirectory: true)
            let real = root.appendingPathComponent("real/project-alpha", isDirectory: true)
            let link = root.appendingPathComponent("linked", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            try expect(PathNormalizer.normalize(link.path + "/../linked") == real.path, "symlink was not resolved")
        },
        CodexBarTestCase(name: "matches workspace name at title boundaries") {
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "README.md — project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "summer-notes — Visual Studio Code")
            ]

            try expect(
                VSCodeWindowMatcher().match(cwd: "/work/project-alpha", windows: windows) == .matched(windows[0]),
                "unique workspace title did not match"
            )
            try expect(
                VSCodeWindowMatcher().match(cwd: "/work/MER", windows: windows) == .notFound,
                "substring inside another word should not match"
            )
        },
        CodexBarTestCase(name: "never treats the VS Code product name as a workspace") {
            let matcher = VSCodeWindowMatcher()
            for title in [
                "unrelated — Visual Studio Code",
                "unrelated – Visual Studio Code",
                "unrelated - Visual Studio Code",
                "Visual Studio Code"
            ] {
                let windows = [VSCodeWindowDescriptor(id: 1, title: title)]
                for name in ["Code", "Visual", "Studio", "Visual Studio Code"] {
                    try expect(
                        matcher.match(cwd: "/work/\(name)", windows: windows) == .notFound,
                        "product name in \(title) incorrectly matched workspace \(name)"
                    )
                }
            }
        },
        CodexBarTestCase(name: "preserves real workspaces named after the VS Code product") {
            for name in ["Code", "Visual", "Studio", "Visual Studio Code"] {
                let windows = [
                    VSCodeWindowDescriptor(id: 1, title: "unrelated — Visual Studio Code"),
                    VSCodeWindowDescriptor(id: 2, title: "README.md — \(name) — Visual Studio Code")
                ]
                try expect(
                    VSCodeWindowMatcher().match(cwd: "/work/\(name)", windows: windows) == .matched(windows[1]),
                    "real workspace \(name) was hidden or confused with the product suffix"
                )
            }
        },
        CodexBarTestCase(name: "refuses ambiguous window candidates") {
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "main.swift — project-alpha — Visual Studio Code")
            ]

            try expect(
                VSCodeWindowMatcher().match(cwd: "/work/project-alpha", windows: windows) == .ambiguous(windows),
                "ambiguous windows did not fail closed"
            )
        },
        CodexBarTestCase(name: "ordinary window switching leaves other VS Code windows unchanged") {
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "pi — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 3, title: "Codexbar — Visual Studio Code")
            ]

            let result = VSCodeWindowMatcher().focusPlan(
                cwd: "/work/project-alpha",
                windows: windows
            )

            try expect(
                result == .planned(VSCodeWindowFocusPlan(
                    target: windows[0],
                    windowsToMinimize: []
                )),
                "ordinary window switching would minimize other windows"
            )
        },
        CodexBarTestCase(name: "explicit project focus plans to minimize every other VS Code window") {
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "reference — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 3, title: "notes — Visual Studio Code")
            ]

            try expect(
                VSCodeWindowMatcher().focusPlan(
                    cwd: "/work/project-alpha", windows: windows, minimizeOtherWindows: true
                ) == .planned(VSCodeWindowFocusPlan(
                    target: windows[0], windowsToMinimize: [windows[1], windows[2]]
                )),
                "explicit project focus did not retain the other-window minimization plan"
            )
        },
        CodexBarTestCase(name: "both window actions refuse missing and ambiguous targets") {
            let windows = [
                VSCodeWindowDescriptor(id: 1, title: "project-alpha — Visual Studio Code"),
                VSCodeWindowDescriptor(id: 2, title: "main.swift — project-alpha — Visual Studio Code")
            ]
            for minimizeOtherWindows in [false, true] {
                try expect(
                    VSCodeWindowMatcher().focusPlan(
                        cwd: "/work/project-alpha", windows: windows,
                        minimizeOtherWindows: minimizeOtherWindows
                    ) == .ambiguous(windows),
                    "window action accepted an ambiguous target"
                )
                try expect(
                    VSCodeWindowMatcher().focusPlan(
                        cwd: "/work/missing", windows: windows,
                        minimizeOtherWindows: minimizeOtherWindows
                    ) == .notFound,
                    "window action accepted a missing target"
                )
            }
        },
        CodexBarTestCase(name: "never matches empty or root cwd") {
            let windows = [VSCodeWindowDescriptor(id: 1, title: "Visual Studio Code")]

            try expect(VSCodeWindowMatcher().match(cwd: "", windows: windows) == .notFound, "empty cwd matched")
            try expect(VSCodeWindowMatcher().match(cwd: "/", windows: windows) == .notFound, "root cwd matched")
        }
    ]
}
