import CryptoKit
import Foundation
import InferPeer
import InferPeerCore
import InferPeerInference
import InferPeerMLX
import InferPeerProtocol
#if os(iOS)
    import UIKit
#endif

enum SandboxPinnedModel {
    static let directoryName = "Qwen3-0.6B-4bit"
    static let modelID = "mlx-community/Qwen3-0.6B-4bit"
    static let revision = "73e3e38d981303bc594367cd910ea6eb48349da8"
    static let weightsSHA256 =
        "392e8d466d56100ada00eb82031fb854297fc9e389b7d303eba3af114e87bce2"
}

struct SandboxModelResult: Sendable {
    let text: String
    let modelID: String
    let revision: String
    let weightsSHA256: String
    let loadSeconds: Double
    let firstTextSeconds: Double?
    let generationSeconds: Double
    let promptTokens: UInt32
    let outputTokens: UInt32
    let tokensPerSecond: Double

    var summary: String {
        String(
            format: "%@ · load %.2fs · first text %.2fs · %.2f tokens/s",
            modelID,
            loadSeconds,
            firstTextSeconds ?? 0,
            tokensPerSecond
        )
    }
}

enum SandboxModelError: Error, LocalizedError, Sendable {
    case weightsMissing
    case weightsDigestMismatch(expected: String, actual: String)
    case generationDidNotComplete

    var errorDescription: String? {
        switch self {
        case .weightsMissing:
            "The pinned model does not contain model.safetensors."
        case .weightsDigestMismatch(let expected, let actual):
            "The model weights digest is \(actual); expected \(expected)."
        case .generationDidNotComplete:
            "The InferPeer event stream ended without a completion event."
        }
    }
}

struct SandboxVerifiedModelArtifact: Sendable {
    let artifact: LocalModelArtifact
    let weightsSHA256: String
}

enum SandboxModelArtifactFactory {
    static func make(at directoryURL: URL) async throws -> SandboxVerifiedModelArtifact {
        let digests = try await Task.detached(priority: .utility) {
            try DirectoryDigest.verify(directoryURL)
        }.value
        let reference = try ModelReference(
            modelID: requiredID(ModelID.self, value: SandboxPinnedModel.modelID),
            revision: SandboxPinnedModel.revision
        )
        let descriptor = try ModelDescriptor(
            reference: reference,
            runtimeFormat: .mlx,
            metadata: try ModelMetadata(
                quantization: "4-bit, group size 64",
                tokenizer: "tokenizer.json",
                chatTemplate: "tokenizer_config.json",
                license: "Apache-2.0"
            ),
            contextTokenLimit: 40_960,
            contentDigest: try ModelContentDigest(bytes: digests.directory)
        )
        return try SandboxVerifiedModelArtifact(
            artifact: LocalModelArtifact(descriptor: descriptor, directoryURL: directoryURL),
            weightsSHA256: digests.weightsHex
        )
    }

    private static func requiredID<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        value: String
    ) -> ProtocolIdentifier<Domain> {
        guard let identifier = ProtocolIdentifier<Domain>(rawValue: value) else {
            preconditionFailure("Sandbox identifier must be valid")
        }
        return identifier
    }
}

actor SandboxMLXRunner {
    func run(directoryURL: URL) async throws -> SandboxModelResult {
        let didAccess = directoryURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { directoryURL.stopAccessingSecurityScopedResource() }
        }

        let verified = try await SandboxModelArtifactFactory.make(at: directoryURL)
        let reference = verified.artifact.descriptor.reference
        let facade = try InferPeer(
            configuration: InferPeerConfiguration(
                localResource: LocalResourceConfiguration(
                    displayName: "InferPeer Sandbox",
                    platform: await platformDescriptor()
                ),
                localRuntime: MLXInferenceBackend(),
                localModels: [verified.artifact],
                defaultTextModel: reference
            )
        )
        return try await runAndStop(
            facade,
            query: makeQuery(reference: reference),
            weightsSHA256: verified.weightsSHA256
        )
    }

    private func runAndStop(
        _ facade: InferPeer,
        query: InferenceQuery,
        weightsSHA256: String
    ) async throws -> SandboxModelResult {
        do {
            let runStart = ContinuousClock.now
            let handle = try await facade.run(query, resourceId: .local)
            let observation = try await observe(handle.events, runStart: runStart)
            let result = try await handle.result()
            await facade.stop()
            return makeResult(
                result,
                observation: observation,
                weightsSHA256: weightsSHA256
            )
        } catch {
            await facade.stop()
            throw error
        }
    }

    private func observe(
        _ events: RunEventStream,
        runStart: ContinuousClock.Instant
    ) async throws -> SandboxRunObservation {
        var tracker = SandboxRunTimingTracker()
        for try await event in events {
            tracker.record(event)
        }
        return try tracker.observation(runStart: runStart)
    }

    private func makeResult(
        _ result: RunResult,
        observation: SandboxRunObservation,
        weightsSHA256: String
    ) -> SandboxModelResult {
        let generationSeconds = seconds(observation.generationDuration)
        let outputTokens = result.usage.outputTokens
        let throughput = generationSeconds > 0 ? Double(outputTokens) / generationSeconds : 0
        return SandboxModelResult(
            text: result.text,
            modelID: SandboxPinnedModel.modelID,
            revision: SandboxPinnedModel.revision,
            weightsSHA256: weightsSHA256,
            loadSeconds: seconds(observation.loadDuration),
            firstTextSeconds: observation.firstTextDuration.map(seconds),
            generationSeconds: generationSeconds,
            promptTokens: result.usage.promptTokens,
            outputTokens: outputTokens,
            tokensPerSecond: throughput
        )
    }

    private func makeQuery(reference: ModelReference) -> InferenceQuery {
        .text(
            model: .exact(reference),
            messages: [.user("Reply with exactly: InferPeer offline OK")],
            generation: .init(maxOutputTokens: 32, temperature: 0)
        )
    }

    private func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private func platformDescriptor() async -> PlatformDescriptor {
        #if os(iOS)
            let operatingSystem: PlatformDescriptor.OperatingSystem = await MainActor.run {
                UIDevice.current.userInterfaceIdiom == .pad ? .iPadOS : .iOS
            }
        #else
            let operatingSystem = PlatformDescriptor.OperatingSystem.macOS
        #endif
        return PlatformDescriptor(
            operatingSystem: operatingSystem,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

private struct SandboxRunObservation {
    let loadDuration: Duration
    let firstTextDuration: Duration?
    let generationDuration: Duration
}

private struct SandboxRunTimingTracker {
    private var executionStart: ContinuousClock.Instant?
    private var firstTextDuration: Duration?
    private var terminalObserved = false

    mutating func record(_ event: RunEvent) {
        switch event {
        case .started:
            executionStart = .now
        case .textDelta where firstTextDuration == nil:
            firstTextDuration = executionStart?.duration(to: .now)
        case .completed, .failed, .cancelled:
            terminalObserved = true
        default:
            break
        }
    }

    func observation(runStart: ContinuousClock.Instant) throws -> SandboxRunObservation {
        guard terminalObserved, let executionStart else {
            throw SandboxModelError.generationDidNotComplete
        }
        return SandboxRunObservation(
            loadDuration: runStart.duration(to: executionStart),
            firstTextDuration: firstTextDuration,
            generationDuration: executionStart.duration(to: .now)
        )
    }
}

private struct VerifiedModelDigests: Sendable {
    let weightsHex: String
    let directory: Data
}

private enum DirectoryDigest {
    static func verify(_ directoryURL: URL) throws -> VerifiedModelDigests {
        let weightsURL = directoryURL.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw SandboxModelError.weightsMissing
        }
        let weights = try hashFile(weightsURL)
        let weightsHex = hex(weights)
        guard weightsHex == SandboxPinnedModel.weightsSHA256 else {
            throw SandboxModelError.weightsDigestMismatch(
                expected: SandboxPinnedModel.weightsSHA256,
                actual: weightsHex
            )
        }
        return try VerifiedModelDigests(
            weightsHex: weightsHex,
            directory: hashDirectory(directoryURL)
        )
    }

    private static func hashDirectory(_ directoryURL: URL) throws -> Data {
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

    private static func hashFile(_ url: URL) throws -> Data {
        var hasher = SHA256()
        try hashContents(of: url, into: &hasher)
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

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
