import CryptoKit
import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerProtocol
import InferPeerSecurity
import InferPeerStorage
import InferPeerTelemetry

struct SandboxCheck: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let passed: Bool
    let detail: String
}

actor SandboxValidationRunner {
    private let statusProvider: SystemStatusProvider?
    private let failureMatrix = SandboxFailureMatrixRunner()

    init() {
        statusProvider = try? SystemStatusProvider(participation: .available)
    }

    func setParticipation(_ participation: WorkerParticipationState) async {
        await statusProvider?.setParticipation(participation)
    }

    func run() async -> [SandboxCheck] {
        var checks: [SandboxCheck] = []
        checks.append(await identityCheck())
        checks.append(await storageCheck())
        checks.append(await statusCheck())
        checks.append(await inferenceCheck())
        let failureChecks = await failureMatrix.run()
        checks.append(contentsOf: failureChecks)
        try? SandboxEvidenceStore.writeChecks(checks)
        try? SandboxEvidenceStore.writeFailures(failureChecks)
        return checks
    }

    private func identityCheck() async -> SandboxCheck {
        do {
            let store = try KeychainSecretStore(service: "in.kodlabs.inferpeer.sandbox")
            let manager = DeviceIdentityManager(secretStore: store)
            let credentials = try await manager.credentials()
            return passed("Identity and Keychain", credentials.identity.peerID.rawValue)
        } catch {
            return failed("Identity and Keychain", error)
        }
    }

    private func storageCheck() async -> SandboxCheck {
        do {
            let directory = try SandboxEvidenceStore.directory()
            let store = try SQLiteOutboxStore(
                databaseURL: directory.appendingPathComponent("smoke.sqlite"))
            let submission = try makeSubmission()
            _ = try await store.enqueue(submission)
            let pending = try await store.pending(callerID: submission.callerID, limit: 10)
            try await store.remove(requestID: submission.requestID, callerID: submission.callerID)
            try store.close()
            return passed("Protected durable storage", "Recovered \(pending.count) queued request")
        } catch {
            return failed("Protected durable storage", error)
        }
    }

    private func statusCheck() async -> SandboxCheck {
        guard let statusProvider else {
            return SandboxCheck(
                name: "Platform status", passed: false, detail: "Provider unavailable")
        }
        let status = await statusProvider.currentStatus()
        return passed(
            "Platform status", "Participation: \(status.condition.participation.rawValue)")
    }

    private func inferenceCheck() async -> SandboxCheck {
        do {
            let artifact = try makeArtifact(directoryURL: SandboxEvidenceStore.directory())
            let request = try makeRequest(reference: artifact.descriptor.reference)
            let backend = SandboxInferenceBackend()
            await backend.loadModel(artifact)
            let execution = InferenceExecution(
                requestID: identifier(RequestID.self, prefix: "request"),
                attemptID: identifier(AttemptID.self, prefix: "attempt"),
                model: artifact.descriptor.reference,
                request: request
            )
            let events = try await backend.generate(execution)
            var eventCount = 0
            for try await _ in events { eventCount += 1 }
            return passed("Bounded inference stream", "Consumed \(eventCount) ordered events")
        } catch {
            return failed("Bounded inference stream", error)
        }
    }

    private func makeSubmission() throws -> RequestSubmission {
        let callerID = identifier(PeerID.self, prefix: "caller")
        let request = try makeRequest(reference: makeReference())
        let digest = Data(SHA256.hash(data: Data("sandbox-smoke-v1".utf8)))
        return RequestSubmission(
            requestID: identifier(RequestID.self, prefix: "request"),
            callerID: callerID,
            request: request,
            contentDigest: try RequestContentDigest(bytes: digest)
        )
    }

    private func makeRequest(reference: ModelReference) throws -> TextGenerationRequest {
        let context = try ConversationContext(
            conversationID: identifier(ConversationID.self, prefix: "conversation"),
            revision: 1,
            messages: [try TextMessage(role: .user, text: "InferPeer physical-device smoke test")]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(reference),
            maximumOutputTokens: 16
        )
        return TextGenerationRequest(context: context, options: options)
    }

    private func makeArtifact(directoryURL: URL) throws -> LocalModelArtifact {
        let descriptor = try ModelDescriptor(
            reference: makeReference(),
            runtimeFormat: .mlx,
            metadata: try ModelMetadata(
                quantization: "test-double",
                tokenizer: "test-double",
                chatTemplate: "test-double",
                license: "validation-only"
            ),
            contextTokenLimit: 128,
            contentDigest: try ModelContentDigest(
                bytes: Data(SHA256.hash(data: Data("sandbox-model-v1".utf8)))
            )
        )
        return try LocalModelArtifact(descriptor: descriptor, directoryURL: directoryURL)
    }

    private func makeReference() throws -> ModelReference {
        try ModelReference(
            modelID: identifier(ModelID.self, prefix: "sandbox-model"),
            revision: "validation-1"
        )
    }

    private func identifier<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        prefix: String
    ) -> ProtocolIdentifier<Domain> {
        guard
            let value = ProtocolIdentifier<Domain>(
                rawValue: "\(prefix)-\(UUID().uuidString.lowercased())")
        else {
            preconditionFailure("A UUID-backed protocol identifier must be valid")
        }
        return value
    }

    private func passed(_ name: String, _ detail: String) -> SandboxCheck {
        SandboxCheck(name: name, passed: true, detail: detail)
    }

    private func failed(_ name: String, _ error: any Error) -> SandboxCheck {
        SandboxCheck(name: name, passed: false, detail: String(describing: error))
    }
}

private actor SandboxInferenceBackend: InferenceBackend {
    private var loadedReference: ModelReference?

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate(peakMemoryBytes: 1)
    }

    func loadModel(_ model: LocalModelArtifact) {
        loadedReference = model.descriptor.reference
    }

    func unloadModel(_ reference: ModelReference) throws {
        guard loadedReference == reference else {
            throw InferenceBackendError.modelUnavailable(reference)
        }
        loadedReference = nil
    }

    func generate(_ execution: InferenceExecution) throws -> GenerationEventStream {
        guard loadedReference == execution.model else {
            throw InferenceBackendError.modelUnavailable(execution.model)
        }
        let delta = try TextDelta("InferPeer is running locally.")
        let result = GenerationResult(
            fullText: delta.text,
            modelUsed: execution.model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 4, outputTokens: 5)
        )
        return GenerationEventStream { continuation in
            continuation.yield(.textDelta(delta))
            continuation.yield(.completed(result))
            continuation.finish()
        }
    }

    func cancel(attemptID: AttemptID) {}
}
