import Foundation

/// A reflog records creation history, not the current commit ancestry of a branch.
enum GitBranchOriginReader {
    static func read(branch: String, commonDirectory: URL) -> String? {
        guard isLocalBranchName(branch),
              let contents = metadata("logs/refs/heads/\(branch)", within: commonDirectory, limit: 131_072),
              contents.hasSuffix("\n")
        else { return nil }
        let lines = contents.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first, let first = entry(firstLine),
              first.oldOID.allSatisfy({ $0 == "0" }),
              first.message.hasPrefix("branch: Created from ")
        else { return nil }
        let rawSource = String(first.message.dropFirst(21))
        let source = rawSource.hasPrefix("refs/heads/") ? String(rawSource.dropFirst(11)) : rawSource
        guard isLocalBranchName(source), source != branch, source != "HEAD",
              !source.hasPrefix("refs/"), unambiguousSource(rawSource, within: commonDirectory),
              reference(source, within: commonDirectory) != nil
        else { return nil }

        var lastOID = first.newOID
        for line in lines.dropFirst() {
            guard let record = entry(line), record.oldOID == lastOID else { return nil }
            let message = record.message.lowercased()
            // Copy/rename preserves older reflog entries belonging to a different branch identity.
            guard !message.hasPrefix("branch: copied "),
                  !message.hasPrefix("branch: renamed "),
                  !message.hasPrefix("branch: created from ")
            else { return nil }
            lastOID = record.newOID
        }
        guard reference(branch, within: commonDirectory) == lastOID else { return nil }
        return source
    }

    private static func unambiguousSource(_ source: String, within directory: URL) -> Bool {
        if source.hasPrefix("refs/heads/") { return true }
        if (4...64).contains(source.utf8.count), source.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0)
        }) { return false }
        let alternatives = Set([source, "refs/\(source)", "refs/tags/\(source)",
                                "refs/remotes/\(source)", "refs/remotes/\(source)/HEAD"])
        for name in alternatives {
            guard let url = metadataURL(name, within: directory),
                  !FileManager.default.fileExists(atPath: url.path)
            else { return false }
        }
        guard let packedURL = metadataURL("packed-refs", within: directory) else { return false }
        guard FileManager.default.fileExists(atPath: packedURL.path) else { return true }
        guard let packed = metadata("packed-refs", within: directory, limit: 1_048_576) else { return false }
        return !packed.split(separator: "\n").contains { line in
            guard !line.hasPrefix("#"), !line.hasPrefix("^") else { return false }
            let fields = line.split(separator: " ")
            return fields.count == 2 && alternatives.contains(String(fields[1]))
        }
    }

    static func isLocalBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 1_024, name != "@", name != "HEAD",
              !name.hasPrefix("-"), !name.contains(".."), !name.contains("@{"),
              !name.hasSuffix("."), !name.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || CharacterSet.controlCharacters.contains($0)
                      || "~^:?*[\\".unicodeScalars.contains($0)
              })
        else { return false }
        return name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
        }
    }

    /// Resolving a Git ref must never turn it into a read outside this repository's metadata.
    static func metadataURL(_ relativePath: String, within directory: URL) -> URL? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    private static func reference(_ branch: String, within directory: URL) -> String? {
        let relativePath = "refs/heads/\(branch)"
        guard let looseURL = metadataURL(relativePath, within: directory) else { return nil }
        if FileManager.default.fileExists(atPath: looseURL.path) {
            guard let value = metadata(relativePath, within: directory, limit: 128) else { return nil }
            let oid = value.trimmingCharacters(in: .newlines)
            return isObjectID(oid) && !oid.allSatisfy({ $0 == "0" }) ? oid : nil
        }
        guard let packed = metadata("packed-refs", within: directory, limit: 1_048_576) else { return nil }
        var result: String?
        for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            if parts[1] == relativePath {
                let oid = String(parts[0])
                guard result == nil, isObjectID(oid), !oid.allSatisfy({ $0 == "0" }) else { return nil }
                result = oid
            }
        }
        return result
    }

    private struct Entry {
        let oldOID: String
        let newOID: String
        let message: Substring
    }

    private static func entry(_ line: Substring) -> Entry? {
        guard let tab = line.firstIndex(of: "\t") else { return nil }
        let header = line[..<tab].split(separator: " ", omittingEmptySubsequences: false)
        guard header.count >= 6,
              isObjectID(String(header[0])), isObjectID(String(header[1])),
              header[0].count == header[1].count, !header[1].allSatisfy({ $0 == "0" }),
              let timestamp = Int64(header[header.count - 2]), timestamp >= 0
        else { return nil }
        let zone = header[header.count - 1]
        guard zone.count == 5, zone.first == "+" || zone.first == "-",
              zone.dropFirst().utf8.allSatisfy({ (48...57).contains($0) }),
              let hours = Int(zone.dropFirst().prefix(2)), hours <= 23,
              let minutes = Int(zone.suffix(2)), minutes <= 59
        else { return nil }
        let identity = header[2..<(header.count - 2)].joined(separator: " ")
        guard identity.contains("<"), identity.hasSuffix(">") else { return nil }
        let message = line[line.index(after: tab)...]
        guard !message.isEmpty else { return nil }
        return Entry(oldOID: String(header[0]), newOID: String(header[1]), message: message)
    }

    private static func isObjectID(_ value: String) -> Bool {
        [40, 64].contains(value.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func metadata(_ path: String, within directory: URL, limit: Int) -> String? {
        guard let url = metadataURL(path, within: directory),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= limit,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit,
              let contents = String(data: data, encoding: .utf8),
              !contents.contains("\0"), !contents.contains("\r")
        else { return nil }
        return contents
    }
}
