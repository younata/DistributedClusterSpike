import Distributed
import Foundation
import DistributedCluster

typealias DefaultDistributedActorSystem = ClusterSystem

distributed actor WorkerPool: LifecycleWatch {
    private var workers: Set<Worker> = []

    var listingTask: Task<Void, Never>?

    init(transport: ActorSystem) async {
        self.actorSystem = transport

        listingTask = Task<Void, Never> {
            for await worker in await transport.receptionist.listing(of: Worker.self) {
                self.workers.insert(worker)
                self.actorSystem.log.info("Worker with id \(worker.id) became available. Now tracking \(self.workers)")

                self.watchTermination(of: worker)
            }
        }
    }

    deinit {
        listingTask?.cancel()
    }

    distributed func submit(work item: Job) async throws -> TaskOutput {
        guard let worker = workers.shuffled().first else {
            actorSystem.log.error("No workers to submit job to. Workers: \(workers)")
            throw WorkerError.noWorkersAvailable
        }
        let submitDate = Date()
        defer {
            let receiveDate = Date()
            actorSystem.log.info("Job \(item) took \(receiveDate.timeIntervalSince(submitDate)) seconds to hear back.")
        }
        return try await worker.work(on: item)
    }

    distributed func shutdown() async throws {
        for worker in workers {
            do {
                try await worker.exit()
            } catch {
                actorSystem.log.error("Error asking worker to exit: \(error)")
            }
        }
        try actorSystem.shutdown()
    }

    func terminated(actor id: ActorID) async {
        actorSystem.log.info("Removing terminated actor \(id)")
        guard let member = workers.first(where: { $0.id == id }) else { return }
        workers.remove(member)
    }
}

enum WorkerError: Error {
    case noWorkersAvailable // no workers available for the given platform
}

distributed actor Worker {
    private let executor: Executor

    @ActorID.Metadata(\.receptionID)
    var receptionID: String

    init(actorSystem: ActorSystem, executor: Executor) async {
        self.actorSystem = actorSystem
        self.executor = executor
        self.receptionID = "*" // any/"All of this type", see  https://github.com/apple/swift-distributed-actors/issues/1084
        await actorSystem.receptionist.checkIn(self)
    }

    deinit {
        actorSystem.log.info("Terminating worker")
    }

    distributed func exit() throws {
        try actorSystem.shutdown()
    }

    distributed func work(on item: Job) async throws -> TaskOutput {
        let startDate = Date()
        actorSystem.log.info("Executing job \(item)")
        defer {
            let endDate = Date()
            actorSystem.log.info("Finished executing job \(item). Took \(endDate.timeIntervalSince(startDate)) seconds.")
        }
        return try await executor.execute(task: item)
    }
}

