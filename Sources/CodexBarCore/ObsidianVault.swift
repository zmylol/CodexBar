import Foundation

public struct ObsidianVault: Equatable, Sendable {
    public let rootPath: String
    public let name: String

    public init(rootPath: String, name: String) {
        self.rootPath = rootPath
        self.name = name
    }

    /// Check only workspace ancestors. Never enumerate the vault or read its notes.
    public static func discover(cwd: String) -> ObsidianVault? {
        guard let path = PathNormalizer.normalize(cwd) else { return nil }
        var directory = URL(fileURLWithPath: path, isDirectory: true)
        for _ in 0..<64 where directory.path != "/" {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".obsidian").path,
                                             isDirectory: &isDirectory), isDirectory.boolValue {
                return ObsidianVault(rootPath: directory.path, name: directory.lastPathComponent)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    /// Must run off the UI actor: canonicalization also checks symlink destinations.
    public func notePath(_ raw: String, cwd: String) -> String? {
        guard !raw.isEmpty, raw.utf8.count <= 4_096, !raw.contains("://"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (rootPath as NSString).isAbsolutePath, rootPath != "/",
              (cwd as NSString).isAbsolutePath else { return nil }
        let url = (raw as NSString).isAbsolutePath
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(raw)
        // Foundation may leave an entire path unresolved when its final file has
        // been deleted. Resolve the nearest existing ancestor before adding it back.
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            if (try? FileManager.default.attributesOfItem(atPath: ancestor.path)[.type]) as? FileAttributeType == .typeSymbolicLink {
                return nil
            }
            guard ancestor.path != "/", missing.count < 128 else { return nil }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var canonical = ancestor.resolvingSymlinksInPath()
        for component in missing.reversed() { canonical.appendPathComponent(component) }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
        guard canonical.path.hasPrefix(root + "/"), canonical.pathExtension.lowercased() == "md" else { return nil }
        let relative = String(canonical.path.dropFirst(root.count + 1))
        guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        return relative
    }

    public func openURL(notePath: String) -> URL? {
        guard let relative = self.notePath(notePath, cwd: rootPath) else { return nil }
        var parts = URLComponents()
        parts.scheme = "obsidian"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: URL(fileURLWithPath: rootPath)
            .appendingPathComponent(relative).path)]
        return parts.url
    }
}
