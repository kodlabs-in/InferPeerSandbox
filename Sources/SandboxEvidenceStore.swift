import Foundation

enum SandboxEvidenceStore {
    static func directory() throws -> URL {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        var directory = base.appendingPathComponent("InferPeerSandbox", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        #if os(iOS)
            try manager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: directory.path
            )
        #endif
        return directory
    }

    static func writeChecks(_ checks: [SandboxCheck]) throws {
        let lines = checks.map { "\($0.passed ? "PASS" : "FAIL")\t\($0.name)\t\($0.detail)" }
        try write(lines, to: "latest-validation.txt")
    }

    static func writeModelSuccess(_ result: SandboxModelResult) throws {
        try write(
            [
                "PASS\tBundled MLX inference",
                "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
                "model\t\(result.modelID)",
                "revision\t\(result.revision)",
                "weights_sha256\t\(result.weightsSHA256)",
                "device_model\t\(SandboxSystemMetrics.machineIdentifier)",
                "os_version\t\(SandboxSystemMetrics.operatingSystem)",
                "context_token_limit\t40960",
                String(format: "load_seconds\t%.3f", result.loadSeconds),
                String(format: "first_text_seconds\t%.3f", result.firstTextSeconds ?? 0),
                String(format: "generation_seconds\t%.3f", result.generationSeconds),
                "prompt_tokens\t\(result.promptTokens)",
                "output_tokens\t\(result.outputTokens)",
                String(format: "tokens_per_second\t%.3f", result.tokensPerSecond),
                "peak_app_memory_bytes\t\(SandboxSystemMetrics.peakResidentMemoryBytes ?? 0)",
                "output_characters\t\(result.text.count)",
            ],
            to: "latest-model-validation.txt"
        )
    }

    static func writeModelFailure(_ detail: String) throws {
        try write(
            [
                "FAIL\tBundled MLX inference\t\(detail)",
                "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
                "model\t\(SandboxPinnedModel.modelID)",
                "revision\t\(SandboxPinnedModel.revision)",
                "expected_weights_sha256\t\(SandboxPinnedModel.weightsSHA256)",
                "device_model\t\(SandboxSystemMetrics.machineIdentifier)",
                "os_version\t\(SandboxSystemMetrics.operatingSystem)",
            ],
            to: "latest-model-validation.txt"
        )
    }

    static func writeCluster(_ lines: [String]) throws {
        try write(lines, to: "latest-cluster-validation.txt")
    }

    static func writeLifecycle(_ lines: [String]) throws {
        try write(lines, to: "latest-lifecycle-validation.txt")
    }

    static func writeFailures(_ checks: [SandboxCheck]) throws {
        let lines = checks.map { "\($0.passed ? "PASS" : "FAIL")\t\($0.name)\t\($0.detail)" }
        try write(lines, to: "latest-failure-validation.txt")
    }

    static func writeAutomation(_ data: Data, mode: String) throws {
        try data.write(
            to: directory().appendingPathComponent("automation-\(mode).json"),
            options: .atomic
        )
    }

    private static func write(_ lines: [String], to filename: String) throws {
        try lines.joined(separator: "\n").write(
            to: directory().appendingPathComponent(filename),
            atomically: true,
            encoding: .utf8
        )
    }
}
