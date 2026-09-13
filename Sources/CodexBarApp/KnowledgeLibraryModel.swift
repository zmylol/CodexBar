import AppKit
import CodexBarCore
import CryptoKit
import Foundation

/// The total vault is independent of VS Code tasks; category previews share its cached changes.
@MainActor
final class KnowledgeLibraryModel: ObservableObject {
    @Published private(set) var review: KnowledgeVaultReview?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var sections: [KnowledgeFolderSection] = []
    @Published private(set) var noteCount = 0
    @Published private(set) var unseenChangeCount = 0
    @Published private(set) var todayArticles: [KnowledgeArticle] = []
    @Published private(set) var articleRange: KnowledgeArticleRange = .today
    @Published private(set) var visibleArticles: [KnowledgeArticle] = []

    private static let folderKey = "codexbar.knowledgeLibraryFolder"
    private static let receiptKey = "codexbar.knowledgeArticleReceipts"
    @Published private var seenArticleIDs: Set<String> = []
    private var receiptDates: [String: Double]
    private var readingScope: String?
    private var articles: [KnowledgeArticle] = []
    private var displayedDay: Date?
    private var dayTask: Task<Void, Never>?
    private let now: () -> Date
    private let defaults: UserDefaults
    private let registryURL: URL?
    private let monitor = KnowledgeFolderMonitor()
    private var worker: KnowledgeLibraryWorker?
    private var selectionGeneration: UUID?
    private var scanTask: Task<Void, Never>?
    private var scanID: UUID?
    private var scanRequested = false
    private var restoreTask: Task<Void, Never>?
    private var vaultPicker: NSOpenPanel?
    var isChoosingVault: Bool { vaultPicker != nil }

    init(defaultsSuiteName: String? = nil, registryURL: URL? = nil, now: @escaping () -> Date = { Date() }) {
        defaults = defaultsSuiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        self.registryURL = registryURL
        self.now = now
        receiptDates = defaults.dictionary(forKey: Self.receiptKey) as? [String: Double] ?? [:]
    }

    func start() {
        restoreTask?.cancel()
        restoreTask = Task { [weak self] in await self?.restoreNow() }
    }

    func stop() {
        let picker = vaultPicker
        vaultPicker = nil
        picker?.cancel(nil)
        selectionGeneration = nil
        restoreTask?.cancel()
        restoreTask = nil
        disconnect()
        message = nil
    }

    func restoreNow() async {
        guard !Task.isCancelled, review == nil else { return }
        let generation = UUID()
        selectionGeneration = generation
        let savedPath = defaults.string(forKey: Self.folderKey)
        let registryURL = registryURL
        do {
            let vault = try await Task.detached(priority: .userInitiated) { () throws -> ObsidianVault? in
                if let savedPath {
                    let url = URL(fileURLWithPath: savedPath, isDirectory: true)
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true, values?.isSymbolicLink != true,
                       let path = PathNormalizer.normalize(savedPath),
                       let vault = ObsidianVault.discover(cwd: path), vault.rootPath == path {
                        return vault
                    }
                }
                if let registryURL { return try ObsidianVaultDiscovery.defaultVault(registryURL: registryURL) }
                return try ObsidianVaultDiscovery.defaultVault()
            }.value
            guard !Task.isCancelled, selectionGeneration == generation, review == nil else { return }
            if let vault { await selectVault(URL(fileURLWithPath: vault.rootPath, isDirectory: true)) }
        } catch {
            guard !Task.isCancelled, selectionGeneration == generation, review == nil else { return }
            message = "无法自动读取 Obsidian 的知识库位置，请手动选择知识库总目录。"
        }
    }

    func pendingCount(in sectionID: String) -> Int {
        review?.notes.lazy.filter { !$0.isReviewed && self.belongs($0, to: sectionID) }.count ?? 0
    }

    func unseenCount(in sectionID: String) -> Int {
        visibleArticles.lazy.filter {
            $0.path.hasPrefix(sectionID + "/") && !self.seenArticleIDs.contains($0.id)
        }.count
    }

    func setArticleRange(_ range: KnowledgeArticleRange) {
        articleRange = range
        refreshToday()
    }

    /// Selecting a library acknowledges only articles in the visible range.
    func markUpdatesSeen(in sectionID: String) {
        refreshToday()
        guard sections.contains(where: { $0.id == sectionID }) else { return }
        var nextReceipts = receiptDates
        var acknowledgedKeys: Set<String> = []
        for article in visibleArticles where article.path.hasPrefix(sectionID + "/") {
            if let key = receiptID(for: article.path) {
                nextReceipts[key] = article.collectedAt.timeIntervalSince1970
                acknowledgedKeys.insert(key)
            }
        }
        storeReadingReceipts(nextReceipts, relativeTo: now(), prioritizing: acknowledgedKeys)
        restoreSeenArticles()
        refreshToday()
    }

    func refreshToday() {
        let date = now()
        let calendar = KnowledgeArticle.collectionCalendar
        let day = calendar.startOfDay(for: date)
        if displayedDay != day {
            displayedDay = day
            storeReadingReceipts(receiptDates, relativeTo: date)
        }
        let current = articles.filter { calendar.isDate($0.collectedAt, inSameDayAs: day) }
            .sorted { $0.collectedAt == $1.collectedAt ? $0.path < $1.path : $0.collectedAt > $1.collectedAt }
        if todayArticles != current { todayArticles = current }
        let interval = articleRange.interval(relativeTo: date)
        let visible = articles.filter { $0.collectedAt >= interval.start && $0.collectedAt < interval.end }
            .sorted { $0.collectedAt == $1.collectedAt ? $0.path < $1.path : $0.collectedAt > $1.collectedAt }
        if visibleArticles != visible { visibleArticles = visible }
        let unseenCount = current.lazy.filter { !self.seenArticleIDs.contains($0.id) }.count
        if unseenChangeCount != unseenCount { unseenChangeCount = unseenCount }
    }

    private func receiptID(for path: String) -> String? {
        guard let readingScope else { return nil }
        return SHA256.hash(data: Data("\(readingScope)\u{0}\(path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func restoreSeenArticles() {
        let seen = Set(articles.compactMap { article -> String? in
            guard let key = receiptID(for: article.path),
                  receiptDates[key] == article.collectedAt.timeIntervalSince1970 else { return nil }
            return article.id
        })
        if seenArticleIDs != seen { seenArticleIDs = seen }
    }

    private func storeReadingReceipts(
        _ receipts: [String: Double], relativeTo date: Date, prioritizing acknowledgedKeys: Set<String> = []
    ) {
        let interval = KnowledgeArticleRange.lastSevenDays.interval(relativeTo: date)
        let retained = receipts.filter { key, timestamp in
            key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && timestamp.isFinite && timestamp >= interval.start.timeIntervalSince1970
                && timestamp < interval.end.timeIntervalSince1970
        }.sorted {
            let firstIsAcknowledged = acknowledgedKeys.contains($0.key)
            let secondIsAcknowledged = acknowledgedKeys.contains($1.key)
            if firstIsAcknowledged != secondIsAcknowledged { return firstIsAcknowledged }
            return $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        let bounded = Dictionary(uniqueKeysWithValues: retained.prefix(KnowledgeFolderTracker.maximumNotes)
            .map { ($0.key, $0.value) })
        guard bounded != receiptDates else { return }
        receiptDates = bounded
        defaults.set(bounded, forKey: Self.receiptKey)
    }

    func review(for sectionID: String?) -> KnowledgeVaultReview? {
        guard let review else { return nil }
        guard let sectionID else { return review }
        guard let section = sections.first(where: { $0.id == sectionID }) else { return nil }
        return KnowledgeVaultReview(
            vault: ObsidianVault(rootPath: review.vault.rootPath, name: section.name),
            notes: review.notes.filter { belongs($0, to: sectionID) },
            isLoading: review.isLoading, message: review.message
        )
    }

    private func belongs(_ note: KnowledgeNoteChange, to sectionID: String) -> Bool {
        func matches(_ path: String) -> Bool {
            path.hasPrefix(sectionID + "/")
        }
        return matches(note.path) || note.previousPath.map(matches) == true
    }

    func chooseVault(in window: NSWindow) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let vaultPicker {
            vaultPicker.makeKeyAndOrderFront(nil)
            return
        }
        let picker = NSOpenPanel()
        picker.title = "选择知识库总目录"
        picker.message = "选择 Obsidian 中打开的整个知识库文件夹，知识库面板会自动列出其中的一级分类。无需寻找隐藏的 .obsidian 文件夹。"
        picker.prompt = "选择总目录"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        vaultPicker = picker
        window.makeKeyAndOrderFront(nil)
        picker.beginSheetModal(for: window) { [weak self, weak picker] response in
            guard let self, let picker, self.vaultPicker === picker else { return }
            self.vaultPicker = nil
            guard response == .OK, let url = picker.url else { return }
            Task { @MainActor [weak self] in await self?.selectVault(url) }
        }
    }

    func selectVault(_ url: URL) async {
        let selection = UUID()
        selectionGeneration = selection
        do {
            let vault = try await Task.detached(priority: .userInitiated) {
                guard let path = PathNormalizer.normalize(url.path),
                      let vault = ObsidianVault.discover(cwd: path), vault.rootPath == path else {
                    throw KnowledgeLibraryError.notVault
                }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw KnowledgeLibraryError.notVault
                }
                return vault
            }.value
            guard !Task.isCancelled, selectionGeneration == selection else { return }
            if worker != nil, review?.vault.rootPath == vault.rootPath {
                await refreshNow()
                return
            }
            disconnect()
            let nextWorker = KnowledgeLibraryWorker(vault: vault)
            // Observe before creating the baseline, so edits during initial reading
            // schedule a second pass instead of falling between setup and observation.
            try monitor.start(root: URL(fileURLWithPath: vault.rootPath, isDirectory: true)) { [weak self] in
                self?.refresh()
            }
            worker = nextWorker
            dayTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self else { return }
                    // Reproject cached metadata across midnight or wake; never poll the folder.
                    self.refreshToday()
                }
            }
            review = KnowledgeVaultReview(vault: vault, notes: [], isLoading: true,
                message: nil)
            message = nil
            defaults.set(vault.rootPath, forKey: Self.folderKey)
            await refreshNow()
        } catch {
            guard !Task.isCancelled, selectionGeneration == selection else { return }
            message = error is KnowledgeLibraryError
                ? "请选择 Obsidian 中打开的整个知识库文件夹，而不是其中的分类目录。"
                : "无法开始记录这个知识库，请检查文件夹是否仍存在且可读取。"
        }
    }

    func refresh() {
        Task { [weak self] in await self?.refreshNow() }
    }

    func refreshNow() async {
        guard let worker else { return }
        scanRequested = true
        if let scanTask {
            await scanTask.value
            return
        }
        let id = UUID()
        scanID = id
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if scanID == id {
                    scanID = nil
                    scanTask = nil
                    isLoading = false
                }
            }
            repeat {
                scanRequested = false
                do {
                    let next = try await worker.capture()
                    guard !Task.isCancelled, scanID == id, self.worker === worker else { return }
                    receive(next)
                    message = nil
                } catch {
                    guard !Task.isCancelled, scanID == id, self.worker === worker else { return }
                    if let current = review, current.isLoading {
                        review = KnowledgeVaultReview(vault: current.vault, notes: current.notes, isLoading: false,
                            message: "尚未建立笔记起点，恢复读取后开始记录新的变化。")
                    }
                    message = "暂时无法读取知识库，保留上次记录。请检查文件夹或点击刷新重试。"
                }
            } while scanRequested && !Task.isCancelled
        }
        scanTask = task
        await task.value
    }

    func toggleReview(_ note: KnowledgeNoteChange) {
        Task { [weak self] in await self?.toggleReviewNow(note) }
    }

    func toggleReviewNow(_ note: KnowledgeNoteChange) async {
        guard let worker else { return }
        let next = await worker.toggleReview(note)
        guard !Task.isCancelled, self.worker === worker else { return }
        receive(next)
    }

    func openNote(_ note: KnowledgeNoteChange) {
        guard let worker else { return }
        Task { [weak self] in
            let url = await worker.openURL(note)
            guard let self, self.worker === worker else { return }
            guard let url else {
                message = "这篇笔记已删除、移动或不在所选知识库中，无法打开。"
                return
            }
            if !NSWorkspace.shared.open(url) {
                message = "无法打开 Obsidian，请确认已经安装并打开过这个知识库。"
            }
        }
    }

    func openArticle(_ article: KnowledgeArticle) {
        guard let worker else { return }
        Task { [weak self] in
            let url = await worker.openArticleURL(article)
            guard let self, self.worker === worker else { return }
            guard let url else {
                message = "这篇文章已删除、移动或不在所选知识库中，无法打开。"
                return
            }
            if !NSWorkspace.shared.open(url) {
                message = "无法打开 Obsidian，请确认已经安装并打开过这个知识库。"
            }
        }
    }

    func openCodex() {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.caseInsensitiveCompare("Codex") == .orderedSame
        }), application.activate(options: [.activateIgnoringOtherApps]) else {
            message = "请先打开 Codex 桌面端；知识库的文件记录会继续运行。"
            return
        }
        message = nil
    }

    private var receivedRevision = -1

    private func receive(_ next: KnowledgeLibraryUpdate) {
        guard next.revision > receivedRevision else { return }
        receivedRevision = next.revision
        var nextReceipts = receiptDates
        if readingScope == next.rootFingerprint && !next.articleMoves.isEmpty {
            let oldDates = Dictionary(uniqueKeysWithValues: articles.map { ($0.path, $0.collectedAt) })
            let newDates = Dictionary(uniqueKeysWithValues: next.articles.map { ($0.path, $0.collectedAt) })
            for (previous, current) in next.articleMoves where seenArticleIDs.contains(previous)
                && oldDates[previous] == newDates[current] {
                if let oldKey = receiptID(for: previous), let newKey = receiptID(for: current),
                   let timestamp = nextReceipts.removeValue(forKey: oldKey) {
                    nextReceipts[newKey] = timestamp
                }
            }
        }
        readingScope = next.rootFingerprint
        storeReadingReceipts(nextReceipts, relativeTo: now())
        if review != next.review { review = next.review }
        articles = next.articles
        restoreSeenArticles()
        refreshToday()
        if noteCount != next.noteCount { noteCount = next.noteCount }
        if sections != next.sections {
            sections = next.sections
        }
    }

    private func disconnect() {
        monitor.stop()
        dayTask?.cancel()
        dayTask = nil
        scanTask?.cancel()
        scanTask = nil
        scanID = nil
        scanRequested = false
        worker = nil
        receivedRevision = -1
        readingScope = nil
        review = nil
        seenArticleIDs.removeAll()
        articles = []
        todayArticles = []
        visibleArticles = []
        displayedDay = nil
        unseenChangeCount = 0
        noteCount = 0
        if !sections.isEmpty {
            sections = []
        }
        isLoading = false
    }
}

private enum KnowledgeLibraryError: Error { case notVault }

private struct KnowledgeLibraryUpdate: Sendable {
    let review: KnowledgeVaultReview
    let revision: Int
    let rootFingerprint: String?
    let sections: [KnowledgeFolderSection]
    let noteCount: Int
    let articles: [KnowledgeArticle]
    let articleMoves: [String: String]
}

private actor KnowledgeLibraryWorker {
    private let tracker: KnowledgeFolderTracker
    private var ledger: KnowledgeReviewLedger
    private var revision = 0
    private var warnings: [String] = []
    private var sections: [KnowledgeFolderSection] = []
    private var noteCount = 0
    private var articles: [KnowledgeArticle] = []
    private var baselineID = UUID()
    private var rootFingerprint: String?
    private var articleMoves: [String: String] = [:]

    init(vault: ObsidianVault) {
        tracker = KnowledgeFolderTracker(vault: vault)
        ledger = KnowledgeReviewLedger(vault: vault, scopeID: UUID().uuidString)
    }

    func capture() async throws -> KnowledgeLibraryUpdate {
        let snapshot = try await tracker.capture()
        if baselineID != snapshot.baselineID {
            baselineID = snapshot.baselineID
            ledger = KnowledgeReviewLedger(vault: ledger.vault, scopeID: baselineID.uuidString)
        }
        ledger.receiveLatest(snapshot.changes, cwd: ledger.vault.rootPath)
        rootFingerprint = snapshot.rootFingerprint
        warnings = snapshot.warnings
        sections = snapshot.sections
        noteCount = snapshot.noteCount
        articles = snapshot.articles
        // The model receives each capture before starting the next one. Keep these moves in
        // review updates too, which may otherwise overtake a capture with a newer revision.
        articleMoves = snapshot.articleMoves
        return update()
    }

    func toggleReview(_ note: KnowledgeNoteChange) -> KnowledgeLibraryUpdate {
        if ledger.notes.contains(where: { $0.id == note.id && $0.version == note.version }) {
            ledger.toggleReview(noteID: note.id)
        }
        return update()
    }

    func openURL(_ note: KnowledgeNoteChange) -> URL? {
        guard let current = ledger.notes.first(where: { $0.id == note.id }), current.kind != "delete",
              let relative = ledger.vault.notePath(current.path, cwd: ledger.vault.rootPath) else { return nil }
        let file = URL(fileURLWithPath: ledger.vault.rootPath).appendingPathComponent(relative)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return ledger.vault.openURL(notePath: relative)
    }

    func openArticleURL(_ article: KnowledgeArticle) -> URL? {
        guard let current = articles.first(where: { $0.id == article.id && $0.collectedAt == article.collectedAt }),
              let relative = ledger.vault.notePath(current.path, cwd: ledger.vault.rootPath) else { return nil }
        let file = URL(fileURLWithPath: ledger.vault.rootPath).appendingPathComponent(relative)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return ledger.vault.openURL(notePath: relative)
    }

    private func update() -> KnowledgeLibraryUpdate {
        revision += 1
        let notices = warnings
        return KnowledgeLibraryUpdate(review: KnowledgeVaultReview(vault: ledger.vault, notes: ledger.recentNotes,
            isLoading: false, message: notices.isEmpty ? nil : notices.joined(separator: "\n")), revision: revision,
            rootFingerprint: rootFingerprint, sections: sections, noteCount: noteCount, articles: articles, articleMoves: articleMoves)
    }
}
