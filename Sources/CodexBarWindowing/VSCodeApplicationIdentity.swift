import Foundation

package struct VSCodeApplicationIdentity: Equatable, Sendable {
    package let processIdentifier: Int32
    package let bundleIdentifier: String
    package let launchDate: Date

    package init(
        processIdentifier: Int32,
        bundleIdentifier: String,
        launchDate: Date
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.launchDate = launchDate
    }

    package func matches(
        processIdentifier: Int32,
        bundleIdentifier: String?,
        launchDate: Date?,
        isTerminated: Bool,
        hasValidCodeSignature: Bool
    ) -> Bool {
        guard hasValidCodeSignature,
              !isTerminated,
              processIdentifier == self.processIdentifier,
              bundleIdentifier == self.bundleIdentifier,
              launchDate == self.launchDate
        else {
            return false
        }
        return true
    }
}
