import Darwin
import Foundation

@main
@MainActor
struct CodexBarTestRunner {
    static func main() async {
        var tests = hookParsingTestCases()
        tests += eventTransitionTestCases()
        tests += taskTimeFormatterTestCases()
        tests += panelLayoutTestCases()
        tests += detailSelectionTestCases()
        tests += inboxTestCases()
        tests += privacyStaticTestCases()
        tests += windowTitleMatchingTestCases()
        tests += windowActivationSequencingTestCases()
        tests += taskOpeningTestCases()
        tests += startupReconciliationTestCases()
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
