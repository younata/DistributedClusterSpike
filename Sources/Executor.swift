import Foundation

protocol Executor: Sendable {
    func execute(task: Job) async throws -> TaskOutput
}

struct FolderizationExecutor: Executor {
    let workDirectory: Path
    let processRunner: ProcessRunner

    func execute(task: Job) async throws -> TaskOutput {
        let taskId = UUID().uuidString

        let taskResult = try await withTemporaryDirectory(inside: workDirectory, named: taskId) { (workingDirectory: Path) in
            let command = Path(components: ["bin", "bash"], isAbsolute: true)
            return try await processRunner.run(
                command: command,
                arguments: ["-c", task.script],
                workingDirectory: workingDirectory
            )
        }

        return TaskOutput(
            exitCode: taskResult.exitCode,
            standardOut: taskResult.standardOut,
            standardError: taskResult.standardErr,
            output: [:]
        )
    }
}

