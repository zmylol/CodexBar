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
        CodexBarTestCase(name: "does not monitor Accessibility until the user opens settings") {
            var trigger = AccessibilityRecoveryTrigger()

            try expect(
                !trigger.isWaitingForGrant,
                "Accessibility monitoring was enabled before the user requested it"
            )
            try expect(
                !trigger.consumeGrant(isTrusted: true),
                "an unsolicited trust state launched recovery"
            )

            trigger.waitForGrant()
            try expect(
                trigger.isWaitingForGrant,
                "opening Accessibility settings did not arm recovery"
            )
        }
    ]
}
