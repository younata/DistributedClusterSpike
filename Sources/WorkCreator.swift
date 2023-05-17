import Darwin

func createWork(_ pool: WorkerPool) -> Task<Void, Never> {
    Task {
        await listenForWork(pool)
    }
}

private func listenForWork(_ pool: WorkerPool) async {
    while !Task.isCancelled {
        guard let line = readLine(strippingNewline: true) else { continue }
        if line.lowercased() == "exit" {
            pool.actorSystem.log.info("Shutting down")
            do {
                try await pool.shutdown()
            } catch {
                pool.actorSystem.log.error("Unable to shutdown: \(error)")
            }
        }

        do {
            let result = try await pool.submit(work: Job(script: line))
            print("Exit code      : \(result.exitCode)")
            print("Standard Output: " + (String(data: result.standardOut, encoding: .utf8) ?? ""))
            fputs("Standard Error : " + (String(data: result.standardError, encoding: .utf8) ?? "") + "\n", stderr)
        } catch {
            fputs(error.localizedDescription + "\n", stderr)
        }
    }
}
