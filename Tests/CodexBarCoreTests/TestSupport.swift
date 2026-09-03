import Foundation

struct CodexBarTestCase {
    let name: String
    let body: @MainActor () async throws -> Void
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func expect(
    _ condition: Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard condition else {
        throw TestFailure(description: "\(file):\(line): \(message)")
    }
}

@MainActor
func require<T>(
    _ value: T?,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value else {
        throw TestFailure(description: "\(file):\(line): \(message)")
    }
    return value
}
