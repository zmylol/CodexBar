import CodexBarWindowing

@MainActor
func accessibilityRecoveryTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "retries startup recovery once after Accessibility is granted") {
            var trigger = AccessibilityRecoveryTrigger()

            trigger.waitForGrant()
            try expect(
                !trigger.consumeGrant(isTrusted: false),
                "recovery ran before Accessibility was granted"
            )
            try expect(
                trigger.consumeGrant(isTrusted: true),
                "the first granted state did not request recovery"
            )
            try expect(
                !trigger.consumeGrant(isTrusted: true),
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
                !trigger.consumeGrant(isTrusted: true),
                "an unsolicited trust state launched recovery"
            )

            // A denied startup recovery arms this even if the user opens
            // System Settings without going through CodexBar.
            trigger.waitForGrant()
            try expect(
                trigger.isWaitingForGrant,
                "a denied startup did not arm recovery"
            )
            try expect(
                trigger.consumeGrant(isTrusted: true),
                "an external grant did not launch the pending recovery"
            )
        }
    ]
}
