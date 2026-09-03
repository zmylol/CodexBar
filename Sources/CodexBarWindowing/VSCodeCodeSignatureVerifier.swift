import Foundation
import Security

enum VSCodeCodeSignatureVerifier {
    private static let requirement = #"anchor apple generic and identifier "com.microsoft.VSCode" and certificate leaf[subject.OU] = "UBF8T346G9""#

    static func isOfficialVisualStudioCode(processIdentifier: pid_t) -> Bool {
        let attributes = [
            kSecGuestAttributePid: NSNumber(value: processIdentifier)
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            return false
        }

        var codeRequirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirement as CFString,
            [],
            &codeRequirement
        ) == errSecSuccess,
              let codeRequirement
        else {
            return false
        }

        return SecCodeCheckValidity(code, [], codeRequirement) == errSecSuccess
    }
}
