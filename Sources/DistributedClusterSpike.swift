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
    await ClusterSystem("ClusterSpike") {
        $0.endpoint = Cluster.Endpoint(host: host, port: port)
        $0.logging.logLevel = .info
        $0.onDownAction = .gracefulShutdown(delay: .seconds(10))
        $0.nid = .init(1337)
    }
}

func workerClusterSystem() async -> ClusterSystem {
    await ClusterSystem("WorkerCluster") {
        $0.logging.logLevel = .info
        $0.downingStrategy = .timeout(.default)
        $0.onDownAction = .gracefulShutdown(delay: .seconds(10))
    }
}

struct ManagerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(commandName: "manager")

    @OptionGroup var clusterArgs: ClusterArguments

    func run() async throws {
        let clusterSystem = await poolClusterSystem(host: clusterArgs.host, port: clusterArgs.port)
        let pool = await WorkerPool(transport: clusterSystem)

        // NOTE: this is not necessary, and all it'll do if you DO call it is
        // cause the `manager` command to terminate early if the cluster is unable to join.
//        try await clusterSystem.cluster.joined(within: .seconds(10))
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
        let clusterSystem = await workerClusterSystem()

        let targetEndpoint = Cluster.Endpoint(host: clusterArgs.host, port: clusterArgs.port)
        let targetNode = Cluster.Node(endpoint: targetEndpoint, nid: .init(1337))
        clusterSystem.cluster.join(node: targetNode)

        // NOTE: This is only necessary if you wish to block further execution until after this has joined the workpool. However, due to the timeout, this will exit early if the workpool has not been spun up before the timeout period. IMO, calling `joined(endoint:)` is unnecessary for a workpool-type setup.
//        try await clusterSystem.cluster.joined(endpoint: targetEndpoint, within: .seconds(10))
//        clusterSystem.log.info("Should be joined now...")
        self.worker = await Worker(
            actorSystem: clusterSystem,
            executor: FolderizationExecutor(
                workDirectory: Path(pathString: NSTemporaryDirectory()),
                processRunner: FoundationProcessRunner()
            )
        )

        let task = listenForPoolEvents(clusterSystem: clusterSystem, poolEndpoint: targetEndpoint)
        defer {
            task.cancel()
        }

        try await clusterSystem.terminated
    }

    private func listenForPoolEvents(clusterSystem: ClusterSystem, poolEndpoint: Cluster.Endpoint) -> Task<Void, Never> {
        Task<Void, Never> {
            for await event in clusterSystem.cluster.events {
                switch event {
                case .reachabilityChange(let change):
                    guard change.member.node.endpoint == poolEndpoint else { break }
                    if change.toReachable {
                        clusterSystem.log.notice("Pool Cluster System is now available to receive jobs from.")
                    } else if change.toUnreachable {
//                        clusterSystem.cluster.down(endpoint: poolEndpoint)
//                        clusterSystem.cluster.join(endpoint: poolEndpoint)
                        clusterSystem.log.notice("Pool Cluster System is no longer reachable.")// Will attempt to re-join once it becomes available.")
                    }
                case .membershipChange(let change):
                    guard change.member.node.endpoint == poolEndpoint else {
                        break
                    }
                    if change.isUp {
                        clusterSystem.log.notice("Pool Cluster System is now up")
                    } else if change.isDown {
                        clusterSystem.log.notice("Pool Cluster System is now down")
//                        clusterSystem.cluster.join(endpoint: poolEndpoint)
                    } else if change.isJoining {
                        clusterSystem.log.notice("Pool Cluster System is now joining")
                    } else if change.isLeaving {
                        clusterSystem.log.notice("Pool Cluster Systme is now leaving")
                    } else if change.isRemoval {
                        clusterSystem.log.notice("Pool Cluster System is now removed")
                    } else if change.isReplacement {
                        clusterSystem.log.notice("Pool Cluster System is now replaced: \(change.node)")
                    }
                default: break
                }
            }
        }
    }
}
