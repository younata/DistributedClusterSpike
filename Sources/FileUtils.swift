import Foundation

protocol FileReader: Sendable {
    func string(from url: URL) async throws -> String
}

struct DefaultFileReader: FileReader {
    func string(from url: URL) async throws -> String {
        try await Task {
            try String(contentsOf: url)
        }.value
    }
}

public func withTemporaryDirectory<Result: Sendable>(inside topLevelPath: Path, named: String, body: @Sendable @escaping (Path) async throws -> Result) async throws -> Result {
    let tempDirectoryPath = topLevelPath.appending(components: named)
    let directoryURL = tempDirectoryPath.url
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer {
        _ = try? FileManager.default.removeItem(at: directoryURL)
    }
    return try await body(tempDirectoryPath)
}
