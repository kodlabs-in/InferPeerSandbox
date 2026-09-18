import Foundation
import InferPeerCore

actor SandboxClusterRunner {
    private let coordinator = SandboxCoordinatorScenario()
    private let caller = SandboxCallerScenario()
    private let worker = SandboxWorkerScenario()

    func setParticipation(_ participation: WorkerParticipationState) async {
        await coordinator.setParticipation(participation)
        await worker.setParticipation(participation)
    }

    func runIfConfigured(modelURL: URL) async -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawRole = environment["INFERPEER_VALIDATION_ROLE"],
            let role = SandboxClusterRole(rawValue: rawRole)
        else {
            return nil
        }

        do {
            let network = try await SandboxClusterSupport.wifiNetwork()
            return try await run(
                role: role,
                modelURL: modelURL,
                environment: environment,
                network: network
            )
        } catch {
            return recordFailure(error, role: role)
        }
    }

    private func run(
        role: SandboxClusterRole,
        modelURL: URL,
        environment: [String: String],
        network: SandboxWiFiNetwork
    ) async throws -> String {
        switch role {
        case .coordinator:
            try await coordinator.start(
                modelURL: modelURL,
                environment: environment,
                network: network
            )
        case .caller:
            try await caller.run(environment: environment, network: network)
        case .worker:
            try await worker.start(modelURL: modelURL, network: network)
        }
    }

    private func recordFailure(_ error: any Error, role: SandboxClusterRole) -> String {
        let detail = String(reflecting: error)
        try? SandboxEvidenceStore.writeCluster([
            "FAIL\tPhysical-device cluster\t\(detail)",
            "role\t\(role.rawValue)",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
        ])
        return "Cluster validation failed: \(detail)"
    }
}
