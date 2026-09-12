import Foundation

@MainActor
func privacyStaticTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "app source does not install a global keyboard monitor") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appSource = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
            let sourceURLs = try FileManager.default.contentsOfDirectory(
                at: appSource,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "swift" }
            let offenders = try sourceURLs.compactMap { url -> String? in
                let source = try String(contentsOf: url, encoding: .utf8)
                return source.contains("addGlobalMonitorForEvents")
                    ? url.lastPathComponent
                    : nil
            }

            try expect(
                offenders.isEmpty,
                "global keyboard monitor remains in: \(offenders.joined(separator: ", "))"
            )
        },
        CodexBarTestCase(name: "window discovery preserves and revalidates process identity") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarWindowing", isDirectory: true)
                .appendingPathComponent("AccessibilityWindowActivator.swift")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)

            try expect(
                !source.contains("processIdentifiers:"),
                "window discovery reduced a verified app identity to a reusable PID"
            )
            try expect(
                source.contains("applicationIdentities:")
                    && source.contains("isCurrentApplication"),
                "window discovery does not revalidate the full app identity"
            )
        },
        CodexBarTestCase(name: "app validates storage before constructing the task store") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarApp.swift")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let preparation = source.range(of: "try paths.prepareStorageDirectory()")
            let storeConstruction = source.range(of: "TaskStore(persistenceURL: paths.taskStore)")

            try expect(preparation != nil, "app startup does not prepare private storage")
            try expect(storeConstruction != nil, "task store construction was not found")
            if let preparation, let storeConstruction {
                try expect(
                    preparation.lowerBound < storeConstruction.lowerBound,
                    "task store is constructed before private storage is validated"
                )
            }
        },
        CodexBarTestCase(name: "old-task cleanup uses asynchronous window discovery") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarAppModel.swift")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)

            try expect(
                !source.contains("activator.discoverWindows()"),
                "old-task cleanup performs Accessibility I/O on the main actor"
            )
            try expect(
                source.contains("await activator.discoverWindowSnapshotAsync()"),
                "old-task cleanup does not use asynchronous window discovery"
            )
        },
        CodexBarTestCase(name: "task selection only activates an existing VS Code window") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appModelURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarAppModel.swift")
            let legacyOpenerURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarWindowing", isDirectory: true)
                .appendingPathComponent("CodexTaskOpener.swift")
            let source = try String(contentsOf: appModelURL, encoding: .utf8)

            try expect(
                source.contains("await activator.activateWindow(")
                    && source.contains("promptForAccessibility: false"),
                "task selection does not directly use VS Code window activation"
            )
            try expect(
                !source.contains("taskOpener")
                    && !FileManager.default.fileExists(atPath: legacyOpenerURL.path),
                "task selection still includes a cross-client opener or fallback"
            )
        },
        CodexBarTestCase(name: "task persistence stays off the main actor") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let coreSourceURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarCore", isDirectory: true)
                .appendingPathComponent("TaskStore.swift")
            let appSourceURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarApp.swift")
            let coreSource = try String(contentsOf: coreSourceURL, encoding: .utf8)
            let appSource = try String(contentsOf: appSourceURL, encoding: .utf8)
            let mainActorSource = coreSource.components(
                separatedBy: "private actor TaskStoreStorage"
            ).first ?? coreSource
            let storageActorSource = coreSource.components(
                separatedBy: "private actor TaskStoreStorage"
            ).last ?? ""

            try expect(
                coreSource.contains("private actor TaskStoreStorage"),
                "task persistence is not serialized by a storage actor"
            )
            try expect(
                coreSource.contains("public func load() async"),
                "task snapshots are still loaded synchronously during initialization"
            )
            try expect(
                coreSource.contains("private var publishedRevision")
                    && coreSource.contains("state.revision > publishedRevision"),
                "late main-actor resumptions can publish an older storage revision"
            )
            try expect(
                !storageActorSource.contains("await "),
                "storage transactions can reenter the actor before their commit finishes"
            )
            try expect(
                !mainActorSource.contains("Data(contentsOf:")
                    && !mainActorSource.contains("JSONEncoder")
                    && !mainActorSource.contains("JSONDecoder")
                    && !mainActorSource.contains("FileManager.default")
                    && !mainActorSource.contains(".sorted {"),
                "TaskStore still performs filesystem, JSON, or sorting work on the main actor"
            )
            try expect(
                mainActorSource.contains("guard !events.isEmpty else"),
                "empty event batches still enter storage and rebuild sorted view state"
            )
            try expect(
                appSource.contains("await store.load()"),
                "app startup does not await the background snapshot load"
            )
            try expect(
                appSource.contains("try await Task.detached")
                    && appSource.contains("try paths.prepareStorageDirectory()"),
                "app startup still prepares its storage directory on the main actor"
            )
        },
        CodexBarTestCase(name: "normal synchronization uses events without periodic data polling") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appModelURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarAppModel.swift")
            let appModelSource = try String(contentsOf: appModelURL, encoding: .utf8)

            try expect(
                !appModelSource.contains("Timer.scheduledTimer")
                    && !appModelSource.contains("pollInbox")
                    && !appModelSource.contains("nextWindowScanAt")
                    && !appModelSource.contains("nextWindowRecoveryAt"),
                "the application still wakes periodically to scan tasks or windows"
            )

            try expect(
                !appModelSource.contains("TaskRecoveryThrottle(interval: 5)"),
                "normal polling still keeps an App Server recovery throttle"
            )
            try expect(
                !appModelSource.contains("reconcileAppServerTasks(force: false)"),
                "the normal poll loop still launches App Server recovery"
            )
            try expect(
                !appModelSource.contains("matchingActiveTasks: activeTasks")
                    && !appModelSource.contains("reconcileActiveTasks("),
                "the app still queries persisted turns for live tasks"
            )
            try expect(
                appModelSource.contains("startupRecoveryID")
                    && appModelSource.contains("startupRecoveryID == recoveryID"),
                "startup App Server recovery has no stale-task identity guard"
            )
            let cancellationGuard =
                "guard !Task.isCancelled, startupRecoveryID == recoveryID else"
            let cancellationGuardCount = appModelSource.components(
                separatedBy: cancellationGuard
            ).count - 1
            try expect(
                cancellationGuardCount >= 3,
                "cancelled or superseded startup recovery can report stale failures"
            )
        },
        CodexBarTestCase(name: "startup recovery exposes compact progress and final task count") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appRoot = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
            let modelSource = try String(
                contentsOf: appRoot.appendingPathComponent("CodexBarAppModel.swift"),
                encoding: .utf8
            )
            let viewSource = try String(
                contentsOf: appRoot.appendingPathComponent("TaskListView.swift"),
                encoding: .utf8
            )

            try expect(
                modelSource.contains("@Published private(set) var isRecoveringOpenTasks"),
                "startup recovery has no observable progress state"
            )
            try expect(
                viewSource.contains("model.isRecoveringOpenTasks")
                    && viewSource.contains("正在同步已打开的 VS Code Codex 任务")
                    && viewSource.contains("model.visibleTasks.count"),
                "the compact header does not expose recovery progress and the final task count"
            )
        },
        CodexBarTestCase(name: "header exposes a permanent knowledge entry and on-demand task refresh") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appRoot = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
            let modelSource = try String(
                contentsOf: appRoot.appendingPathComponent("CodexBarAppModel.swift"),
                encoding: .utf8
            )
            let viewSource = try String(
                contentsOf: appRoot.appendingPathComponent("TaskListView.swift"),
                encoding: .utf8
            )
            let headerSource = viewSource.components(
                separatedBy: "private var header: some View"
            ).last?.components(separatedBy: "@ViewBuilder").first ?? ""
            let refreshSource = modelSource.components(
                separatedBy: "func refreshOpenTasks()"
            ).last?.components(
                separatedBy: "func requestAccessibilityPermission()"
            ).first ?? ""
            let startSource = modelSource.components(
                separatedBy: "func start()"
            ).last?.components(
                separatedBy: "func stop()"
            ).first ?? ""
            let environmentChangeSource = modelSource.components(
                separatedBy: "private func handleWindowEnvironmentChange()"
            ).last?.components(
                separatedBy: "private func processInbox()"
            ).first ?? ""
            let recoverySource = modelSource.components(
                separatedBy: "private func recoverStartupTasks("
            ).last?.components(
                separatedBy: "private func logRecoveryFailureIfNeeded"
            ).first ?? ""

            try expect(
                headerSource.contains("action: model.refreshOpenTasks")
                    && headerSource.contains(".disabled(model.isRecoveringOpenTasks)"),
                "the header menu has no disabled-while-syncing refresh control"
            )
            try expect(
                headerSource.contains("Button(action: onKnowledgeRequested)")
                    && headerSource.contains("Image(systemName: \"book.closed\")")
                    && headerSource.contains(".accessibilityLabel(\"知识库\")"),
                "the header has no permanent accessible knowledge entry"
            )
            try expect(
                headerSource.contains("刷新已打开的 VS Code Codex 任务"),
                "the refresh control has no accessible description"
            )
            let hiddenMenuIndicatorCount = viewSource.components(
                separatedBy: ".menuIndicator(.hidden)"
            ).count - 1
            try expect(
                headerSource.contains("HStack(spacing: 3)")
                    && headerSource.contains(".padding(.leading, 6)")
                    && !headerSource.contains("Text(\"· \\(model.visibleTasks.count)\")")
                    && hiddenMenuIndicatorCount >= 2,
                "the compact bar does not adapt its header and menus to the narrow width"
            )
            try expect(
                viewSource.contains(
                    ".accessibilityValue(\"\\(model.visibleTasks.count) 个任务\")"
                ),
                "the task bar does not expose its task count to VoiceOver"
            )
            if let menuPosition = headerSource.range(of: "Menu {")?.lowerBound,
               let knowledgePosition = headerSource.range(
                   of: "Button(action: onKnowledgeRequested)"
               )?.lowerBound {
                try expect(
                    menuPosition < knowledgePosition,
                    "the knowledge entry is not the rightmost header action"
                )
            } else {
                throw TestFailure(description: "header action positions were not found")
            }
            try expect(
                refreshSource.contains("guard AccessibilityAuthorization.isTrusted else")
                    && refreshSource.contains("waitForGrant(reportCompletion: true)")
                    && refreshSource.contains("showsAccessibilityAction: true")
                    && refreshSource.contains("recoverStartupTasks(reportCompletion: true)"),
                "manual refresh does not start recovery or explain missing Accessibility access"
            )
            try expect(
                environmentChangeSource.contains("let recoveryRequest = accessibilityRecoveryTrigger.consumeGrant")
                    && environmentChangeSource.contains(
                        "reportCompletion: recoveryRequest.reportCompletion"
                    ),
                "an Accessibility grant discards the pending manual refresh feedback"
            )
            try expect(
                recoverySource.contains("reportCompletion")
                    && recoverySource.contains("showRefreshFeedback(.noOpenWindows")
                    && recoverySource.contains("showRefreshFeedback(.failed")
                    && recoverySource.contains(".completed(")
                    && recoverySource.contains("showRefreshFeedback(.persistenceFailed"),
                "manual refresh terminal branches are not routed to visible feedback"
            )
            try expect(
                startSource.contains("recoverStartupTasks(reportCompletion: false)"),
                "automatic startup recovery can show manual refresh notices"
            )
        },
        CodexBarTestCase(name: "header actions avoid native titlebar hit interception") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appRoot = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
            let controllerSource = try String(
                contentsOf: appRoot.appendingPathComponent("FloatingPanelController.swift"),
                encoding: .utf8
            )
            let viewSource = try String(
                contentsOf: appRoot.appendingPathComponent("TaskListView.swift"),
                encoding: .utf8
            )
            let panelConstruction = controllerSource.components(
                separatedBy: "self.panel = CodexBarPanel("
            ).last?.components(
                separatedBy: "self.detailPanel = CodexBarDetailPanel("
            ).first ?? ""
            let taskListRoot = viewSource.components(
                separatedBy: "struct TaskListView: View {"
            ).last?.components(
                separatedBy: "private var header: some View"
            ).first ?? ""
            let headerSource = viewSource.components(
                separatedBy: "private var header: some View"
            ).last?.components(
                separatedBy: "@ViewBuilder"
            ).first ?? ""
            let dragHandleSource = headerSource.components(
                separatedBy: "PanelDragHandle()"
            ).last?.components(
                separatedBy: "HStack(spacing: 5)"
            ).first ?? ""

            try expect(
                panelConstruction.contains("styleMask: [.borderless, .nonactivatingPanel]")
                    && !panelConstruction.contains(".fullSizeContentView")
                    && !panelConstruction.contains(".titled"),
                "header actions are still rendered behind the native titlebar"
            )
            try expect(
                controllerSource.contains("panel.isMovableByWindowBackground = false")
                    && !controllerSource.contains("panel.isMovableByWindowBackground = true")
                    && headerSource.contains("PanelDragHandle()")
                    && dragHandleSource.contains(
                        ".frame(maxWidth: .infinity, maxHeight: .infinity)"
                    )
                    && viewSource.contains("override func acceptsFirstMouse(")
                    && viewSource.contains("window?.performDrag(with: event)"),
                "the dedicated drag handle can be empty, steal controls, or ignore the first mouse press"
            )
            let nonInteractiveDecorationCount = taskListRoot.components(
                separatedBy: ".allowsHitTesting(false)"
            ).count - 1
            try expect(
                nonInteractiveDecorationCount >= 2,
                "decorative root overlays can still intercept pointer events"
            )
        },
        CodexBarTestCase(name: "Accessibility grant recovery is armed after a denied startup") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let sourceURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarAppModel.swift")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)

            try expect(
                source.contains("accessibilityRecoveryTrigger.waitForGrant("),
                "Accessibility denial does not arm a one-shot recovery"
            )
            let recoverySource = source.components(
                separatedBy: "private func recoverStartupTasks("
            ).last?.components(
                separatedBy: "private func logRecoveryFailureIfNeeded"
            ).first ?? ""
            try expect(
                recoverySource.contains("guard AccessibilityAuthorization.isTrusted else")
                    && recoverySource.contains("accessibilityRecoveryTrigger.waitForGrant(")
                    && recoverySource.contains("reportCompletion: reportCompletion"),
                "startup recovery does not wait for a grant when Accessibility is denied"
            )
            try expect(
                recoverySource.contains(
                    "accessibilityRecoveryTrigger.prepareForAuthorizedRecovery()"
                ) && recoverySource.contains("dismissAccessibilityNotice()"),
                "authorized recovery leaves stale grant state or a stale permission notice"
            )
            let noticeDismissalSource = source.components(
                separatedBy: "private func dismissAccessibilityNotice()"
            ).last?.components(
                separatedBy: "private func showNotice("
            ).first ?? ""
            try expect(
                noticeDismissalSource.contains("notice?.showsAccessibilityAction == true")
                    && noticeDismissalSource.contains("notice = nil"),
                "authorized recovery does not clear only the obsolete permission notice"
            )
            try expect(
                source.contains("accessibilityRecoveryTrigger.isWaitingForGrant")
                    && source.contains("accessibilityRecoveryTrigger.consumeGrant("),
                "application events do not consume the one-shot grant"
            )
        },
        CodexBarTestCase(name: "startup recovery requests only VS Code thread metadata") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let coreRoot = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarCore", isDirectory: true)
            let snapshotSource = try String(
                contentsOf: coreRoot.appendingPathComponent(
                    "CodexAppServerThreadSnapshotSource.swift"
                ),
                encoding: .utf8
            )
            let snapshotContract = try String(
                contentsOf: coreRoot.appendingPathComponent("CodexThreadSnapshot.swift"),
                encoding: .utf8
            )
            let taskStore = try String(
                contentsOf: coreRoot.appendingPathComponent("TaskStore.swift"),
                encoding: .utf8
            )
            let startupReconciler = try String(
                contentsOf: coreRoot.appendingPathComponent("StartupTaskReconciler.swift"),
                encoding: .utf8
            )

            try expect(
                snapshotSource.contains(#""sourceKinds": ["vscode"]"#)
                    && snapshotSource.contains(#"value["source"] as? String == "vscode""#),
                "App Server recovery does not fix and verify the VS Code source"
            )
            try expect(
                !snapshotSource.contains("matchingActiveTasks")
                    && !snapshotSource.contains(#"method: "thread/read""#)
                    && !snapshotContract.contains("matchingActiveTasks")
                    && !snapshotContract.contains("CodexThreadSource")
                    && !taskStore.contains("matchingExistingTaskIDs")
                    && !taskStore.contains("markTerminalChangesUnread")
                    && !taskStore.contains("mergeSameRecoveredTurn")
                    && !startupReconciler.contains("matchingExistingTaskIDs"),
                "startup recovery still exposes a CLI or active-task query path"
            )
            try expect(
                !FileManager.default.fileExists(
                    atPath: coreRoot.appendingPathComponent("TaskRecoveryThrottle.swift").path
                ),
                "the obsolete periodic recovery throttle still exists"
            )
        },
        CodexBarTestCase(name: "App Server failures use privacy-safe rate-limited diagnostics") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appModelURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarAppModel.swift")
            let source = try String(contentsOf: appModelURL, encoding: .utf8)

            try expect(source.contains("Logger("), "App Server failures have no system diagnostic")
            try expect(
                source.contains("nextRecoveryErrorLogAt"),
                "App Server failure diagnostics are not rate limited"
            )
            try expect(
                source.contains("App Server reconciliation failed; Hook state remains authoritative."),
                "App Server failure diagnostic is not a fixed privacy-safe message"
            )
        },
        CodexBarTestCase(name: "filesystem-backed task matching stays off the main actor") {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let appModelURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarApp", isDirectory: true)
                .appendingPathComponent("CodexBarAppModel.swift")
            let reconcilerURL = repositoryRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("CodexBarCore", isDirectory: true)
                .appendingPathComponent("StartupTaskReconciler.swift")
            let appModelSource = try String(contentsOf: appModelURL, encoding: .utf8)
            let reconcilerSource = try String(contentsOf: reconcilerURL, encoding: .utf8)
            let reconcilerMainActorSource = reconcilerSource.components(
                separatedBy: "private actor StartupTaskRecoveryWorker"
            ).first ?? reconcilerSource

            try expect(
                appModelSource.contains("private actor OldTaskCleanupWorker")
                    && appModelSource.contains("await oldTaskCleanupWorker.staleTasks"),
                "old-task cleanup still resolves workspace paths on the main actor"
            )
            try expect(
                reconcilerSource.contains("private actor StartupTaskRecoveryWorker")
                    && reconcilerSource.contains("await worker.recoveredTasks"),
                "startup reconciliation has no background path-matching worker"
            )
            try expect(
                !reconcilerMainActorSource.contains("PathNormalizer.normalize")
                    && !reconcilerMainActorSource.contains("matcher.match"),
                "startup reconciliation still resolves workspace paths on the main actor"
            )
        }
    ]
}
