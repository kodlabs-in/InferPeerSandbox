import Foundation
import InferPeerCore
import InferPeerInference
import InferPeerModelStore

actor SandboxAutomationRunner {
    private let service: SandboxLocalAIService
    private var hasRun = false

    init(service: SandboxLocalAIService) {
        self.service = service
    }

    func runIfRequested() async {
        guard !hasRun,
            let rawMode = ProcessInfo.processInfo.environment["INFERPEER_AUTOMATION_MODE"],
            let mode = Mode(rawValue: rawMode)
        else { return }
        hasRun = true
        do {
            let evidence = try await run(mode: mode)
            try Self.write(evidence, mode: mode)
        } catch {
            try? Self.writeFailure(error, mode: mode)
        }
    }
}

private extension SandboxAutomationRunner {
    enum Mode: String {
        case stable
        case native
        case whisper

        var runtime: String {
            switch self {
            case .stable: "mlx"
            case .native: "llama.cpp"
            case .whisper: "whisperkit"
            }
        }

        var task: InferenceTask {
            switch self {
            case .stable, .native: .textGeneration
            case .whisper: .transcribe
            }
        }
    }

    struct Sample: Codable {
        let totalSeconds: Double
        let firstTextSeconds: Double?
        let outputTokens: UInt32
        let tokensPerSecond: Double
        let output: String
        let qualityPassed: Bool
    }

    struct Evidence: Codable {
        let passed: Bool
        let timestamp: String
        let hardwareIdentifier: String
        let operatingSystem: String
        let modelID: String
        let revision: String
        let runtime: String
        let peakResidentMemoryBytes: UInt64?
        let samples: [Sample]
    }

    struct Failure: Codable {
        let passed: Bool
        let timestamp: String
        let hardwareIdentifier: String
        let operatingSystem: String
        let mode: String
        let error: String
    }

    func run(mode: Mode) async throws -> Evidence {
        let candidate = try await selectCandidate(mode: mode)
        let key = try await install(candidate)
        var samples: [Sample] = []
        for _ in 0..<3 {
            samples.append(try await sample(mode: mode, model: key))
        }
        return Evidence(
            passed: samples.allSatisfy(\.qualityPassed),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            hardwareIdentifier: SandboxSystemMetrics.machineIdentifier,
            operatingSystem: SandboxSystemMetrics.operatingSystem,
            modelID: key.modelID.rawValue,
            revision: key.revision,
            runtime: candidate.runtime,
            peakResidentMemoryBytes: SandboxSystemMetrics.peakResidentMemoryBytes,
            samples: samples
        )
    }

    func selectCandidate(mode: Mode) async throws -> SandboxCatalogModel {
        let candidates = try await service.catalog()
        guard let model = candidates.first(where: {
            $0.runtime == mode.runtime
                && $0.task == mode.task
                && $0.support.sandboxIsInstallable
        }) else {
            throw SandboxAutomationError.noCompatibleModel(mode.runtime)
        }
        return model
    }

    func install(_ model: SandboxCatalogModel) async throws -> ModelKey {
        if let existing = try await service.installedModels().first(where: {
            $0.key.modelID == model.key.modelID
        }) {
            return existing.key
        }
        let installation = try await service.install(model.key, task: model.task)
        var installed: ModelKey?
        for try await event in installation.events {
            if case .installed(let model) = event {
                installed = model.key
            }
        }
        guard let installed else { throw SandboxAutomationError.installationDidNotComplete }
        return installed
    }

    func sample(mode: Mode, model: ModelKey) async throws -> Sample {
        switch mode {
        case .stable, .native:
            try await textSample(model: model)
        case .whisper:
            try await transcriptionSample(model: model)
        }
    }

    func textSample(model: ModelKey) async throws -> Sample {
        let started = ContinuousClock.now
        let stream = try await service.run(
            prompt: SandboxBenchmarkQuality.prompt,
            model: model,
            maxOutputTokens: 32
        )
        var firstText: ContinuousClock.Instant?
        var completed: RunResult?
        for try await event in stream {
            switch event {
            case .textDelta where firstText == nil:
                firstText = .now
            case .completed(let result):
                completed = result
            default:
                break
            }
        }
        let finished = ContinuousClock.now
        guard let completed else { throw SandboxAutomationError.generationDidNotComplete }
        let total = started.duration(to: finished).sandboxSeconds
        return Sample(
            totalSeconds: total,
            firstTextSeconds: firstText.map { started.duration(to: $0).sandboxSeconds },
            outputTokens: completed.usage.outputTokens,
            tokensPerSecond: Double(completed.usage.outputTokens) / max(total, 0.000_001),
            output: completed.text,
            qualityPassed: SandboxBenchmarkQuality.passes(completed.text)
        )
    }

    func transcriptionSample(model: ModelKey) async throws -> Sample {
        let audioURL = try Self.writeSilenceWAV()
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let started = ContinuousClock.now
        let stream = try await service.transcribe(audio: audioURL, model: model)
        var firstText: ContinuousClock.Instant?
        var completed: RunResult?
        for try await event in stream {
            switch event {
            case .transcriptSegment where firstText == nil:
                firstText = .now
            case .completed(let result):
                completed = result
            default:
                break
            }
        }
        let finished = ContinuousClock.now
        guard let completed else { throw SandboxAutomationError.generationDidNotComplete }
        let total = started.duration(to: finished).sandboxSeconds
        return Sample(
            totalSeconds: total,
            firstTextSeconds: firstText.map { started.duration(to: $0).sandboxSeconds },
            outputTokens: completed.usage.outputTokens,
            tokensPerSecond: 0,
            output: completed.text,
            qualityPassed: SandboxTranscriptionQuality.passesSilence(completed.text)
        )
    }

    static func writeSilenceWAV() throws -> URL {
        let sampleRate: UInt32 = 16_000
        let sampleCount = Int(sampleRate) * 2
        let dataByteCount = UInt32(sampleCount * MemoryLayout<Int16>.size)
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(36 + dataByteCount)
        data.appendASCII("WAVEfmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * 2)
        data.appendLittleEndian(UInt16(2))
        data.appendLittleEndian(UInt16(16))
        data.appendASCII("data")
        data.appendLittleEndian(dataByteCount)
        data.append(Data(count: Int(dataByteCount)))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inferpeer-silence-\(UUID().uuidString).wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func write(_ evidence: Evidence, mode: Mode) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SandboxEvidenceStore.writeAutomation(encoder.encode(evidence), mode: mode.rawValue)
    }

    static func writeFailure(_ error: any Error, mode: Mode) throws {
        let failure = Failure(
            passed: false,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            hardwareIdentifier: SandboxSystemMetrics.machineIdentifier,
            operatingSystem: SandboxSystemMetrics.operatingSystem,
            mode: mode.rawValue,
            error: String(describing: error)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SandboxEvidenceStore.writeAutomation(encoder.encode(failure), mode: mode.rawValue)
    }
}

private enum SandboxAutomationError: Error {
    case noCompatibleModel(String)
    case installationDidNotComplete
    case generationDidNotComplete
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
