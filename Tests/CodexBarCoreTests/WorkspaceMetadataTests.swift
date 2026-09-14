import Foundation
import CodexBarCore

@MainActor
func workspaceMetadataTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "multi-root workspace resolves JSONC folder paths from the workspace file") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let absolute = fixture.root.appendingPathComponent("absolute").path
            let uri = fixture.root.appendingPathComponent("uri folder").absoluteString
            let workspace = try fixture.workspace("Example-Workspace.code-workspace", content: """
            {
                // The title differs from every folder name.
                "folders": [
                    { "path": "project-alpha", },
                    /* absolute paths are also supported */
                    { "path": "\(absolute)" },
                    { "uri": "\(uri)" },
                ],
                "settings": { "example": "https://example.test/a/*literal*/,}" },
            }
            """)
            try fixture.storage(opened: [workspace])
            let window = VSCodeWindowDescriptor(id: 1, title: "README.md — Example-Workspace (Workspace) — Visual Studio Code")
            let enriched = VSCodeWorkspaceMetadata.enrich([window], storageURL: fixture.storageURL)
            let expected = ["project-alpha", "absolute", "uri folder"].compactMap {
                PathNormalizer.normalize(fixture.root.appendingPathComponent($0).path)
            }
            try expect(enriched.count == 1 && enriched[0].id == window.id && enriched[0].title == window.title,
                       "metadata changed the AX window identity")
            try expect(enriched[0].workspaceFolderPaths == expected, "JSONC workspace folders were not resolved")
            try expect(enriched[0].workspace == .workspace(PathNormalizer.normalize(workspace.path)!),
                       "multi-root identity did not retain its workspace file")
        },
        CodexBarTestCase(name: "workspace identities distinguish opened folders from saved workspace files") {
            let folder = VSCodeWorkspaceIdentity.folder("/work/project")
            let workspace = VSCodeWorkspaceIdentity.workspace("/work/team.code-workspace")
            try expect(folder.path == "/work/project" && folder.displayName == "project" && !folder.isMultiRoot,
                       "folder identity did not describe the opened root")
            try expect(workspace.path == "/work/team.code-workspace" && workspace.displayName == "team" && workspace.isMultiRoot,
                       "multi-root identity did not describe the saved workspace")
            let untitled = VSCodeWorkspaceIdentity.untitledWorkspace("/Code/Workspaces/123/workspace.json")
            try expect(untitled.path == "/Code/Workspaces/123/workspace.json"
                       && untitled.displayName == "未命名工作区" && untitled.isMultiRoot,
                       "untitled identity did not retain a distinct workspace path")
        },
        CodexBarTestCase(name: "current untitled VS Code workspace is an independent multi-root identity") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = try fixture.workspace("Code/Workspaces/1789047859336/workspace.json", content: """
            {"folders":[{"path":"member",},],}
            """)
            try fixture.storage(opened: [workspace, workspace], active: workspace)
            for title in ["Release Notes: 1.137.0 — Untitled (Workspace)", "欢迎 — 未命名 (工作区) — Visual Studio Code"] {
                let windows = [VSCodeWindowDescriptor(id: 9, title: title)]
                let enriched = VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)
                try expect(enriched[0].workspace == .untitledWorkspace(PathNormalizer.normalize(workspace.path)!),
                           "current untitled workspace did not receive its own identity")
                try expect(enriched[0].workspaceFolderPaths == [PathNormalizer.normalize(workspace.deletingLastPathComponent().appendingPathComponent("member").path)!],
                           "untitled workspace did not resolve its member folders")
                try expect(VSCodeWorkspaceMetadata.enrich(enriched, storageURL: fixture.storageURL) == enriched,
                           "re-enrichment lost the untitled workspace identity")
            }
        },
        CodexBarTestCase(name: "untitled workspace metadata rejects arbitrary JSON paths and remote configurations") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let windows = [VSCodeWindowDescriptor(id: 9, title: "Untitled (Workspace) — Visual Studio Code")]
            for name in [
                "workspace.json", "Code/Workspaces/workspace.json",
                "Code/Workspaces/123/nested/workspace.json", "Code/Other/123/workspace.json",
                "Other/Workspaces/123/workspace.json", "Code/Workspaces/123/settings.json"
            ] {
                let workspace = try fixture.workspace(name, content: "{\"folders\":[{\"path\":\"member\"}]}")
                try fixture.storage(opened: [workspace])
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                           "arbitrary JSON was treated as a VS Code untitled workspace")
            }
            try fixture.writeStorage(["windowsState": ["openedWindows": [["workspaceIdentifier": [
                "configURIPath": "file://remotehost/Code/Workspaces/123/workspace.json"
            ]]]]])
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                       "remote untitled configuration was accepted")
        },
        CodexBarTestCase(name: "multiple current untitled workspaces remain ambiguous") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let first = try fixture.workspace("Code/Workspaces/123/workspace.json", content: "{\"folders\":[{\"path\":\"first\"}]}")
            let second = try fixture.workspace("Code/Workspaces/456/workspace.json", content: "{\"folders\":[{\"path\":\"second\"}]}")
            try fixture.storage(opened: [first, second])
            let windows = [VSCodeWindowDescriptor(id: 9, title: "Untitled (Workspace) — Visual Studio Code")]
            let enriched = VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)
            try expect(enriched[0].workspace == nil && enriched[0].workspaceFolderPaths == [],
                       "multiple untitled workspaces were selected or merged arbitrarily")
        },
        CodexBarTestCase(name: "opened folder metadata maps child tasks to the actual opened root") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let folder = fixture.root.appendingPathComponent("Example-Workspace")
            try fixture.storage(opened: [], folders: [folder, folder], activeFolder: folder)
            let windows = [VSCodeWindowDescriptor(id: 17, title: "Welcome — Example-Workspace — Visual Studio Code")]
            let enriched = VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)
            let path = PathNormalizer.normalize(folder.path)!
            try expect(enriched[0].workspace == .folder(path) && enriched[0].workspaceFolderPaths == [path],
                       "ordinary folder window did not retain its opened root")
            try expect(VSCodeWindowMatcher().match(cwd: path + "/project-alpha/src", windows: enriched) == .matched(enriched[0]),
                       "child task did not map to its opened parent root")
            try expect(VSCodeWorkspaceMetadata.enrich(enriched, storageURL: fixture.storageURL) == enriched,
                       "re-enrichment lost the opened root identity")
            try fixture.storage(opened: [], activeFolder: folder)
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == enriched,
                       "active folder record did not identify the opened root")
            try Data("invalid".utf8).write(to: fixture.storageURL)
            try expect(VSCodeWorkspaceMetadata.enrich(enriched, storageURL: fixture.storageURL) == enriched,
                       "temporarily unavailable metadata lost the known root identity")
        },
        CodexBarTestCase(name: "opened folder metadata never matches an editor filename or partial root name") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            try fixture.storage(opened: [], folders: [fixture.root.appendingPathComponent("project")])
            for title in [
                "project — unrelated — Visual Studio Code",
                "project — unrelated",
                "README.md — other-project — Visual Studio Code",
                "README.md — project-next — Visual Studio Code",
                "project (Workspace) — Visual Studio Code"
            ] {
                let windows = [VSCodeWindowDescriptor(id: 3, title: title)]
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                           "editor filename or unrelated final title segment acquired a root identity")
            }
        },
        CodexBarTestCase(name: "same-name opened folder paths remain ambiguous") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            try fixture.storage(opened: [], folders: [
                fixture.root.appendingPathComponent("one/project"),
                fixture.root.appendingPathComponent("two/project")
            ])
            let windows = [VSCodeWindowDescriptor(id: 3, title: "project — Visual Studio Code")]
            let enriched = VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)
            try expect(enriched[0].workspace == nil && enriched[0].workspaceFolderPaths == [],
                       "same-name root paths were selected or combined arbitrarily")
        },
        CodexBarTestCase(name: "opened folder metadata ignores remote folder URIs") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            for uri in ["vscode-remote://ssh-remote+host/work/project", "file://remotehost/work/project"] {
                try fixture.writeStorage(["windowsState": ["openedWindows": [["folder": uri]]]])
                let windows = [VSCodeWindowDescriptor(id: 3, title: "project — Visual Studio Code")]
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                           "remote folder was treated as a local opened root")
            }
        },
        CodexBarTestCase(name: "workspace metadata includes the active window and deduplicates repeated state records") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = try fixture.workspace("project.code-workspace", content: "{\"folders\":[{\"path\":\"member\"}]}")
            try fixture.storage(opened: [workspace, workspace], active: workspace)
            let windows = [VSCodeWindowDescriptor(id: 1, title: "project (Workspace) — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths?.count == 1,
                       "duplicate state records made a unique workspace ambiguous")
            try fixture.storage(opened: [], active: workspace)
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths?.count == 1,
                       "lastActiveWindow workspace was ignored")
        },
        CodexBarTestCase(name: "metadata canonicalizes and deduplicates folder paths") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let real = fixture.root.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked"), withDestinationURL: real)
            let workspace = try fixture.workspace("project.code-workspace", content: "{\"folders\":[{\"path\":\"linked\"},{\"path\":\"real\"}]}")
            try fixture.storage(opened: [workspace])
            let windows = [VSCodeWindowDescriptor(id: 1, title: "project (Workspace) — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths == [PathNormalizer.normalize(real.path)!],
                       "member paths were not canonicalized and deduplicated")
        },
        CodexBarTestCase(name: "workspace metadata enriches current AX windows without reviving stored windows") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = try fixture.workspace("closed.code-workspace", content: "{\"folders\":[{\"path\":\"member\"}]}")
            try fixture.storage(opened: [workspace])
            let windows = [VSCodeWindowDescriptor(id: 8, title: "ordinary — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                       "stored workspace synthesized a window or altered an unrelated window")
            try expect(VSCodeWorkspaceMetadata.enrich([], storageURL: fixture.storageURL).isEmpty,
                       "stored workspace reappeared without an AX window")
        },
        CodexBarTestCase(name: "workspace metadata matches workspace names only at title boundaries") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = try fixture.workspace("mini.code-workspace", content: "{\"folders\":[]}")
            try fixture.storage(opened: [workspace])
            for title in ["miniproject", "mini-graph", "mini_graph", "mini.swift"] {
                let windows = [VSCodeWindowDescriptor(id: 1, title: "\(title) (Workspace) — Visual Studio Code")]
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                           "workspace name matched inside another title token")
            }
            let code = try fixture.workspace("Code.code-workspace", content: "{\"folders\":[]}")
            try fixture.storage(opened: [code])
            let windows = [VSCodeWindowDescriptor(id: 1, title: "ordinary — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                       "workspace matched the VS Code product suffix")
        },
        CodexBarTestCase(name: "same-name workspace files remain ambiguous instead of combining their members") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let first = try fixture.workspace("one/project.code-workspace", content: "{\"folders\":[{\"path\":\"member\"}]}")
            let second = try fixture.workspace("two/project.code-workspace", content: "{\"folders\":[{\"path\":\"other\"}]}")
            try fixture.storage(opened: [first, second])
            let windows = [VSCodeWindowDescriptor(id: 1, title: "project (Workspace) — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths == [],
                       "same-name workspaces were selected or combined arbitrarily")
        },
        CodexBarTestCase(name: "metadata requires the workspace marker and the final workspace title segment") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = try fixture.workspace("project.code-workspace", content: "{\"folders\":[{\"path\":\"member\"}]}")
            try fixture.storage(opened: [workspace])
            for title in [
                "project — unrelated — Visual Studio Code",
                "project — unrelated (Workspace) — Visual Studio Code",
                "project — Visual Studio Code",
                "other-project (Workspace) — Visual Studio Code"
            ] {
                let windows = [VSCodeWindowDescriptor(id: 1, title: title)]
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                           "an editor filename or an ordinary folder window acquired workspace membership")
            }
            for title in ["Welcome — project (Workspace)", "欢迎 — project (工作区) — Visual Studio Code"] {
                let windows = [VSCodeWindowDescriptor(id: 1, title: title)]
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths?.count == 1,
                           "an explicit workspace title was not recognized")
            }
        },
        CodexBarTestCase(name: "unreadable or invalid confirmed workspace disables basename fallback") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = fixture.root.appendingPathComponent("project.code-workspace")
            try fixture.storage(opened: [workspace])
            let windows = [VSCodeWindowDescriptor(id: 1, title: "project (Workspace) — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths == [],
                       "missing confirmed workspace retained an unsafe title fallback")
            for content in ["{ broken", "{\"folders\":{}}", "{\"folders\":[]}", "{/* unclosed"] {
                _ = try fixture.workspace("project.code-workspace", content: content)
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths == [],
                           "invalid confirmed workspace retained an unsafe title fallback")
            }
        },
        CodexBarTestCase(name: "workspace metadata ignores historical entries and nonlocal workspace URIs") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = try fixture.workspace("project.code-workspace", content: "{\"folders\":[{\"path\":\"member\"}]}")
            let historical: [String: Any] = ["backupWorkspaces": [["workspaceIdentifier": ["configURIPath": workspace.absoluteString]]]]
            try fixture.writeStorage(historical)
            let windows = [VSCodeWindowDescriptor(id: 1, title: "project (Workspace) — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                       "historical workspace was treated as open")
            for uri in ["vscode-remote://ssh-remote+host/project.code-workspace", "file://remotehost/project.code-workspace"] {
                try fixture.writeStorage(["windowsState": ["openedWindows": [["workspaceIdentifier": ["configURIPath": uri]]]]])
                try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                           "nonlocal workspace URI was read as a local workspace")
            }
        },
        CodexBarTestCase(name: "workspace folder URIs reject remote hosts and unsupported schemes") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let workspace = try fixture.workspace("project.code-workspace", content: """
            {"folders":[
                {"uri":"vscode-remote://ssh-remote+host/work/member"},
                {"uri":"file://remotehost/work/member"},
                {"path":""},
                {"path":"/"},
                {"uri":"https://example.test/member"}
            ]}
            """)
            try fixture.storage(opened: [workspace])
            let windows = [VSCodeWindowDescriptor(id: 1, title: "project (Workspace) — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths == [],
                       "invalid or remote folder path was accepted")
        },
        CodexBarTestCase(name: "workspace metadata bounds file sizes and preserves unknown state on invalid storage") {
            let fixture = try WorkspaceMetadataFixture()
            defer { fixture.remove() }
            let windows = [VSCodeWindowDescriptor(id: 1, title: "project (Workspace) — Visual Studio Code")]
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                       "missing storage changed current windows")
            try Data("invalid".utf8).write(to: fixture.storageURL)
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                       "invalid storage changed current windows")
            let oversized = String(repeating: " ", count: 1_048_577)
            try Data(oversized.utf8).write(to: fixture.storageURL)
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL) == windows,
                       "oversized storage changed current windows")
            let workspace = try fixture.workspace("project.code-workspace", content: "{\"folders\":[]}" + oversized)
            try fixture.storage(opened: [workspace])
            try expect(VSCodeWorkspaceMetadata.enrich(windows, storageURL: fixture.storageURL)[0].workspaceFolderPaths == [],
                       "oversized confirmed workspace retained a title fallback")
        }
    ]
}

private struct WorkspaceMetadataFixture {
    let root: URL
    var storageURL: URL { root.appendingPathComponent("Code/User/globalStorage/storage.json") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceMetadataTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func workspace(_ name: String, content: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }

    func storage(opened: [URL], active: URL? = nil, folders: [URL] = [], activeFolder: URL? = nil) throws {
        let workspaceRecords: [[String: Any]] = opened.map {
            ["workspaceIdentifier": ["configURIPath": $0.absoluteString]]
        }
        var state: [String: Any] = ["openedWindows": workspaceRecords + folders.map { ["folder": $0.absoluteString] }]
        if let active {
            state["lastActiveWindow"] = ["workspaceIdentifier": ["configURIPath": active.absoluteString]]
        } else if let activeFolder {
            state["lastActiveWindow"] = ["folder": activeFolder.absoluteString]
        }
        try writeStorage(["windowsState": state])
    }

    func writeStorage(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: storageURL)
    }
}
