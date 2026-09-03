import Foundation

public struct CodexBarPaths: Equatable, Sendable {
    static let maximumArchivedFileCount = 500
    static let maximumArchiveAge: TimeInterval = 7 * 24 * 60 * 60

    public let rootDirectory: URL
    public let inbox: URL
    public let processed: URL
    public let failed: URL
    public let probe: URL
    public let taskStore: URL

    public static var defaultRootDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["CODEXBAR_SUPPORT_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(
                fileURLWithPath: NSString(string: override).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        }

        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar", isDirectory: true)
    }

    public init(rootDirectory: URL = CodexBarPaths.defaultRootDirectory) {
        self.rootDirectory = rootDirectory
        self.inbox = rootDirectory.appendingPathComponent("Inbox", isDirectory: true)
        self.processed = rootDirectory.appendingPathComponent("Processed", isDirectory: true)
        self.failed = rootDirectory.appendingPathComponent("Failed", isDirectory: true)
        self.probe = rootDirectory.appendingPathComponent("Probe", isDirectory: true)
        self.taskStore = rootDirectory.appendingPathComponent("tasks.json", isDirectory: false)
    }

    public func prepareStorageDirectory(fileManager: FileManager = .default) throws {
        try createPrivateDirectory(rootDirectory, fileManager: fileManager)
    }

    func validateStorageDirectory() throws {
        try validateManagedDirectory(rootDirectory)
    }

    public func prepareEventDirectories(fileManager: FileManager = .default) throws {
        try prepareStorageDirectory(fileManager: fileManager)
        try createPrivateDirectory(inbox, fileManager: fileManager)
        try createPrivateDirectory(processed, fileManager: fileManager)
        try createPrivateDirectory(failed, fileManager: fileManager)
    }

    public func prepareProbeDirectory(fileManager: FileManager = .default) throws {
        try prepareStorageDirectory(fileManager: fileManager)
        try createPrivateDirectory(probe, fileManager: fileManager)
    }

    func enforceArchiveRetention(
        in directory: URL,
        preserving protectedURLs: Set<URL> = [],
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws {
        let protectedPaths = Set(protectedURLs.map(\.standardizedFileURL.path))
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        )
        var archivedFiles: [ArchivedFile] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true
            else {
                continue
            }
            archivedFiles.append(ArchivedFile(
                url: url,
                modificationDate: values.contentModificationDate ?? .distantPast
            ))
        }
        archivedFiles.sort {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate < $1.modificationDate
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        let expirationDate = now.addingTimeInterval(-Self.maximumArchiveAge)
        var retainedFiles: [ArchivedFile] = []
        for file in archivedFiles {
            let isProtected = protectedPaths.contains(file.url.standardizedFileURL.path)
            if file.modificationDate < expirationDate && !isProtected {
                try fileManager.removeItem(at: file.url)
            } else {
                retainedFiles.append(file)
            }
        }

        var excessCount = max(0, retainedFiles.count - Self.maximumArchivedFileCount)
        for file in retainedFiles where excessCount > 0 {
            guard !protectedPaths.contains(file.url.standardizedFileURL.path) else {
                continue
            }
            try fileManager.removeItem(at: file.url)
            excessCount -= 1
        }
    }

    private func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: url.path) {
            try validateManagedDirectory(url)
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try validateManagedDirectory(url)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private func validateManagedDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(
                .fileWriteNoPermission,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }
}

private struct ArchivedFile {
    let url: URL
    let modificationDate: Date
}
