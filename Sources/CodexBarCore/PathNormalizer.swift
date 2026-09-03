import Foundation

public enum PathNormalizer {
    /// Returns a canonical absolute path suitable for workspace matching.
    /// Relative paths, empty paths, and the filesystem root are rejected.
    public static func normalize(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.count <= 4_096
        else {
            return nil
        }

        let expandedPath = (path as NSString).expandingTildeInPath
        guard (expandedPath as NSString).isAbsolutePath else {
            return nil
        }

        let normalizedPath = URL(fileURLWithPath: expandedPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path

        guard normalizedPath != "/" else {
            return nil
        }

        return normalizedPath
    }
}
