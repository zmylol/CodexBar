import Darwin
import Foundation

@main
@MainActor
struct CodexBarTestRunner {
    static func main() async {
        var tests = hookParsingTestCases()
        tests += approvalPayloadTestCases()
        tests += eventTransitionTestCases()
        tests += runtimeStatusStoreTestCases()
        tests += runtimeStatusTestCases()
        tests += conversationPreviewTestCases()
        tests += knowledgeReviewTestCases()
        tests += knowledgeProjectionTestCases()
        tests += knowledgeFolderTestCases()
        tests += obsidianVaultDiscoveryTestCases()
        tests += runtimeStatusMonitoringTests()
        tests += taskTimeFormatterTestCases()
        tests += panelLayoutTestCases()
        tests += gitWorkspaceIdentityTestCases()
        tests += gitWorkspaceMonitoringTestCases()
        tests += gitWorkspaceTreeTestCases()
        tests += taskDetailSummaryTestCases()
        tests += openTaskRefreshFeedbackTestCases()
        tests += detailSelectionTestCases()
        tests += inboxTestCases()
        tests += inboxMonitoringTests()
        tests += privacyStaticTestCases()
        tests += accessibilityRecoveryTestCases()
        tests += windowTitleMatchingTestCases()
        tests += workspaceMetadataTestCases()
        tests += windowActivationSequencingTestCases()
        tests += taskOpeningTestCases()
        tests += startupReconciliationTestCases()
        tests += taskVisibilityTestCases()
        tests += windowSnapshotDiscoveryTestCases()
        tests += windowMonitorTestCases()
        tests += appServerSnapshotSourceTestCases()
        var failures = 0

        for test in tests {
            do {
                try await test.body()
                print("PASS \(test.name)")
            } catch {
                failures += 1
                print("FAIL \(test.name): \(error)")
            }
        }

        print("\(tests.count - failures)/\(tests.count) tests passed")
        if failures > 0 {
            exit(1)
        }
    }
}
