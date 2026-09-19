import Foundation
import InferPeerApple
import InferPeerCore
import InferPeerInference
import InferPeerLlama
import InferPeerMLX
import InferPeerModelStore
import InferPeerWhisperKit

struct SandboxResourceCard: Identifiable, Sendable {
    let id: ResourceID
    let name: String
    let platform: String
    let hardware: String
    let physicalMemoryBytes: UInt64?
    let availableMemoryBytes: UInt64?
    let freeStorageBytes: UInt64?
    let chipFeatures: [String]
    let connection: ConnectionState
    let execution: ExecutionAvailability
}

struct SandboxCatalogModel: Identifiable, Sendable {
    var id: ModelCatalogKey { key }
    let key: ModelCatalogKey
    let displayName: String
    let publisher: String
    let runtime: String
    let format: String
    let quantization: String
    let status: ModelCatalogStatus
    let downloadBytes: UInt64
    let support: ModelSupport
    let task: InferenceTask
}

struct SandboxInstalledModel: Identifiable, Sendable {
    var id: ModelKey { key }
    let key: ModelKey
    let displayName: String
    let runtime: String
    let format: String
    let installedBytes: UInt64
    let isLoaded: Bool
    let tasks: Set<InferenceTask>
}

struct SandboxBenchmarkSample: Identifiable, Sendable {
    let id = UUID()
    let model: ModelKey
    let startedAt: Date
    let loadSeconds: Double
    let firstTextSeconds: Double?
    let totalSeconds: Double
    let outputTokens: UInt32
    let tokensPerSecond: Double
    let qualityPassed: Bool
}

enum SandboxBenchmarkQuality {
    static let expectedOutput = "BENCHMARK_OK"
    static let prompt = "/no_think\nReply with exactly: \(expectedOutput)"

    static func passes(_ output: String) -> Bool {
        let normalized = output.replacingOccurrences(
            of: #"^\s*<think>\s*</think>\s*"#,
            with: "",
            options: .regularExpression
        )
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines) == expectedOutput
    }
}

enum SandboxTranscriptionQuality {
    static func passesSilence(_ output: String) -> Bool {
        let withoutControlTokens = output.replacingOccurrences(
            of: #"<\|[^|]+\|>"#,
            with: "",
            options: .regularExpression
        )
        return withoutControlTokens.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

actor SandboxLocalAIService {
    private var store: InferPeerModelStore?

    func localResource() throws -> SandboxResourceCard {
        let profile = try currentProfile()
        return SandboxResourceCard(
            id: .local,
            name: Self.resourceName(for: profile.platform),
            platform: profile.platform.operatingSystem.rawValue + " "
                + profile.platform.operatingSystemVersion,
            hardware: profile.platform.hardwareIdentifier ?? "Unknown hardware",
            physicalMemoryBytes: profile.modelStoreProfile.physicalMemoryBytes,
            availableMemoryBytes: profile.modelStoreProfile.availableMemoryBytes,
            freeStorageBytes: profile.modelStoreProfile.freeStorageBytes,
            chipFeatures: profile.chipFeatures.sorted(),
            connection: .connected,
            execution: .available
        )
    }

    func catalog() async throws -> [SandboxCatalogModel] {
        let store = try await currentStore()
        let profile = try currentProfile().modelStoreProfile
        var models: [SandboxCatalogModel] = []
        for task in InferenceTask.allCases {
            let candidates = await store.catalog(task: task, resource: profile)
            models.append(contentsOf: candidates.compactMap { candidate in
                guard candidate.entry.manifest.capabilities.contains(where: { $0.task == task })
                else { return nil }
                return SandboxCatalogModel(
                    key: candidate.entry.metadata.key,
                    displayName: candidate.entry.metadata.displayName,
                    publisher: candidate.entry.metadata.publisher,
                    runtime: candidate.entry.manifest.runtime.runtimeIdentifier,
                    format: candidate.entry.manifest.runtime.format,
                    quantization: candidate.entry.manifest.runtime.quantization,
                    status: candidate.entry.metadata.status,
                    downloadBytes: candidate.entry.approximateDownloadBytes,
                    support: candidate.support,
                    task: task
                )
            })
        }
        return models.sorted { $0.displayName < $1.displayName }
    }

    func installedModels() async throws -> [SandboxInstalledModel] {
        let store = try await currentStore()
        var summaries: [SandboxInstalledModel] = []
        for model in try await store.installedModels() {
            let status = try await store.status(of: model.key)
            summaries.append(
                SandboxInstalledModel(
                    key: model.key,
                    displayName: model.manifest.name,
                    runtime: model.manifest.runtime.runtimeIdentifier,
                    format: model.manifest.runtime.format,
                    installedBytes: model.installedByteCount,
                    isLoaded: status?.isLoaded == true,
                    tasks: Set(model.manifest.capabilities.map(\.task))
                )
            )
        }
        return summaries.sorted { $0.displayName < $1.displayName }
    }

    func install(_ key: ModelCatalogKey, task: InferenceTask) async throws -> ModelInstallation {
        let store = try await currentStore()
        let profile = try currentProfile().modelStoreProfile
        return try await store.install(
            key,
            task: task,
            on: profile,
            authorization: ModelDownloadAuthorization(resourceID: .local)
        )
    }

    func pause(jobID: UUID) async throws {
        let store = try await currentStore()
        await store.pause(jobID: jobID)
    }

    func remove(_ key: ModelKey) async throws {
        let store = try await currentStore()
        try await store.remove(key, policy: .unloadAndRemove)
    }

    func run(
        prompt: String,
        model key: ModelKey,
        maxOutputTokens: UInt32 = 256
    ) async throws -> DirectRuntimeEventStream {
        let store = try await currentStore()
        let profile = try currentProfile().modelStoreProfile
        if try await store.status(of: key)?.isLoaded != true {
            try await store.load(key, on: profile)
        }
        let query = InferenceQuery.text(
            model: .exact(key),
            messages: [.user(prompt)],
            generation: .init(maxOutputTokens: maxOutputTokens, temperature: 0)
        )
        return try await store.run(query, using: key)
    }

    func transcribe(audio: URL, model key: ModelKey) async throws -> DirectRuntimeEventStream {
        let store = try await currentStore()
        let profile = try currentProfile().modelStoreProfile
        if try await store.status(of: key)?.isLoaded != true {
            try await store.load(key, on: profile)
        }
        let query = InferenceQuery.transcribe(
            model: .exact(key),
            audio: .file(audio)
        )
        return try await store.run(query, using: key)
    }
}

private extension SandboxLocalAIService {
    func currentStore() async throws -> InferPeerModelStore {
        if let store { return store }
        let root = try modelStoreRoot()
        let starter = try InferPeerStarterCatalog.load()
        let opened = try await InferPeerModelStore.open(
            configuration: InferPeerModelStoreConfiguration(
                rootDirectory: root,
                builtInCatalog: starter.signedCatalog,
                trustedCatalogKeys: starter.trustedCatalogKeys,
                runtimeAdapters: [
                    MLXRuntimeAdapter(),
                    LlamaRuntimeAdapter(),
                    WhisperKitRuntimeAdapter(),
                ]
            )
        )
        store = opened
        return opened
    }

    func currentProfile() throws -> AppleDeviceProfileSnapshot {
        try AppleDeviceProfiler(storageURL: modelStoreRoot()).snapshot()
    }

    func modelStoreRoot() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appending(path: "InferPeerSandbox", directoryHint: .isDirectory)
            .appending(path: "InferPeerModels", directoryHint: .isDirectory)
    }

    static func resourceName(for platform: PlatformDescriptor) -> String {
        switch platform.operatingSystem {
        case .iOS: "This iPhone"
        case .iPadOS: "This iPad"
        case .macOS: "This Mac"
        }
    }
}

extension ModelSupport {
    var sandboxTitle: String {
        switch self {
        case .supported:
            "Supported"
        case .experimental:
            "Experimental"
        case .unsupported:
            "Unsupported"
        }
    }

    var sandboxIsInstallable: Bool { isInstallable }
}

extension Duration {
    var sandboxSeconds: Double {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
