import InferPeerInference
import InferPeerMLX
import InferPeerProtocol

actor SandboxInterruptOnceBackend: InferenceBackend {
    private let backend: MLXInferenceBackend
    private let textEventLimit: Int
    private var shouldInterrupt = true

    init(backend: MLXInferenceBackend, textEventLimit: Int = 8) {
        self.backend = backend
        self.textEventLimit = textEventLimit
    }

    func estimateResources(
        for request: TextGenerationRequest,
        using model: ModelDescriptor
    ) async throws -> InferenceResourceEstimate {
        try await backend.estimateResources(for: request, using: model)
    }

    func loadModel(_ model: LocalModelArtifact) async throws {
        try await backend.loadModel(model)
    }

    func unloadModel(_ reference: ModelReference) async throws {
        try await backend.unloadModel(reference)
    }

    func generate(_ execution: InferenceExecution) async throws -> GenerationEventStream {
        let stream = try await backend.generate(execution)
        guard shouldInterrupt else { return stream }
        shouldInterrupt = false
        return interrupting(stream, execution: execution)
    }

    func cancel(attemptID: AttemptID) async {
        await backend.cancel(attemptID: attemptID)
    }

    private func interrupting(
        _ source: GenerationEventStream,
        execution: InferenceExecution
    ) -> GenerationEventStream {
        let pair = GenerationEventStream.makeStream(bufferingPolicy: .bufferingOldest(32))
        let task = Task {
            do {
                var textEventCount = 0
                for try await event in source {
                    if case .textDelta = event { textEventCount += 1 }
                    if textEventCount >= textEventLimit {
                        await backend.cancel(attemptID: execution.attemptID)
                        pair.continuation.finish(
                            throwing: InferenceBackendError.executionFailed(retryable: true)
                        )
                        return
                    }
                    guard case .dropped = pair.continuation.yield(event) else { continue }
                    throw InferenceBackendError.resourceExhausted
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        pair.continuation.onTermination = { @Sendable _ in
            task.cancel()
            Task { await self.backend.cancel(attemptID: execution.attemptID) }
        }
        return pair.stream
    }
}
