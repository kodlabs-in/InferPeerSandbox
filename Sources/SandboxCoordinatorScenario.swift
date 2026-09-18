import Foundation
import InferPeer
import InferPeerCore
import InferPeerDiscovery
import InferPeerInference
import InferPeerMLX
import InferPeerProtocol
import InferPeerStorage
import InferPeerTelemetry

private struct SandboxCoordinatorContext: Sendable {
    let identity: SandboxNodeIdentity
    let endpoint: PeerEndpoint
    let clusterID: ClusterID
    let incarnationID: CoordinatorIncarnationID
    let verifiedModel: SandboxVerifiedModelArtifact
    let backend: MLXInferenceBackend
    let status: SystemStatusProvider
    let network: SandboxWiFiNetwork
}

actor SandboxCoordinatorScenario {
    private var retainedNode: InferPeerNode?
    private var retainedStatus: SystemStatusProvider?
    private var retainedEngine: CoordinatorEngine?

    func start(
        modelURL: URL,
        environment: [String: String],
        network: SandboxWiFiNetwork
    ) async throws -> String {
        let context = try await makeContext(
            modelURL: modelURL,
            environment: environment,
            network: network
        )
        let node = try await makeNode(context)
        try await node.start()
        retainedNode = node
        retainedStatus = context.status
        try await writeInvitations(context)
        try writeEvidence(context)
        return "Coordinator listening at \(context.endpoint.host):\(context.endpoint.port)"
    }

    private func makeContext(
        modelURL: URL,
        environment: [String: String],
        network: SandboxWiFiNetwork
    ) async throws -> SandboxCoordinatorContext {
        let host = environment["INFERPEER_COORDINATOR_HOST"] ?? network.ipv4Address
        let endpoint = try PeerEndpoint(host: host, port: SandboxClusterSupport.port)
        let clusterID = try SandboxClusterSupport.identifier(
            ClusterID.self,
            value: "cluster-physical-validation"
        )
        let identity = try await SandboxClusterSupport.makeIdentity(
            approvedRoles: [.caller, .worker]
        )
        let incarnationID = try SandboxClusterSupport.identifier(
            CoordinatorIncarnationID.self,
            value: "coordinator-\(UUID().uuidString.lowercased())"
        )
        let verifiedModel = try await SandboxModelArtifactFactory.make(at: modelURL)
        let backend = MLXInferenceBackend()
        try await backend.loadModel(verifiedModel.artifact)
        let status = try SystemStatusProvider(
            participation: .available,
            models: [
                try SandboxClusterSupport.modelSnapshot(
                    verifiedModel.artifact.descriptor.reference
                )
            ]
        )
        return SandboxCoordinatorContext(
            identity: identity,
            endpoint: endpoint,
            clusterID: clusterID,
            incarnationID: incarnationID,
            verifiedModel: verifiedModel,
            backend: backend,
            status: status,
            network: network
        )
    }

    private func makeNode(_ context: SandboxCoordinatorContext) async throws -> InferPeerNode {
        let advertiser = try await MainActor.run {
            try BonjourServiceAdvertiser(
                serviceName: "InferPeer Physical Validation",
                port: SandboxClusterSupport.port
            )
        }
        let engine = try makeEngine(context)
        retainedEngine = engine
        return try InferPeerNode(
            configuration: InferPeerNodeConfiguration(
                roles: [.coordinator],
                coordinatorEndpoint: context.endpoint
            ),
            dependencies: InferPeerDependencies(
                identity: context.identity.provider,
                transport: try SandboxClusterSupport.makeTransport(
                    identity: context.identity,
                    clusterID: context.clusterID,
                    endpoint: context.endpoint,
                    roles: [.coordinator],
                    interfaceName: context.network.interfaceName,
                    incarnationID: context.incarnationID
                ),
                discovery: BonjourPeerDiscovery(),
                status: context.status,
                optional: InferPeerOptionalServices(
                    coordinator: engine,
                    advertisement: BonjourCoordinatorAdvertisement(advertiser: advertiser)
                )
            )
        )
    }

    private func makeEngine(_ context: SandboxCoordinatorContext) throws -> CoordinatorEngine {
        let clock = SystemCoreClock()
        let localWorker = InProcessCoordinatorWorker(
            peerID: context.identity.credentials.identity.peerID,
            statusProvider: context.status,
            backend: context.backend,
            clock: clock
        )
        let configuration = CoordinatorConfiguration.standard(
            clusterID: context.clusterID,
            coordinatorID: context.identity.credentials.identity.peerID,
            incarnationID: context.incarnationID
        )
        let jobStore = try SQLiteJobStore(
            databaseURL: SandboxEvidenceStore.directory()
                .appendingPathComponent("cluster-jobs.sqlite")
        )
        return CoordinatorEngine(
            configuration: configuration,
            store: jobStore,
            scheduler: DefaultSchedulerPolicy(configuration: .standard),
            clock: clock,
            localWorker: localWorker
        )
    }

    private func writeInvitations(_ context: SandboxCoordinatorContext) async throws {
        let coordinator = PairingCoordinator(
            clusterID: context.clusterID,
            endpoint: context.endpoint,
            certificateFingerprint: context.identity.credentials.identity.certificateFingerprint
        )
        let caller = try await context.identity.invitationAuthority.issue(for: coordinator)
        let worker = try await context.identity.invitationAuthority.issue(for: coordinator)
        try SandboxClusterSupport.writeInvitation(
            caller,
            filename: "cluster-caller-invitation.json"
        )
        try SandboxClusterSupport.writeInvitation(
            worker,
            filename: "cluster-worker-invitation.json"
        )
    }

    private func writeEvidence(_ context: SandboxCoordinatorContext) throws {
        try SandboxEvidenceStore.writeCluster([
            "PASS\tPhysical-device coordinator started",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "endpoint\t\(context.endpoint.host):\(context.endpoint.port)",
            "peer_id\t\(context.identity.credentials.identity.peerID.rawValue)",
            "model\t\(SandboxPinnedModel.modelID)",
            "revision\t\(SandboxPinnedModel.revision)",
            "weights_sha256\t\(context.verifiedModel.weightsSHA256)",
        ])
    }

    func setParticipation(_ participation: WorkerParticipationState) async {
        guard let retainedStatus, let retainedEngine else { return }
        await retainedStatus.setParticipation(participation)
        await retainedEngine.refreshLocalWorkerStatus()
        try? SandboxEvidenceStore.writeLifecycle([
            "PASS\tCoordinator lifecycle participation updated",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "role\tcoordinator",
            "participation\t\(participation.rawValue)",
        ])
    }
}
