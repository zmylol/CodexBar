import CodexBarCore
import Combine
import Foundation

protocol GitWorkspaceBrowserService: Sendable {
    func snapshot() async throws -> GitWorkspaceSnapshot
    func addProject(directory: URL) async throws -> GitWorkspaceSnapshot
    func createWorktree(from: String, at: URL, branch: String) async throws -> GitWorkspaceSnapshot
    func switchBranch(in directory: String, to branch: String) async throws -> GitWorkspaceSnapshot
    func localBranches(in directory: String) async throws -> [String]
    func workspaceRoot(for directory: String) async -> String?
}

extension GitWorkspaceBrowserService {
    func workspaceRoot(for directory: String) async -> String? {
        await Task.detached(priority: .utility) {
            GitWorkspaceIdentityReader.read(cwd: directory)?.workspaceRoot
        }.value
    }
}

extension GitWorkspaceService: GitWorkspaceBrowserService {}

struct GitWorkspaceBrowserRow: Identifiable {
    var id: String { record.workspaceRoot }
    let record: GitWorkspaceRecord
    let depth: Int
    let hasUnknownOrigin: Bool
}

@MainActor
final class GitWorkspaceBrowserModel: ObservableObject {
    @Published private(set) var snapshot = GitWorkspaceSnapshot(records: [], identities: [:])
    @Published private(set) var activeDirectory: String?
    @Published private(set) var branches: [String] = []
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isLoadingBranches = false
    @Published var errorMessage: String?
    var onSnapshotChange: ((GitWorkspaceSnapshot) -> Void)?

    private let service: any GitWorkspaceBrowserService
    private let defaults: UserDefaults
    private let monitor = GitWorkspaceMonitor(includeStandalone: true)
    private let selectionKey = "GitWorkspaceBrowser.selectedDirectory"
    private var isStarted = false
    private var lifetimeID = UUID()
    private var selectionID = UUID()
    private var refreshID = UUID()
    private var branchID = UUID()
    private var refreshTask: Task<Void, Never>?
    private var branchTask: Task<Void, Never>?
    private var refreshRequested = false
    private var pendingFollow: String?

    init(service: any GitWorkspaceBrowserService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        activeDirectory = defaults.string(forKey: selectionKey)
    }

    var activeIdentity: GitWorkspaceIdentity? {
        activeDirectory.flatMap { snapshot.identities[$0] }
    }

    var rows: [GitWorkspaceBrowserRow] { Self.rows(for: snapshot) }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        lifetimeID = UUID()
        monitor.start(cwds: Set(snapshot.records.map(\.workspaceRoot))) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func stop() {
        isStarted = false
        lifetimeID = UUID()
        selectionID = UUID()
        refreshID = UUID()
        branchID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        branchTask?.cancel()
        branchTask = nil
        monitor.stop()
        isRefreshing = false
        isLoadingBranches = false
        pendingFollow = nil
    }

    func refresh() {
        guard isStarted else { return }
        guard !isBusy, refreshTask == nil else { refreshRequested = true; return }
        refreshRequested = false
        isRefreshing = true
        let id = UUID()
        refreshID = id
        refreshTask = Task { [weak self, service] in
            do {
                let updated = try await service.snapshot()
                guard let self, self.refreshID == id, !Task.isCancelled else { return }
                self.apply(updated)
                self.loadBranches()
            } catch {
                guard let self, self.refreshID == id, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
            guard let self, self.refreshID == id else { return }
            self.refreshTask = nil
            self.isRefreshing = false
            if self.refreshRequested { self.refresh() }
        }
    }

    func selectDirectory(_ directory: String) {
        guard snapshot.records.contains(where: { $0.workspaceRoot == directory }) else { return }
        selectionID = UUID()
        pendingFollow = nil
        setSelection(directory)
    }

    func followDirectory(_ directory: String) {
        let canonical = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        if snapshot.records.contains(where: { $0.workspaceRoot == canonical }) {
            selectionID = UUID()
            pendingFollow = nil
            if activeDirectory != canonical { setSelection(canonical) }
            return
        }
        selectionID = UUID()
        pendingFollow = canonical
        resolvePendingFollow()
    }

    func addProject(_ directory: URL) async {
        await mutate(preferredDirectory: directory.path) { service in
            try await service.addProject(directory: directory)
        }
    }

    func createWorktree(from source: String, at destination: URL, branch: String) async {
        await mutate(preferredDirectory: destination.path) { service in
            try await service.createWorktree(from: source, at: destination, branch: branch)
        }
    }

    func switchBranch(_ branch: String, in requestedDirectory: String? = nil) async {
        guard let directory = requestedDirectory ?? activeDirectory,
              snapshot.identities[directory] != nil else { return }
        await mutate { service in try await service.switchBranch(in: directory, to: branch) }
    }

    private func mutate(
        preferredDirectory: String? = nil,
        reportsError: Bool = true,
        operation: @Sendable (any GitWorkspaceBrowserService) async throws -> GitWorkspaceSnapshot
    ) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
        branchID = UUID()
        branchTask?.cancel()
        branchTask = nil
        isLoadingBranches = false
        let lifetime = lifetimeID
        let selection = selectionID
        do {
            let updated = try await operation(service)
            guard lifetimeID == lifetime else { finishMutation(); return }
            apply(updated)
            if selectionID == selection, let preferredDirectory,
               let match = workspace(containing: URL(fileURLWithPath: preferredDirectory).standardizedFileURL.resolvingSymlinksInPath().path) {
                setSelection(match)
            } else {
                loadBranches()
            }
        } catch {
            let operationError = error
            if let updated = try? await service.snapshot(), lifetimeID == lifetime {
                apply(updated)
                loadBranches()
            }
            if lifetimeID == lifetime, reportsError { errorMessage = operationError.localizedDescription }
        }
        finishMutation()
    }

    private func finishMutation() {
        isBusy = false
        resolvePendingFollow()
        if refreshRequested { refresh() }
    }

    private func resolvePendingFollow() {
        guard !isBusy, let directory = pendingFollow else { return }
        pendingFollow = nil
        let selection = selectionID
        Task { [weak self] in
            guard let self, self.selectionID == selection else { return }
            // Resolve Git's nearest actual checkout before matching registered paths:
            // a nested independent repository must not select its containing project.
            let resolvedRoot = await self.service.workspaceRoot(for: directory)
            guard self.selectionID == selection else { return }
            if let registered = self.workspace(containing: directory) {
                let remainsInside = resolvedRoot.map {
                    $0 == registered || $0.hasPrefix(registered == "/" ? "/" : registered + "/")
                } ?? false
                if !remainsInside {
                    // Missing .git metadata must not turn a saved child checkout into
                    // its containing repository. A valid deeper repository still wins.
                    self.selectDirectory(registered)
                    return
                }
            }
            guard let root = resolvedRoot else { return }
            if self.snapshot.identities[root] != nil {
                self.selectDirectory(root)
            } else if self.isBusy {
                self.pendingFollow = root
            } else {
                await self.mutate(preferredDirectory: root, reportsError: false) { service in
                    try await service.addProject(directory: URL(fileURLWithPath: root))
                }
            }
        }
    }

    private func apply(_ updated: GitWorkspaceSnapshot) {
        snapshot = updated
        if activeDirectory == nil || !updated.records.contains(where: { $0.workspaceRoot == activeDirectory }) {
            setSelection(updated.records.sorted { $0.order < $1.order }.first?.workspaceRoot)
        }
        if isStarted { monitor.setCWDs(Set(updated.records.map(\.workspaceRoot))) }
        onSnapshotChange?(updated)
    }

    private func setSelection(_ directory: String?) {
        activeDirectory = directory
        defaults.set(directory, forKey: selectionKey)
        loadBranches()
    }

    private func workspace(containing directory: String) -> String? {
        snapshot.records.map(\.workspaceRoot).filter {
            directory == $0 || directory.hasPrefix($0 == "/" ? "/" : $0 + "/")
        }.max { $0.count < $1.count }
    }

    private func loadBranches() {
        branchTask?.cancel()
        let id = UUID()
        branchID = id
        branches = []
        guard let directory = activeDirectory, snapshot.identities[directory] != nil else {
            isLoadingBranches = false
            return
        }
        isLoadingBranches = true
        branchTask = Task { [weak self, service] in
            do {
                let names = try await service.localBranches(in: directory)
                guard let self, self.branchID == id, self.activeDirectory == directory, !Task.isCancelled else { return }
                self.branches = names
            } catch {
                guard let self, self.branchID == id, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
            guard let self, self.branchID == id else { return }
            self.isLoadingBranches = false
            self.branchTask = nil
        }
    }

    static func rows(for snapshot: GitWorkspaceSnapshot) -> [GitWorkspaceBrowserRow] {
        let records = snapshot.records.sorted {
            $0.order == $1.order ? $0.workspaceRoot < $1.workspaceRoot : $0.order < $1.order
        }
        let byPath = Dictionary(records.map { ($0.workspaceRoot, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [String: [GitWorkspaceRecord]] = [:]
        var roots: [GitWorkspaceRecord] = []
        for record in records {
            if let parent = record.parentWorkspaceRoot, parent != record.workspaceRoot,
               byPath[parent]?.repositoryID == record.repositoryID {
                children[parent, default: []].append(record)
            } else { roots.append(record) }
        }
        var result: [GitWorkspaceBrowserRow] = []
        var visited = Set<String>()
        func append(_ root: GitWorkspaceRecord) {
            var pending = [(root, 0)]
            while let (record, depth) = pending.popLast() {
                guard visited.insert(record.workspaceRoot).inserted else { continue }
                let parent = record.parentWorkspaceRoot.flatMap { byPath[$0] }
                result.append(GitWorkspaceBrowserRow(
                    record: record, depth: depth,
                    hasUnknownOrigin: !record.isMainWorkspace && (parent == nil || parent?.repositoryID != record.repositoryID || depth == 0)
                ))
                pending += (children[record.workspaceRoot] ?? []).reversed().map { ($0, depth + 1) }
            }
        }
        for root in roots { append(root) }
        // Corrupt parent cycles remain visible without inventing a creation relationship.
        for record in records where !visited.contains(record.workspaceRoot) { append(record) }
        return result
    }
}
