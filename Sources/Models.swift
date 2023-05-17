import Foundation

struct Job: Codable, Equatable, Sendable, CustomStringConvertible {
    let id: UUID
    let script: String

    init(script: String) {
        self.id = UUID()
        self.script = script
    }

    var description: String {
        "\(id.uuidString): \"\"\"\(script)\"\"\""
    }
}

public struct TaskOutput: Codable, Equatable, Sendable {
    public let exitCode: Int
    public let standardOut: Data
    public let standardError: Data
    public let output: [String: Data]

    public init(exitCode: Int, standardOut: Data, standardError: Data, output: [String : Data]) {
        self.exitCode = exitCode
        self.standardOut = standardOut
        self.standardError = standardError
        self.output = output
    }
}
