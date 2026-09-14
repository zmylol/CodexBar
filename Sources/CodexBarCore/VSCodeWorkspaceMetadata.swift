import Foundation

/// Adds local opened-root identities and multi-root membership to current AX windows.
/// Call off the main thread: workspace paths are read and canonicalized on disk.
public enum VSCodeWorkspaceMetadata {
    private static let maximumFileBytes = 1_048_576
    private static let maximumWindows = 128
    private static let maximumFolders = 256

    public static func enrich(
        _ windows: [VSCodeWindowDescriptor],
        storageURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Code/User/globalStorage/storage.json")
    ) -> [VSCodeWindowDescriptor] {
        guard !windows.isEmpty,
              let data = boundedData(at: storageURL),
              let state = try? JSONDecoder().decode(Storage.self, from: data).windowsState
        else { return windows }

        var records = state.openedWindows ?? []
        if let active = state.lastActiveWindow { records.append(active) }
        guard records.count <= maximumWindows else { return windows }

        var seen = Set<String>()
        let workspaces = records.compactMap { record -> VSCodeWorkspaceIdentity? in
            if let uri = record.workspaceIdentifier?.configURIPath {
                guard let url = localFileURL(uri),
                      let path = PathNormalizer.normalize(url.path)
                else { return nil }
                let identity: VSCodeWorkspaceIdentity
                if url.pathExtension.caseInsensitiveCompare("code-workspace") == .orderedSame {
                    identity = .workspace(path)
                } else if isUntitledWorkspace(path: path, storageURL: storageURL) {
                    identity = .untitledWorkspace(path)
                } else {
                    return nil
                }
                return seen.insert("workspace:" + path).inserted ? identity : nil
            }
            guard let uri = record.folder, let url = localFileURL(uri),
                  let path = PathNormalizer.normalize(url.path),
                  seen.insert("folder:" + path).inserted
            else { return nil }
            return .folder(path)
        }

        return windows.map { window in
            let candidates = workspaces.filter {
                matchesWorkspaceTitle(window.title, workspace: $0)
            }
            guard !candidates.isEmpty else { return window }

            // The title cannot distinguish separate roots or workspace files with the same name.
            let workspace = candidates.count == 1 ? candidates[0] : nil
            let folders: [String]
            switch workspace {
            case let .folder(path): folders = [path]
            case let .workspace(path), let .untitledWorkspace(path):
                folders = folderPaths(in: URL(fileURLWithPath: path))
            case nil: folders = []
            }
            return VSCodeWindowDescriptor(
                id: window.id, title: window.title, workspaceFolderPaths: folders, workspace: workspace
            )
        }
    }

    private static func matchesWorkspaceTitle(_ title: String, workspace: VSCodeWorkspaceIdentity) -> Bool {
        let title = VSCodeWindowMatcher().workspaceTitle(title)
        let names: [String]
        if case .untitledWorkspace = workspace { names = ["Untitled", "未命名"] }
        else { names = [workspace.displayName] }
        for name in names {
            for marker in workspace.isMultiRoot ? [" (Workspace)", " (工作区)"] : [""] {
                let suffix = name + marker
                if title.caseInsensitiveCompare(suffix) == .orderedSame { return true }
                for separator in [" — ", " – ", " - "] {
                    if title.range(of: separator + suffix, options: [.backwards, .anchored, .caseInsensitive]) != nil {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func isUntitledWorkspace(path: String, storageURL: URL) -> Bool {
        let storage = storageURL.standardizedFileURL
        guard Array(storage.pathComponents.suffix(4)) == ["Code", "User", "globalStorage", "storage.json"]
        else { return false }
        let directory = storage.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Workspaces")
            .resolvingSymlinksInPath()
        let workspace = URL(fileURLWithPath: path)
        return workspace.lastPathComponent == "workspace.json"
            && workspace.deletingLastPathComponent().deletingLastPathComponent().path == directory.path
    }

    private static func folderPaths(in workspace: URL) -> [String] {
        guard let data = boundedData(at: workspace),
              let json = strippingJSONCommentsAndTrailingCommas(data),
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let folders = object["folders"] as? [[String: Any]],
              folders.count <= maximumFolders
        else { return [] }

        var seen = Set<String>()
        return folders.compactMap { folder in
            let url: URL
            if let path = folder["path"] as? String {
                guard !path.isEmpty, path.utf8.count <= 4_096 else { return nil }
                url = (path as NSString).isAbsolutePath
                    ? URL(fileURLWithPath: path)
                    : workspace.deletingLastPathComponent().appendingPathComponent(path)
            } else if let uri = folder["uri"] as? String, let local = localFileURL(uri) {
                url = local
            } else {
                return nil
            }
            guard let path = PathNormalizer.normalize(url.path), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    private static func localFileURL(_ uri: String) -> URL? {
        guard uri.utf8.count <= 4_096,
              let url = URL(string: uri), url.isFileURL,
              url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              !url.path.contains("\0"), (url.path as NSString).isAbsolutePath
        else { return nil }
        return url
    }

    private static func boundedData(at url: URL) -> Data? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maximumFileBytes,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumFileBytes + 1),
              data.count <= maximumFileBytes
        else { return nil }
        return data
    }

    /// Strip only outside strings so URI slashes, escaped quotes and literal commas survive.
    private static func strippingJSONCommentsAndTrailingCommas(_ data: Data) -> Data? {
        var bytes = Array(data)
        var index = 0
        var inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if byte == 92 { index += 2; continue }
                if byte == 34 { inString = false }
            } else if byte == 34 {
                inString = true
            } else if byte == 47, index + 1 < bytes.count {
                if bytes[index + 1] == 47 {
                    while index < bytes.count, bytes[index] != 10, bytes[index] != 13 {
                        bytes[index] = 32
                        index += 1
                    }
                    continue
                }
                if bytes[index + 1] == 42 {
                    bytes[index] = 32
                    bytes[index + 1] = 32
                    index += 2
                    var closed = false
                    while index < bytes.count {
                        if bytes[index] == 42, index + 1 < bytes.count, bytes[index + 1] == 47 {
                            bytes[index] = 32
                            bytes[index + 1] = 32
                            index += 2
                            closed = true
                            break
                        }
                        bytes[index] = 32
                        index += 1
                    }
                    guard closed else { return nil }
                    continue
                }
            }
            index += 1
        }

        index = 0
        inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if byte == 92 { index += 2; continue }
                if byte == 34 { inString = false }
            } else if byte == 34 {
                inString = true
            } else if byte == 44 {
                var next = index + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 93 || bytes[next] == 125 { bytes[index] = 32 }
            }
            index += 1
        }
        return Data(bytes)
    }

    // Deliberately decode only current windows, never history or unrelated global state.
    private struct Storage: Decodable {
        let windowsState: WindowsState?
    }

    private struct WindowsState: Decodable {
        let openedWindows: [WindowState]?
        let lastActiveWindow: WindowState?
    }

    private struct WindowState: Decodable {
        let workspaceIdentifier: WorkspaceIdentifier?
        let folder: String?
    }

    private struct WorkspaceIdentifier: Decodable {
        let configURIPath: String?
    }
}
