import Foundation
import CodexBarCore

@MainActor
func windowTitleMatchingTestCases() -> [CodexBarTestCase] {
    [
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
