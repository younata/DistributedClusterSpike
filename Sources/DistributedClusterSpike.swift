import NIOSSL
import Foundation
import ArgumentParser
import DistributedCluster

@main
struct DistributedClusterSpike: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "A spike for learning how to work with distributed actors and how to test them",
        subcommands: [GenerateCertificates.self, ManagerCommand.self, WorkerCommand.self]
    )
}

struct ClusterArguments: ParsableArguments {
    @Option(name: .shortAndLong)
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong)
    var port: Int = 9001

    @Option(name: .customLong("security-pool-certificate"), transform: { Path(pathString: $0) })
    var poolCertificate: Path
}

func poolClusterSystem(host: String, port: Int, poolCertificate: Path, poolKey: Path, workerCertificates: [Path]) async throws -> ClusterSystem {
    var tlsConfiguration = TLSConfiguration.makeServerConfiguration(
        certificateChain: try NIOSSLCertificate.fromPEMFile(poolCertificate.pathString).map { .certificate($0) },
        privateKey: .file(poolKey.pathString)
    )
    tlsConfiguration.certificateVerification = .noHostnameVerification
    tlsConfiguration.trustRoots = .certificates(try workerCertificates.map {
        try NIOSSLCertificate(file: $0.pathString, format: .pem)
    })

    return await ClusterSystem("ClusterSpike") {
        $0.endpoint = Cluster.Endpoint(host: host, port: port)
        $0.logging.logLevel = .info
        $0.onDownAction = .gracefulShutdown(delay: .seconds(10))
        $0.nid = .init(1337)

        $0.tls = tlsConfiguration
    }
}

func workerClusterSystem(workerCertificate: Path, workerKey: Path, poolCertificate: Path) async throws -> ClusterSystem {
    var tlsConfiguration = TLSConfiguration.makeServerConfiguration(
        certificateChain: try NIOSSLCertificate.fromPEMFile(workerCertificate.pathString).map { .certificate($0) },
        privateKey: .file(workerKey.pathString)
    )
    tlsConfiguration.certificateVerification = .noHostnameVerification
    tlsConfiguration.trustRoots = .certificates([try NIOSSLCertificate(file: poolCertificate.pathString, format: .pem)])

    return await ClusterSystem("WorkerCluster") {
        $0.logging.logLevel = .info
        $0.downingStrategy = .timeout(.default)
        $0.onDownAction = .gracefulShutdown(delay: .seconds(10))

        $0.tls = tlsConfiguration
    }
}

// shells out to generate the TLS configurations.
struct GenerateCertificates: AsyncParsableCommand {
    static var configuration = CommandConfiguration(commandName: "generate-tls-certificates")

    @Option(name: .customLong("number-of-workers"))
    var numberOfWorkers: Int = 1

    @Option(name: .long)
    var hostname: String

    func run() async throws {
        let processRunner = FoundationProcessRunner()

        let bash = Path(components: ["bin", "bash"], isAbsolute: true)

        let keyNames = ["host"] + (0..<numberOfWorkers).map { "worker-\($0)" }
        for keyName in keyNames {
            print("Creating key \(keyName)")
            let cmd = """
            openssl req -x509 -newkey rsa:4096 -keyout \(keyName)-key.pem -out \(keyName)-cert.pem -sha256 -days 3650 -nodes -subj "/C=XX/ST=StateName/L=CityName/O=CompanyName/OU=CompanySectionName/CN=\(hostname)"
            """

            _ = try await processRunner.run(
                command: bash,
                arguments: ["-c", cmd],
                workingDirectory: Path(pathString: "")
            )
        }
    }
}

struct ManagerCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(commandName: "manager")

    @OptionGroup var clusterArgs: ClusterArguments

    @Option(name: .customLong("security-pool-key"), transform: { Path(pathString: $0) })
    var poolKey: Path

    @Option(name: .customLong("security-worker-certificates"), transform: { Path(pathString: $0) })
    var workerCertificates: [Path]

    func run() async throws {
        let clusterSystem = try await poolClusterSystem(host: clusterArgs.host, port: clusterArgs.port, poolCertificate: clusterArgs.poolCertificate, poolKey: poolKey, workerCertificates: workerCertificates)
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

    @Option(name: .customLong("security-worker-certificate"), transform: { Path(pathString: $0) })
    var workerCertificate: Path

    @Option(name: .customLong("security-worker-key"), transform: { Path(pathString: $0) })
    var workerKey: Path

    mutating func run() async throws {
        let clusterSystem = try await workerClusterSystem(workerCertificate: workerCertificate, workerKey: workerKey, poolCertificate: clusterArgs.poolCertificate)

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
