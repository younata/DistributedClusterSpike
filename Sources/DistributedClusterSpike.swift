import Foundation
import ArgumentParser
import DistributedCluster

@main
struct DistributedClusterSpike: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "A spike for learning how to work with distributed actors and how to test them",
        subcommands: [ManagerCommand.self, WorkerCommand.self]
    )
}

struct ClusterArguments: ParsableArguments {
    @Option(name: .shortAndLong)
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong)
    var port: Int = 9001
}

func poolClusterSystem(host: String, port: Int) async -> ClusterSystem {
    var settings = ClusterSystemSettings(endpoint: Cluster.Endpoint(host: host, port: port))
    settings.logging.logLevel = .info
    return await ClusterSystem("ClusterSpike", settings: settings)
}

func workerClusterSystem() async -> ClusterSystem {
    await ClusterSystem("WorkerCluster") {
        $0.logging.logLevel = .info
    }
}

struct ManagerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(commandName: "manager")

    @OptionGroup var clusterArgs: ClusterArguments

    func run() async throws {
        let clusterSystem = await poolClusterSystem(host: clusterArgs.host, port: clusterArgs.port)
        let pool = await WorkerPool(transport: clusterSystem)

        try await clusterSystem.cluster.joined(within: .seconds(10))
        let task = createWork(pool)

        clusterSystem.log.info("Now to run the cluster indefinitely")

        try await clusterSystem.terminated

        task.cancel()
    }
}

struct WorkerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(commandName: "worker")

    @OptionGroup var clusterArgs: ClusterArguments

    var worker: Worker? = nil

    mutating func run() async throws {
        let clusterSystem = await ClusterSystem("WorkerCluster") {
            $0.logging.logLevel = .info
        }

        let targetEndpoint = Cluster.Endpoint(host: clusterArgs.host, port: clusterArgs.port)
        clusterSystem.cluster.join(endpoint: targetEndpoint)
        try await clusterSystem.cluster.joined(endpoint: targetEndpoint, within: .seconds(10))
        clusterSystem.log.info("Should be joined now...")
        self.worker = await Worker(
            actorSystem: clusterSystem,
            executor: FolderizationExecutor(
                workDirectory: Path(pathString: NSTemporaryDirectory()),
                processRunner: FoundationProcessRunner()
            )
        )

        try await clusterSystem.terminated
    }
}
