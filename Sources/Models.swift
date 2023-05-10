import Foundation

struct Job: Codable, Equatable, Sendable {
    let script: String
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
