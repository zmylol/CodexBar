import CodexBarWindowing

@MainActor
func accessibilityRecoveryTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "retries startup recovery once after Accessibility is granted") {
            var trigger = AccessibilityRecoveryTrigger()

            trigger.waitForGrant(reportCompletion: false)
            try expect(
                trigger.consumeGrant(isTrusted: false) == nil,
                "recovery ran before Accessibility was granted"
            )
            try expect(
                trigger.consumeGrant(isTrusted: true)?.reportCompletion == false,
                "the first granted state did not request recovery"
            )
            try expect(
                trigger.consumeGrant(isTrusted: true) == nil,
                "the same grant launched recovery more than once"
            )
        },
        CodexBarTestCase(name: "waits for an external grant after startup is denied") {
            var trigger = AccessibilityRecoveryTrigger()

            try expect(
                !trigger.isWaitingForGrant,
                "a fresh trigger should not monitor Accessibility"
            )
            try expect(
                trigger.consumeGrant(isTrusted: true) == nil,
                "an unsolicited trust state launched recovery"
            )

            // A denied startup recovery arms this even if the user opens
            // System Settings without going through CodexBar.
            trigger.waitForGrant(reportCompletion: false)
            try expect(
                trigger.isWaitingForGrant,
                "a denied startup did not arm recovery"
            )
            try expect(
                trigger.consumeGrant(isTrusted: true)?.reportCompletion == false,
                "an external grant did not launch the pending recovery"
            )
        },
        CodexBarTestCase(name: "preserves manual refresh feedback through Accessibility grant") {
            var trigger = AccessibilityRecoveryTrigger()

            trigger.waitForGrant(reportCompletion: false)
            trigger.waitForGrant(reportCompletion: true)

            try expect(
                trigger.consumeGrant(isTrusted: true)?.reportCompletion == true,
                "a manual refresh became a silent recovery after Accessibility was granted"
            )
        },
        CodexBarTestCase(name: "manual recovery consumes a pending Accessibility grant") {
            var trigger = AccessibilityRecoveryTrigger()

            trigger.waitForGrant(reportCompletion: true)
            trigger.prepareForAuthorizedRecovery()

            try expect(
                !trigger.isWaitingForGrant,
                "manual recovery left the grant wait armed"
            )
            try expect(
                trigger.consumeGrant(isTrusted: true) == nil,
                "the next application event launched a duplicate recovery"
            )
        }
    ]
}
