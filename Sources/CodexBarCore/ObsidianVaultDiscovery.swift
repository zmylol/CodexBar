import Darwin
import Foundation

/// Reads Obsidian's bounded vault registry and validates only the directories it names.
/// This discovery step neither searches the disk nor reads note contents.
public enum ObsidianVaultDiscovery {
    public static let maximumRegistryBytes = 1_024 * 1_024
    public static var defaultRegistryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    public static func defaultVault(registryURL: URL = defaultRegistryURL) throws -> ObsidianVault? {
        guard let data = try registryData(registryURL) else { return nil }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw discoveryError("Obsidian 的知识库配置无法解析，请手动选择总目录。") }
        guard let registry = object as? [String: Any] else {
            throw discoveryError("Obsidian 的知识库配置格式不正确，请手动选择总目录。")
        }
        guard let rawVaults = registry["vaults"] else { return nil }
        guard let entries = rawVaults as? [String: Any], entries.count <= 1_024 else {
            throw discoveryError("Obsidian 的知识库列表格式不正确或过大，请手动选择总目录。")
        }
        var candidates: [String: (vault: ObsidianVault, isOpen: Bool)] = [:]
        for value in entries.values {
            guard let entry = value as? [String: Any], let path = entry["path"] as? String,
                  let vault = validatedVault(path: path) else { continue }
            let flag = entry["open"] as? NSNumber
            let isOpen = flag.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            candidates[vault.rootPath] = (vault, isOpen || candidates[vault.rootPath]?.isOpen == true)
        }
        if candidates.count == 1 { return candidates.values.first?.vault }
        let openVaults = candidates.values.filter(\.isOpen)
        return openVaults.count == 1 ? openVaults.first?.vault : nil
    }

    private static func registryData(_ url: URL) throws -> Data? {
        guard url.isFileURL, (url.path as NSString).isAbsolutePath, url.path.utf8.count <= 4_096,
              !url.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw discoveryError("Obsidian 的知识库配置位置无效。")
        }
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw discoveryError("无法读取 Obsidian 的知识库配置，请检查访问权限。")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw discoveryError("Obsidian 的知识库配置不是普通文件。")
        }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw discoveryError("无法读取 Obsidian 的知识库配置。") }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_size >= 0, opened.st_size <= maximumRegistryBytes else {
            throw discoveryError("Obsidian 的知识库配置过大或暂时无法读取。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= maximumRegistryBytes {
            let count = read(descriptor, &buffer, min(buffer.count, maximumRegistryBytes + 1 - data.count))
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw discoveryError("无法读取 Obsidian 的知识库配置。") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= maximumRegistryBytes else {
            throw discoveryError("Obsidian 的知识库配置过大，请手动选择总目录。")
        }
        return data
    }

    private static func validatedVault(path: String) -> ObsidianVault? {
        guard path.utf8.count <= 4_096, (path as NSString).isAbsolutePath, path != "/",
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let selected = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard selected.path != "/" else { return nil }
        let root = open(selected.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { return nil }
        defer { close(root) }
        var status = stat()
        var marker = stat()
        guard fstat(root, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              fstatat(root, ".obsidian", &marker, AT_SYMLINK_NOFOLLOW) == 0,
              marker.st_mode & S_IFMT == S_IFDIR else { return nil }
        let canonical = selected.resolvingSymlinksInPath()
        var current = stat()
        guard lstat(selected.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              current.st_dev == status.st_dev, current.st_ino == status.st_ino,
              lstat(canonical.path, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
              current.st_dev == status.st_dev, current.st_ino == status.st_ino else { return nil }
        return ObsidianVault(rootPath: canonical.path, name: canonical.lastPathComponent)
    }

    private static func discoveryError(_ message: String) -> NSError {
        NSError(domain: "CodexBar.ObsidianVaultDiscovery", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
