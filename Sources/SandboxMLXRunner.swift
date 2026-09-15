import CryptoKit
import Foundation
import InferPeerInference
import InferPeerMLX
import InferPeerProtocol

struct SandboxModelResult: Sendable {
    let text: String
    let summary: String
}

actor SandboxMLXRunner {
    func run(directoryURL: URL) async throws -> SandboxModelResult {
        let didAccess = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { directoryURL.stopAccessingSecurityScopedResource() }
        }

        let digest = try await Task.detached(priority: .utility) {
            try DirectoryDigest.hash(directoryURL)
        }.value
        let reference = try ModelReference(
            modelID: requiredID(ModelID.self, value: "sandbox-local-model"),
            revision: digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
        )
        let artifact = try makeArtifact(
            reference: reference,
            digest: digest,
            directoryURL: directoryURL
        )
        let request = try makeRequest(reference: reference)
        let backend = MLXInferenceBackend()
        let loadStart = ContinuousClock.now
        try await backend.loadModel(artifact)
        let loadDuration = loadStart.duration(to: .now)
        defer { Task { try? await backend.unloadModel(reference) } }

        let execution = InferenceExecution(
            requestID: requiredID(
                RequestID.self, value: "request-\(UUID().uuidString.lowercased())"),
            attemptID: requiredID(
                AttemptID.self, value: "attempt-\(UUID().uuidString.lowercased())"),
            model: reference,
            request: request
        )
        let generationStart = ContinuousClock.now
        let events = try await backend.generate(execution)
        var output = ""
        var firstTextDuration: Duration?
        var usage: TokenUsage?
        for try await event in events {
            switch event {
            case .textDelta(let delta):
                if firstTextDuration == nil {
                    firstTextDuration = generationStart.duration(to: .now)
                }
                output += delta.text
            case .completed(let result):
                usage = result.usage
            }
        }
        let generationDuration = generationStart.duration(to: .now)
        return SandboxModelResult(
            text: output,
            summary: summary(
                load: loadDuration,
                firstText: firstTextDuration,
                generation: generationDuration,
                usage: usage,
                revision: reference.revision
            )
        )
    }

    private func makeArtifact(
        reference: ModelReference,
        digest: Data,
        directoryURL: URL
    ) throws -> LocalModelArtifact {
        let descriptor = try ModelDescriptor(
            reference: reference,
            runtimeFormat: .mlx,
            metadata: try ModelMetadata(
                quantization: "host-provided",
                tokenizer: "tokenizer.json",
                chatTemplate: "model-config",
                license: "host-must-verify"
            ),
            contextTokenLimit: 4_096,
            contentDigest: try ModelContentDigest(bytes: digest)
        )
        return try LocalModelArtifact(descriptor: descriptor, directoryURL: directoryURL)
    }

    private func makeRequest(reference: ModelReference) throws -> TextGenerationRequest {
        let context = try ConversationContext(
            conversationID: requiredID(
                ConversationID.self,
                value: "conversation-\(UUID().uuidString.lowercased())"
            ),
            revision: 1,
            messages: [
                try TextMessage(role: .user, text: "Reply with exactly: InferPeer offline OK")
            ]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(reference),
            maximumOutputTokens: 32,
            sampling: try SamplingOptions(temperature: 0)
        )
        return TextGenerationRequest(context: context, options: options)
    }

    private func summary(
        load: Duration,
        firstText: Duration?,
        generation: Duration,
        usage: TokenUsage?,
        revision: String
    ) -> String {
        let firstTextValue = firstText.map(seconds) ?? 0
        let outputTokens = usage?.outputTokens ?? 0
        let throughput =
            seconds(generation) > 0
            ? Double(outputTokens) / seconds(generation)
            : 0
        return String(
            format: "Offline run %@ · load %.2fs · first text %.2fs · %.2f tokens/s",
            revision,
            seconds(load),
            firstTextValue,
            throughput
        )
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func requiredID<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        value: String
    ) -> ProtocolIdentifier<Domain> {
        guard let identifier = ProtocolIdentifier<Domain>(rawValue: value) else {
            preconditionFailure("Sandbox identifier must be valid")
        }
        return identifier
    }
}

private enum DirectoryDigest {
    static func hash(_ directoryURL: URL) throws -> Data {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )
        else {
            throw CocoaError(.fileReadUnknown)
        }
        let files = try enumerator.compactMap { element -> URL? in
            guard let url = element as? URL else { return nil }
            return try url.resourceValues(forKeys: Set(keys)).isRegularFile == true ? url : nil
        }.sorted { relativePath($0, to: directoryURL) < relativePath($1, to: directoryURL) }

        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(relativePath(file, to: directoryURL).utf8))
            try hashContents(of: file, into: &hasher)
        }
        return Data(hasher.finalize())
    }

    private static func hashContents(of url: URL, into hasher: inout SHA256) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
    }

    private static func relativePath(_ url: URL, to directoryURL: URL) -> String {
        String(url.path.dropFirst(directoryURL.path.count))
    }
}
