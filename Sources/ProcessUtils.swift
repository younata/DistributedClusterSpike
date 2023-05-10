import Foundation

public protocol ProcessRunner: Sendable {
    func run(command: Path, arguments: [String], workingDirectory: Path?) async throws -> (exitCode: Int, standardOut: Data, standardErr: Data)
}

public extension ProcessRunner {
    func run(command: Path, arguments: [String]) async throws -> (exitCode: Int, standardOut: Data, standardErr: Data) {
        try await run(command: command, arguments: arguments, workingDirectory: nil)
    }
}

public actor FoundationProcessRunner: ProcessRunner {
    private struct TrackedProcess: Hashable {
        let stdout: Pipe
        let stderr: Pipe
        let process: Process

        func terminate() {
            process.terminate()
        }
    }

    private var processes = Set<TrackedProcess>()

    public init() {}

    deinit {
        processes.forEach { $0.terminate() }
    }

    public func run(command: Path, arguments: [String], workingDirectory: Path?) async throws -> (exitCode: Int, standardOut: Data, standardErr: Data) {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = command.url
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.currentDirectoryURL = workingDirectory?.url
        process.environment?["OS_ACTIVITY_DT_MODE"] = nil

        let trackedProcess = TrackedProcess(stdout: stdout, stderr: stderr, process: process)
        self.processes.insert(trackedProcess)

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                do {
                    let standardOutData = try stdout.fileHandleForReading.readToEnd() ?? Data()
                    let standardErrorData = try stderr.fileHandleForReading.readToEnd() ?? Data()

                    continuation.resume(returning: (Int(finishedProcess.terminationStatus), standardOutData, standardErrorData))
                } catch {
                    continuation.resume(throwing: error)
                }

                self.processEnded(trackedProcess)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated private func processEnded(_ process: TrackedProcess) {
        Task {
            await self.processDidEnd(process)
        }
    }

    private func processDidEnd(_ process: TrackedProcess) {
        if process.process.isRunning == false {
            process.terminate()
        }
        processes.remove(process)
    }
}
