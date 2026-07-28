import Foundation

actor CodexAppServerClient: RateLimitProviding {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, any Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct InitializeResponse: Decodable, Sendable {}

    private let executableURL: URL
    private let requestTimeoutNanoseconds: UInt64
    private let eventStream: AsyncStream<CodexAppServerEvent>
    private let eventContinuation: AsyncStream<CodexAppServerEvent>.Continuation

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var outputFramer = JSONLineFramer()
    private var pendingRequests: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var generation = 0
    private var intentionallyStopping = false

    init(
        executableURL: URL,
        requestTimeout: TimeInterval = 10
    ) {
        self.executableURL = executableURL
        requestTimeoutNanoseconds = UInt64(requestTimeout * 1_000_000_000)

        let stream = AsyncStream.makeStream(of: CodexAppServerEvent.self)
        eventStream = stream.stream
        eventContinuation = stream.continuation
    }

    func start() async throws {
        if process?.isRunning == true {
            return
        }

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexAppServerError.executableNotRunnable(executableURL.path)
        }

        intentionallyStopping = false
        generation += 1
        let currentGeneration = generation

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] terminatedProcess in
            let exitCode = terminatedProcess.terminationStatus
            Task {
                await self?.processExited(
                    generation: currentGeneration,
                    exitCode: exitCode
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed
        }

        self.process = process
        inputHandle = inputPipe.fileHandleForWriting
        startReading(
            outputHandle: outputPipe.fileHandleForReading,
            errorHandle: errorPipe.fileHandleForReading,
            generation: currentGeneration
        )

        let _: InitializeResponse = try await request(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_usage_status",
                    "title": "Codex Usage Status",
                    "version": Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "0.1.0",
                ],
            ]
        )

        try sendNotification(method: "initialized", params: [:])
    }

    func readAccount() async throws -> AccountReadResponse {
        try await request(
            method: "account/read",
            params: ["refreshToken": false]
        )
    }

    func readRateLimits() async throws -> GetAccountRateLimitsResponse {
        try await request(
            method: "account/rateLimits/read",
            params: nil
        )
    }

    func events() -> AsyncStream<CodexAppServerEvent> {
        eventStream
    }

    func stop() async {
        intentionallyStopping = true
        generation += 1

        inputHandle?.closeFile()
        inputHandle = nil
        closeReadHandles()

        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        self.process = nil

        failPendingRequests(with: CancellationError())
        eventContinuation.finish()
    }

    private func startReading(
        outputHandle: FileHandle,
        errorHandle: FileHandle,
        generation: Int
    ) {
        self.outputHandle = outputHandle
        self.errorHandle = errorHandle
        outputFramer = JSONLineFramer()

        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            Task {
                await self?.handleOutputChunk(
                    data,
                    generation: generation
                )
            }
        }

        // App Server stderr may contain diagnostics. Drain it to prevent the
        // child process from blocking, but do not retain or log its contents.
        errorHandle.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    private func handleOutputChunk(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }

        if data.isEmpty {
            outputHandle?.readabilityHandler = nil
            return
        }

        do {
            for line in try outputFramer.append(data) {
                handleLine(line, generation: generation)
            }
        } catch {
            readerFailed(generation: generation)
        }
    }

    private func request<Result: Decodable & Sendable>(
        method: String,
        params: [String: Any]?
    ) async throws -> Result {
        guard process?.isRunning == true else {
            throw CodexAppServerError.disconnected(process?.terminationStatus)
        }

        let requestID = nextRequestID
        nextRequestID += 1

        var message: [String: Any] = [
            "id": requestID,
            "method": method,
        ]
        message["params"] = params ?? NSNull()

        let responseData = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, any Error>) in
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(
                        nanoseconds: self?.requestTimeoutNanoseconds
                            ?? 10_000_000_000
                    )
                } catch {
                    return
                }
                await self?.timeoutRequest(id: requestID, method: method)
            }

            pendingRequests[requestID] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            do {
                try send(message)
            } catch {
                pendingRequests.removeValue(forKey: requestID)
                timeoutTask.cancel()
                continuation.resume(throwing: CodexAppServerError.disconnected(nil))
            }
        }

        do {
            return try JSONDecoder().decode(Result.self, from: responseData)
        } catch {
            throw CodexAppServerError.invalidResponse
        }
    }

    private func sendNotification(
        method: String,
        params: [String: Any]
    ) throws {
        try send([
            "method": method,
            "params": params,
        ])
    }

    private func send(_ message: [String: Any]) throws {
        guard let inputHandle else {
            throw CodexAppServerError.disconnected(nil)
        }

        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try inputHandle.write(contentsOf: data)
    }

    private func handleLine(_ data: Data, generation: Int) {
        guard generation == self.generation,
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any]
        else {
            return
        }

        if let id = message["id"] as? Int {
            handleResponse(message, id: id)
            return
        }

        guard message["method"] as? String == "account/rateLimits/updated",
              let params = message["params"],
              JSONSerialization.isValidJSONObject(params),
              let paramsData = try? JSONSerialization.data(withJSONObject: params),
              let update = try? JSONDecoder().decode(
                  AccountRateLimitsUpdatedNotification.self,
                  from: paramsData
              )
        else {
            return
        }

        eventContinuation.yield(.rateLimitsUpdated(update))
    }

    private func handleResponse(_ message: [String: Any], id: Int) {
        guard let pendingRequest = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pendingRequest.timeoutTask.cancel()

        if let error = message["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? ""
            pendingRequest.continuation.resume(
                throwing: CodexAppServerError.server(code: code, message: message)
            )
            return
        }

        guard let result = message["result"],
              JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result)
        else {
            pendingRequest.continuation.resume(
                throwing: CodexAppServerError.invalidResponse
            )
            return
        }

        pendingRequest.continuation.resume(returning: data)
    }

    private func timeoutRequest(id: Int, method: String) {
        guard let pendingRequest = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pendingRequest.continuation.resume(
            throwing: CodexAppServerError.requestTimedOut(method)
        )
    }

    private func readerFailed(generation: Int) {
        guard generation == self.generation, !intentionallyStopping else {
            return
        }
        if process?.isRunning == true {
            process?.terminationHandler = nil
            process?.terminate()
        }
        processExited(generation: generation, exitCode: nil)
    }

    private func processExited(generation: Int, exitCode: Int32?) {
        guard generation == self.generation, !intentionallyStopping else {
            return
        }

        closeReadHandles()
        inputHandle = nil
        process = nil

        failPendingRequests(with: CodexAppServerError.disconnected(exitCode))
        eventContinuation.yield(.disconnected(exitCode: exitCode))
        eventContinuation.finish()
    }

    private func closeReadHandles() {
        outputHandle?.readabilityHandler = nil
        outputHandle?.closeFile()
        outputHandle = nil

        errorHandle?.readabilityHandler = nil
        errorHandle?.closeFile()
        errorHandle = nil
    }

    private func failPendingRequests(with error: any Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()

        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
