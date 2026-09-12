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
        CodexBarTestCase(name: "never matches empty or root cwd") {
            let windows = [VSCodeWindowDescriptor(id: 1, title: "Visual Studio Code")]

            try expect(VSCodeWindowMatcher().match(cwd: "", windows: windows) == .notFound, "empty cwd matched")
            try expect(VSCodeWindowMatcher().match(cwd: "/", windows: windows) == .notFound, "root cwd matched")
        }
    ]
}
