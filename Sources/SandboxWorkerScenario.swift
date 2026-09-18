import Foundation
import InferPeer
import InferPeerCore
import InferPeerDiscovery
import InferPeerInference
import InferPeerMLX
import InferPeerStorage
import InferPeerTelemetry

actor SandboxWorkerScenario {
    private var retainedNode: InferPeerNode?

    func start(modelURL: URL, network: SandboxWiFiNetwork) async throws -> String {
        let invitation = try SandboxClusterSupport.invitation()
        let identity = try await SandboxClusterSupport.makeIdentity(approvedRoles: [.worker])
        let verified = try await SandboxModelArtifactFactory.make(at: modelURL)
        let mlxBackend = MLXInferenceBackend()
        let backend: any InferenceBackend =
            ProcessInfo.processInfo.environment["INFERPEER_WORKER_INTERRUPT_ONCE"] == "1"
            ? SandboxInterruptOnceBackend(backend: mlxBackend)
            : mlxBackend
        try await backend.loadModel(verified.artifact)
        let status = try SystemStatusProvider(
            participation: .available,
            models: [
                try SandboxClusterSupport.modelSnapshot(
                    verified.artifact.descriptor.reference
                )
            ]
        )
        let node = try makeNode(
            invitation: invitation,
            identity: identity,
            backend: backend,
            status: status,
            network: network
        )
        try await node.start()
        _ = try await node.join(invitation)
        retainedNode = node
        try writeEvidence(identity: identity, verified: verified)
        return "Remote worker joined as \(identity.credentials.identity.peerID.rawValue)"
    }

    private func makeNode(
        invitation: PairingInvitation,
        identity: SandboxNodeIdentity,
        backend: any InferenceBackend,
        status: SystemStatusProvider,
        network: SandboxWiFiNetwork
    ) throws -> InferPeerNode {
        try InferPeerNode(
            configuration: InferPeerNodeConfiguration(roles: [.worker]),
            dependencies: InferPeerDependencies(
                identity: identity.provider,
                transport: SandboxClusterSupport.makeTransport(
                    identity: identity,
                    clusterID: invitation.coordinator.clusterID,
                    endpoint: invitation.coordinator.endpoint,
                    roles: [.worker],
                    interfaceName: network.interfaceName
                ),
                discovery: BonjourPeerDiscovery(),
                status: status,
                optional: InferPeerOptionalServices(inferenceBackend: backend)
            )
        )
    }

    private func writeEvidence(
        identity: SandboxNodeIdentity,
        verified: SandboxVerifiedModelArtifact
    ) throws {
        try SandboxEvidenceStore.writeCluster([
            "PASS\tPhysical-device worker joined",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "peer_id\t\(identity.credentials.identity.peerID.rawValue)",
            "model\t\(SandboxPinnedModel.modelID)",
            "revision\t\(SandboxPinnedModel.revision)",
            "weights_sha256\t\(verified.weightsSHA256)",
        ])
    }

    func setParticipation(_ participation: WorkerParticipationState) async {
        guard let retainedNode else { return }
        try? await retainedNode.setParticipation(participation)
        try? SandboxEvidenceStore.writeLifecycle([
            "PASS\tWorker lifecycle participation updated",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "role\tworker",
            "participation\t\(participation.rawValue)",
        ])
    }
}
