import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import SwiftUI

@MainActor
final class SandboxResourceController: ObservableObject {
    @Published private(set) var resources: [SandboxResourceCard] = []
    @Published private(set) var status = "Reading device resources…"

    private let service: SandboxLocalAIService

    init(service: SandboxLocalAIService) {
        self.service = service
    }

    func refresh() async {
        do {
            resources = [try await service.localResource()]
            status = "Local resource ready. Remote hosts appear after authenticated pairing."
        } catch {
            status = "Resource profiling failed: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class SandboxModelLibraryController: ObservableObject {
    @Published private(set) var catalog: [SandboxCatalogModel] = []
    @Published private(set) var installed: [SandboxInstalledModel] = []
    @Published private(set) var progress: ModelInstallationProgress?
    @Published private(set) var status = "Opening signed starter catalog…"
    @Published private(set) var activeJobID: UUID?

    private let service: SandboxLocalAIService
    private var installTask: Task<Void, Never>?

    init(service: SandboxLocalAIService) {
        self.service = service
    }

    func refresh() async {
        do {
            async let catalog = service.catalog()
            async let installed = service.installedModels()
            self.catalog = try await catalog
            self.installed = try await installed
            status = self.installed.isEmpty
                ? "Choose a stable compatible model to download."
                : "\(self.installed.count) verified model installation(s)."
        } catch {
            status = "Model library failed: \(error.localizedDescription)"
        }
    }

    func install(_ model: SandboxCatalogModel) {
        guard activeJobID == nil, model.support.sandboxIsInstallable else { return }
        status = "Authorizing package-owned download…"
        progress = nil
        installTask = Task { [weak self] in
            await self?.performInstall(model)
        }
    }

    func pause() {
        guard let activeJobID else { return }
        installTask?.cancel()
        Task { [service] in try? await service.pause(jobID: activeJobID) }
        status = "Download paused. Resume by choosing Install again."
        self.activeJobID = nil
    }

    func remove(_ model: SandboxInstalledModel) {
        Task {
            do {
                try await service.remove(model.key)
                await refresh()
            } catch {
                status = "Removal failed: \(error.localizedDescription)"
            }
        }
    }
}

private extension SandboxModelLibraryController {
    func performInstall(_ model: SandboxCatalogModel) async {
        do {
            let installation = try await service.install(model.key, task: model.task)
            activeJobID = installation.jobID
            for try await event in installation.events {
                apply(event)
            }
            activeJobID = nil
            progress = nil
            await refresh()
        } catch is CancellationError {
            status = "Download paused."
        } catch {
            activeJobID = nil
            status = "Installation failed: \(error.localizedDescription)"
        }
    }

    func apply(_ event: ModelInstallationEvent) {
        switch event {
        case .state(let state):
            status = "Model state: \(String(describing: state))"
        case .progress(let progress):
            self.progress = progress
            status = "Downloading \(progress.filePath)"
        case .installed(let model):
            status = "Verified and installed \(model.manifest.name)."
        }
    }
}

@MainActor
final class SandboxChatController: ObservableObject {
    @Published var prompt = "/no_think\nReply with exactly: InferPeer package download OK"
    @Published private(set) var output = ""
    @Published private(set) var status = "Install a model, then run a prompt."
    @Published private(set) var isRunning = false
    @Published var selectedModel: ModelKey?

    private let service: SandboxLocalAIService
    private var runTask: Task<Void, Never>?

    init(service: SandboxLocalAIService) {
        self.service = service
    }

    func run(installed: [SandboxInstalledModel]) {
        guard !isRunning, let key = resolvedModel(from: installed), !prompt.isEmpty else { return }
        output = ""
        status = "Loading exact selected model…"
        isRunning = true
        runTask = Task { [weak self] in
            await self?.consume(prompt: self?.prompt ?? "", model: key)
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = "Cancelled."
    }
}

private extension SandboxChatController {
    func resolvedModel(from installed: [SandboxInstalledModel]) -> ModelKey? {
        let compatible = installed.filter { $0.tasks.contains(.textGeneration) }
        if let selectedModel, compatible.contains(where: { $0.key == selectedModel }) {
            return selectedModel
        }
        selectedModel = compatible.first?.key
        return selectedModel
    }

    func consume(prompt: String, model: ModelKey) async {
        do {
            let stream = try await service.run(prompt: prompt, model: model)
            for try await event in stream {
                try Task.checkCancellation()
                apply(event)
            }
            status = "Completed on this exact resource."
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = "Run failed: \(error.localizedDescription)"
        }
        isRunning = false
    }

    func apply(_ event: DirectRuntimeEvent) {
        switch event {
        case .preprocessing(let stage):
            status = "Preprocessing: \(stage.rawValue)"
        case .textDelta(let delta):
            output += delta
            status = "Streaming from selected resource…"
        case .completed(let result):
            output = result.text
            status = "Completed · \(result.usage.outputTokens) output tokens"
        case .transcriptSegment, .audioChunk:
            break
        }
    }
}

@MainActor
final class SandboxBenchmarkController: ObservableObject {
    @Published private(set) var samples: [SandboxBenchmarkSample] = []
    @Published private(set) var status = "Run a deterministic warm benchmark."
    @Published private(set) var isRunning = false

    private let service: SandboxLocalAIService

    init(service: SandboxLocalAIService) {
        self.service = service
    }

    func run(installed: [SandboxInstalledModel]) {
        guard !isRunning,
            let model = installed.first(where: { $0.tasks.contains(.textGeneration) })
        else { return }
        isRunning = true
        status = "Running three deterministic samples…"
        Task { [weak self] in
            await self?.runSamples(model: model.key)
        }
    }
}

@MainActor
final class SandboxTranscriptionController: ObservableObject {
    @Published private(set) var audioURL: URL?
    @Published private(set) var transcript = ""
    @Published private(set) var status = "Install Whisper, then choose an audio file."
    @Published private(set) var isRunning = false
    @Published var selectedModel: ModelKey?

    private let service: SandboxLocalAIService
    private var runTask: Task<Void, Never>?

    init(service: SandboxLocalAIService) {
        self.service = service
    }

    func receive(_ result: Result<[URL], any Error>) {
        do {
            audioURL = try result.get().first
            status = audioURL.map { "Ready to transcribe \($0.lastPathComponent)." }
                ?? "No audio file selected."
        } catch {
            status = "Audio selection failed: \(error.localizedDescription)"
        }
    }

    func run(installed: [SandboxInstalledModel]) {
        let compatible = installed.filter { $0.tasks.contains(.transcribe) }
        guard !isRunning, let audioURL else { return }
        guard let model = resolveModel(from: compatible) else {
            status = "Install a Whisper transcription model first."
            return
        }
        isRunning = true
        transcript = ""
        status = "Loading exact Whisper model…"
        runTask = Task { [weak self] in
            await self?.consume(audioURL: audioURL, model: model)
        }
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        status = "Cancelled."
    }
}

private extension SandboxTranscriptionController {
    func resolveModel(from models: [SandboxInstalledModel]) -> ModelKey? {
        if let selectedModel, models.contains(where: { $0.key == selectedModel }) {
            return selectedModel
        }
        selectedModel = models.first?.key
        return selectedModel
    }

    func consume(audioURL: URL, model: ModelKey) async {
        let access = audioURL.startAccessingSecurityScopedResource()
        defer {
            if access { audioURL.stopAccessingSecurityScopedResource() }
            isRunning = false
        }
        do {
            let stream = try await service.transcribe(audio: audioURL, model: model)
            for try await event in stream {
                try Task.checkCancellation()
                apply(event)
            }
            status = "Transcription completed on this device."
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
    }

    func apply(_ event: DirectRuntimeEvent) {
        switch event {
        case .preprocessing(let stage):
            status = "Preprocessing: \(stage.rawValue)"
        case .transcriptSegment(let segment):
            transcript += (transcript.isEmpty ? "" : " ") + segment.text
        case .completed(let result):
            transcript = result.text
        case .textDelta, .audioChunk:
            break
        }
    }
}

private extension SandboxBenchmarkController {
    func runSamples(model: ModelKey) async {
        do {
            var samples: [SandboxBenchmarkSample] = []
            for _ in 0..<3 {
                samples.append(try await sample(model: model))
            }
            self.samples = samples
            status = "Benchmark complete. Compare only results meeting the same quality floor."
        } catch {
            status = "Benchmark failed: \(error.localizedDescription)"
        }
        isRunning = false
    }

    func sample(model: ModelKey) async throws -> SandboxBenchmarkSample {
        let startedAt = Date()
        let started = ContinuousClock.now
        let stream = try await service.run(
            prompt: SandboxBenchmarkQuality.prompt,
            model: model,
            maxOutputTokens: 32
        )
        let loaded = ContinuousClock.now
        var firstText: ContinuousClock.Instant?
        var result: RunResult?
        for try await event in stream {
            switch event {
            case .textDelta where firstText == nil:
                firstText = .now
            case .completed(let completed):
                result = completed
            default:
                break
            }
        }
        let finished = ContinuousClock.now
        let completed = try requireResult(result)
        let totalSeconds = started.duration(to: finished).sandboxSeconds
        let generationSeconds = max(loaded.duration(to: finished).sandboxSeconds, 0.000_001)
        return SandboxBenchmarkSample(
            model: model,
            startedAt: startedAt,
            loadSeconds: started.duration(to: loaded).sandboxSeconds,
            firstTextSeconds: firstText.map { loaded.duration(to: $0).sandboxSeconds },
            totalSeconds: totalSeconds,
            outputTokens: completed.usage.outputTokens,
            tokensPerSecond: Double(completed.usage.outputTokens) / generationSeconds,
            qualityPassed: SandboxBenchmarkQuality.passes(completed.text)
        )
    }

    func requireResult(_ result: RunResult?) throws -> RunResult {
        guard let result else { throw SandboxModelError.generationDidNotComplete }
        return result
    }
}
