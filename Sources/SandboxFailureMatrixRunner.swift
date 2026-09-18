import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerMLX
import InferPeerProtocol
import InferPeerStorage

actor SandboxFailureMatrixRunner {
    func run() async -> [SandboxCheck] {
        var checks = [await modelLoadFailureCheck()]
        checks.append(schedulerRefusalCheck(name: "Low-memory refusal", mode: .lowMemory))
        checks.append(schedulerRefusalCheck(name: "Thermal refusal", mode: .thermal))
        checks.append(schedulerRefusalCheck(name: "No eligible worker", mode: .none))
        checks.append(await queueCapacityCheck())
        checks.append(await databaseQuotaCheck())
        checks.append(timeoutCheck())
        checks.append(cancelCompleteRaceCheck())
        return checks
    }

    private func modelLoadFailureCheck() async -> SandboxCheck {
        do {
            let backend = MLXInferenceBackend()
            do {
                try await backend.loadModel(missingModelArtifact())
                return failed("Model-load failure", "Missing model directory was accepted")
            } catch let error as InferenceBackendError {
                guard error == .modelLoadFailed(retryable: false) else {
                    return failed("Model-load failure", String(reflecting: error))
                }
                return passed("Model-load failure", "Rejected with modelLoadFailed")
            }
        } catch {
            return failed("Model-load failure", String(reflecting: error))
        }
    }

    private func schedulerRefusalCheck(
        name: String,
        mode: SchedulerRefusalMode
    ) -> SandboxCheck {
        do {
            let model = try modelReference()
            let candidates = try mode.candidates(model: model)
            let selected = DefaultSchedulerPolicy(configuration: .standard).selectWorker(
                for: try request(model: model, suffix: mode.rawValue),
                from: candidates,
                at: SchedulerRefusalMode.now
            )
            guard selected == nil else {
                return failed(name, "Ineligible worker was selected")
            }
            return passed(name, "Scheduler returned no eligible worker")
        } catch {
            return failed(name, String(reflecting: error))
        }
    }

    private func queueCapacityCheck() async -> SandboxCheck {
        do {
            let configuration = try storageConfiguration(
                maximumDatabaseBytes: 256 * 1_024 * 1_024,
                maximumPendingRequests: 1
            )
            return await storageRefusalCheck(
                name: "Full queue",
                configuration: configuration,
                seedRequest: true
            )
        } catch {
            return failed("Full queue", String(reflecting: error))
        }
    }

    private func databaseQuotaCheck() async -> SandboxCheck {
        do {
            let configuration = try storageConfiguration(
                maximumDatabaseBytes: 1,
                maximumPendingRequests: 100
            )
            return await storageRefusalCheck(
                name: "Full database quota",
                configuration: configuration,
                seedRequest: false
            )
        } catch {
            return failed("Full database quota", String(reflecting: error))
        }
    }

    private func storageRefusalCheck(
        name: String,
        configuration: SQLiteStorageConfiguration,
        seedRequest: Bool
    ) async -> SandboxCheck {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferpeer-failure-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let store = try SQLiteJobStore(
                databaseURL: directory.appendingPathComponent("failure.sqlite"),
                configuration: configuration
            )
            defer {
                try? store.close()
                try? FileManager.default.removeItem(at: directory)
            }
            if seedRequest {
                _ = try await store.accept(submission(index: 1))
            }
            do {
                _ = try await store.accept(submission(index: seedRequest ? 2 : 1))
                return failed(name, "Storage admitted data beyond its configured limit")
            } catch RequestPersistenceError.resourceExhausted {
                return passed(name, "Rejected with resourceExhausted")
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return failed(name, String(reflecting: error))
        }
    }

    private func timeoutCheck() -> SandboxCheck {
        var lifecycle = RequestLifecycle()
        let commit = lifecycle.expire()
        let error = InferPeerError(backendError: .deadlineExceeded)
        guard commit == .committed,
            lifecycle.state == .expired,
            error.code == .deadlineExceeded,
            !error.isRetryable
        else {
            return failed("Request timeout", "Deadline did not produce terminal expiry")
        }
        return passed("Request timeout", "Expired with deadlineExceeded")
    }

    private func cancelCompleteRaceCheck() -> SandboxCheck {
        do {
            let attemptID = try identifier(AttemptID.self, value: "attempt-failure-race")
            var cancellationWins = try runningLifecycle(attemptID: attemptID)
            var completionWins = try runningLifecycle(attemptID: attemptID)

            _ = cancellationWins.requestCancellation()
            let cancelled = try cancellationWins.confirmCancellation(attemptID: attemptID)
            let lateCompletion = try cancellationWins.complete(attemptID: attemptID)

            _ = completionWins.requestCancellation()
            let completed = try completionWins.complete(attemptID: attemptID)
            let lateCancellation = try completionWins.confirmCancellation(attemptID: attemptID)

            guard cancelled == .committed,
                lateCompletion == .alreadyTerminal(.cancelled),
                completed == .committed,
                lateCancellation == .alreadyTerminal(.completed)
            else {
                return failed("Cancel/complete race", "First terminal commit did not win")
            }
            return passed("Cancel/complete race", "First terminal commit won both orderings")
        } catch {
            return failed("Cancel/complete race", String(reflecting: error))
        }
    }

    private func runningLifecycle(attemptID: AttemptID) throws -> RequestLifecycle {
        var lifecycle = RequestLifecycle()
        _ = try lifecycle.assign(
            attemptID: attemptID,
            workerID: identifier(PeerID.self, value: "worker-failure-race"),
            coordinatorIncarnationID: identifier(
                CoordinatorIncarnationID.self,
                value: "coordinator-failure-race"
            ),
            leaseDeadline: MonotonicInstant(nanoseconds: 20)
        )
        try lifecycle.accept(attemptID: attemptID)
        return lifecycle
    }

    private func missingModelArtifact() throws -> LocalModelArtifact {
        let metadata = try ModelMetadata(
            quantization: "4-bit",
            tokenizer: "tokenizer.json",
            chatTemplate: "tokenizer_config.json",
            license: "Apache-2.0"
        )
        let descriptor = try ModelDescriptor(
            reference: modelReference(),
            runtimeFormat: .mlx,
            metadata: metadata,
            contextTokenLimit: 128,
            contentDigest: try ModelContentDigest(bytes: Data(repeating: 0xA5, count: 32))
        )
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferpeer-missing-\(UUID().uuidString)", isDirectory: true)
        return try LocalModelArtifact(descriptor: descriptor, directoryURL: missing)
    }

    private func storageConfiguration(
        maximumDatabaseBytes: UInt64,
        maximumPendingRequests: Int
    ) throws -> SQLiteStorageConfiguration {
        try SQLiteStorageConfiguration(
            maximumDatabaseBytes: maximumDatabaseBytes,
            maximumReplayPageSize: 10,
            maximumPendingRequests: maximumPendingRequests,
            maximumPendingRequestsPerCaller: maximumPendingRequests,
            busyTimeout: 1,
            maximumReaderCount: 1
        )
    }

    private func submission(index: Int) throws -> RequestSubmission {
        let callerID = try identifier(PeerID.self, value: "caller-failure")
        return RequestSubmission(
            requestID: try identifier(RequestID.self, value: "request-failure-\(index)"),
            callerID: callerID,
            request: try request(model: modelReference(), suffix: String(index)),
            contentDigest: try RequestContentDigest(
                bytes: Data(repeating: UInt8(index), count: 32)
            )
        )
    }

    private func request(model: ModelReference, suffix: String) throws -> TextGenerationRequest {
        let context = try ConversationContext(
            conversationID: identifier(
                ConversationID.self,
                value: "conversation-failure-\(suffix)"
            ),
            revision: 1,
            messages: [try TextMessage(role: .user, text: "Failure validation")]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(model),
            maximumOutputTokens: 8
        )
        return TextGenerationRequest(context: context, options: options)
    }

    private func modelReference() throws -> ModelReference {
        try ModelReference(
            modelID: identifier(ModelID.self, value: "failure-model"),
            revision: "revision-1"
        )
    }

    private func identifier<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        value: String
    ) throws -> ProtocolIdentifier<Domain> {
        guard let identifier = ProtocolIdentifier<Domain>(rawValue: value) else {
            throw SandboxClusterError.invalidInvitation
        }
        return identifier
    }

    private func passed(_ name: String, _ detail: String) -> SandboxCheck {
        SandboxCheck(name: name, passed: true, detail: detail)
    }

    private func failed(_ name: String, _ detail: String) -> SandboxCheck {
        SandboxCheck(name: name, passed: false, detail: detail)
    }
}

private enum SchedulerRefusalMode: String {
    case lowMemory = "low-memory"
    case thermal
    case none

    static let now = MonotonicInstant(nanoseconds: 20_000_000_000)

    func candidates(model: ModelReference) throws -> [SchedulingCandidate] {
        guard self != .none else { return [] }
        let condition = WorkerCondition(
            participation: .available,
            thermalState: self == .thermal ? .serious : .nominal,
            lowPowerModeEnabled: false
        )
        let load = WorkerLoad(
            activeGenerations: 0,
            generationCapacity: 1,
            availableAppMemoryBytes: self == .lowMemory ? 1_000 : 4_000
        )
        let worker = WorkerSnapshot(
            peerID: try requiredID(PeerID.self, value: "worker-\(rawValue)"),
            isAuthorized: true,
            lastHeartbeat: MonotonicInstant(nanoseconds: 19_000_000_000),
            condition: condition,
            load: load
        )
        return [
            try SchedulingCandidate(
                worker: worker,
                model: model,
                isModelLoaded: true,
                estimate: InferenceResourceEstimate(peakMemoryBytes: 2_000),
                timings: SchedulingTimings(queueDelay: .zero, inputTransferDuration: .zero)
            )
        ]
    }

    private func requiredID<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        value: String
    ) throws -> ProtocolIdentifier<Domain> {
        guard let identifier = ProtocolIdentifier<Domain>(rawValue: value) else {
            throw SandboxClusterError.invalidInvitation
        }
        return identifier
    }
}
