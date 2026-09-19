import CryptoKit
import Foundation
import InferPeer
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
        checks.append(await multimodalInferenceCheck())
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
            let backend = SandboxInferenceBackend()
            let facade = try InferPeer(
                configuration: InferPeerConfiguration(
                    localResource: LocalResourceConfiguration(
                        displayName: "InferPeer Sandbox validation",
                        platform: validationPlatform()
                    ),
                    localRuntime: backend,
                    localModels: [artifact],
                    defaultTextModel: artifact.descriptor.reference
                )
            )
            let handle = try await facade.run(
                .text(
                    model: .exact(artifact.descriptor.reference),
                    messages: [.user("InferPeer physical-device smoke test")],
                    generation: .init(maxOutputTokens: 16)
                ),
                resourceId: .local
            )
            _ = try await handle.result()
            var eventCount = 0
            for try await _ in handle.events { eventCount += 1 }
            await facade.stop()
            return passed(
                "Direct local resource",
                "Facade consumed \(eventCount) ordered events without networking"
            )
        } catch {
            return failed("Direct local resource", error)
        }
    }

    private func multimodalInferenceCheck() async -> SandboxCheck {
        do {
            let artifact = try makeArtifact(directoryURL: SandboxEvidenceStore.directory())
            let facade = try makeMultimodalFacade(artifact: artifact)
            for query in multimodalQueries() {
                let handle = try await facade.run(query, resourceId: .local)
                _ = try await handle.result()
                for try await _ in handle.events {}
            }
            await facade.stop()
            return passed(
                "Direct multimodal contracts",
                "Vision, transcription, and speech completed through the v2 runtime"
            )
        } catch {
            return failed("Direct multimodal contracts", error)
        }
    }

    private func makeMultimodalFacade(artifact: LocalModelArtifact) throws -> InferPeer {
        let model = artifact.descriptor.reference
        return try InferPeer(
            configuration: InferPeerConfiguration(
                localResource: LocalResourceConfiguration(
                    displayName: "InferPeer Sandbox multimodal validation",
                    platform: validationPlatform()
                ),
                directRuntime: SandboxDirectRuntime(),
                localModels: [artifact],
                localModelTasks: [model: Set(InferenceTask.allCases)],
                defaultModels: Dictionary(
                    uniqueKeysWithValues: InferenceTask.allCases.map { ($0, model) }
                )
            )
        )
    }

    private func multimodalQueries() -> [InferenceQuery] {
        [
                .vision(
                    model: .taskDefault,
                    messages: [.user("Describe this image")],
                    images: [.receipt(.init(rawValue: "sandbox-image"))]
                ),
                .transcribe(
                    model: .taskDefault,
                    audio: .receipt(.init(rawValue: "sandbox-audio")),
                    language: "en"
                ),
                .synthesizeSpeech(
                    model: .taskDefault,
                    voiceID: "sandbox-voice",
                    text: "InferPeer Sandbox"
                ),
        ]
    }

    private func validationPlatform() -> PlatformDescriptor {
        #if os(iOS)
            let operatingSystem = PlatformDescriptor.OperatingSystem.iOS
        #else
            let operatingSystem = PlatformDescriptor.OperatingSystem.macOS
        #endif
        return PlatformDescriptor(
            operatingSystem: operatingSystem,
            operatingSystemVersion: Self.operatingSystemVersion
        )
    }

    static var operatingSystemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
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

private actor SandboxDirectRuntime: DirectInferenceRuntime {
    func estimateResources(
        for query: InferenceQuery,
        using model: ModelDescriptor
    ) throws -> InferenceResourceEstimate {
        try InferenceResourceEstimate(peakMemoryBytes: 1)
    }

    func loadModel(_ model: LocalModelArtifact) {}

    func unloadModel(_ reference: ModelKey) {}

    func execute(_ execution: DirectRuntimeExecution) throws -> DirectRuntimeEventStream {
        let pair = DirectRuntimeEventStream.makeStream()
        switch execution.query {
        case .text:
            pair.continuation.yield(.textDelta("InferPeer Sandbox direct runtime"))
        case .vision:
            pair.continuation.yield(.preprocessing(.decodingMedia))
            pair.continuation.yield(.textDelta("InferPeer Sandbox direct runtime"))
        case .audioTranscription:
            pair.continuation.yield(.transcriptSegment(transcriptSegment()))
        case .speechSynthesis:
            pair.continuation.yield(
                .audioChunk(
                    AudioChunk(
                        format: .signedInt16,
                        sampleRate: 24_000,
                        channelCount: 1,
                        frameOffset: 0,
                        samples: Data([0, 1, 2, 3])
                    )
                )
            )
        }
        pair.continuation.yield(.completed(result(for: execution)))
        pair.continuation.finish()
        return pair.stream
    }

    func cancel(attemptID: AttemptID) {}

    private func result(for execution: DirectRuntimeExecution) -> RunResult {
        let content: RunResultContent
        switch execution.query {
        case .text, .vision:
            content = .text("InferPeer Sandbox direct runtime")
        case .audioTranscription:
            content = .transcription(
                segments: [transcriptSegment()],
                language: "en",
                mode: .transcription
            )
        case .speechSynthesis:
            content = .speech(
                asset: .init(rawValue: "sandbox-speech"),
                format: .signedInt16,
                sampleRate: 24_000,
                channelCount: 1,
                frameCount: 2
            )
        }
        return RunResult(
            content: content,
            model: execution.model,
            finishReason: .stop,
            usage: TokenUsage(promptTokens: 1, outputTokens: 1)
        )
    }

    private func transcriptSegment() -> TranscriptSegment {
        TranscriptSegment(
            id: "sandbox-segment",
            revision: 1,
            start: .zero,
            end: .seconds(1),
            text: "InferPeer Sandbox transcription",
            isFinal: true
        )
    }
}
