import CodexBarCore
import Foundation

@MainActor
func obsidianVaultDiscoveryTestCases() -> [CodexBarTestCase] {
    [
        CodexBarTestCase(name: "Obsidian registry discovery returns the only valid registered vault") {
            try withObsidianRegistry { root, registry in
                let vault = try registeredVault("Knowledge", in: root)
                try writeObsidianRegistry(["one": ["path": vault.path], "missing": ["path": root.appendingPathComponent("Missing").path]], to: registry)
                let result = try ObsidianVaultDiscovery.defaultVault(registryURL: registry)
                try expect(result == ObsidianVault(rootPath: vault.path, name: "Knowledge"), "unique registered vault was not discovered")
                try writeObsidianRegistry(["one": ["path": vault.path], "duplicate": ["path": vault.path, "open": true]], to: registry)
                try expect(try ObsidianVaultDiscovery.defaultVault(registryURL: registry) == result, "duplicate registrations became ambiguous")
            }
        },
        CodexBarTestCase(name: "Obsidian registry discovery prefers only one open vault and leaves ambiguity to the user") {
            try withObsidianRegistry { root, registry in
                let first = try registeredVault("One", in: root)
                let second = try registeredVault("Two", in: root)
                try writeObsidianRegistry(["one": ["path": first.path], "two": ["path": second.path]], to: registry)
                try expect(try ObsidianVaultDiscovery.defaultVault(registryURL: registry) == nil, "arbitrary vault selected from ambiguous registry")
                try writeObsidianRegistry(["one": ["path": first.path], "two": ["path": second.path, "open": true]], to: registry)
                try expect(try ObsidianVaultDiscovery.defaultVault(registryURL: registry)?.rootPath == second.path, "unique open vault was not preferred")
                try writeObsidianRegistry(["one": ["path": first.path, "open": true], "two": ["path": second.path, "open": true]], to: registry)
                try expect(try ObsidianVaultDiscovery.defaultVault(registryURL: registry) == nil, "multiple open vaults were treated as one")
            }
        },
        CodexBarTestCase(name: "Obsidian registry discovery rejects invalid paths and symlink markers without scanning for vaults") {
            try withObsidianRegistry { root, registry in
                let real = try registeredVault("Unregistered", in: root)
                let ordinary = root.appendingPathComponent("Ordinary")
                try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
                let linked = root.appendingPathComponent("Linked")
                try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
                let fake = root.appendingPathComponent("Fake")
                try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: fake.appendingPathComponent(".obsidian"), withDestinationURL: real.appendingPathComponent(".obsidian"))
                try writeObsidianRegistry([
                    "relative": ["path": "Knowledge"], "url": ["path": "https://example.com/vault"],
                    "root": ["path": "/"], "control": ["path": root.path + "/bad\nname"],
                    "ordinary": ["path": ordinary.path], "linked": ["path": linked.path], "fake": ["path": fake.path]
                ], to: registry)
                try expect(try ObsidianVaultDiscovery.defaultVault(registryURL: registry) == nil, "invalid registration or an unregistered neighboring vault was selected")
            }
        },
        CodexBarTestCase(name: "Obsidian registry discovery returns nil when absent and reports damaged or oversized configuration") {
            try withObsidianRegistry { _, registry in
                try expect(try ObsidianVaultDiscovery.defaultVault(registryURL: registry) == nil, "absent registry was an error")
                for text in ["{broken", "[]", "{\"vaults\":[]}", String(repeating: "x", count: 1_024 * 1_024 + 1)] {
                    try Data(text.utf8).write(to: registry)
                    var rejected = false
                    do { _ = try ObsidianVaultDiscovery.defaultVault(registryURL: registry) } catch { rejected = true }
                    try expect(rejected, "damaged or oversized registry silently selected a vault")
                }
                try Data("{}".utf8).write(to: registry)
                try expect(try ObsidianVaultDiscovery.defaultVault(registryURL: registry) == nil, "empty valid registry was not accepted")
            }
        },
        CodexBarTestCase(name: "Obsidian registry discovery rejects a symlink or non-regular registry") {
            try withObsidianRegistry { root, registry in
                let other = root.appendingPathComponent("Other.json")
                try Data("{}".utf8).write(to: other)
                try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: other)
                var rejected = false
                do { _ = try ObsidianVaultDiscovery.defaultVault(registryURL: registry) } catch { rejected = true }
                try expect(rejected, "registry symlink was followed")
                try FileManager.default.removeItem(at: registry)
                try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
                rejected = false
                do { _ = try ObsidianVaultDiscovery.defaultVault(registryURL: registry) } catch { rejected = true }
                try expect(rejected, "registry directory was read as configuration")
            }
        }
    ]
}

@MainActor
private func withObsidianRegistry(_ body: (URL, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexBarRegistry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let canonical = root.resolvingSymlinksInPath()
    try body(canonical, canonical.appendingPathComponent("obsidian.json"))
}

private func registeredVault(_ name: String, in root: URL) throws -> URL {
    let vault = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
    return vault
}

private func writeObsidianRegistry(_ vaults: [String: [String: Any]], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: ["vaults": vaults]).write(to: url)
}
