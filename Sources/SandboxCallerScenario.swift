import Foundation
import InferPeer
import InferPeerCore
import InferPeerDiscovery
import InferPeerInference
import InferPeerProtocol
import InferPeerStorage
import InferPeerTelemetry

struct SandboxClusterRequestMetrics: Sendable {
    let acceptanceSeconds: Double
    let outputCharacters: Int
    let eventCount: Int
    let attemptCount: Int
    let interruptionCount: Int
    let interruptionRecoverySeconds: Double?
    let model: ModelReference
}

enum SandboxCallerFlow: Sendable {
    case stream
    case retry
    case reconnect
    case restartSeed
    case restartResume
    case acceptance
}

struct SandboxCallerRequestProfile: Sendable {
    let flow: SandboxCallerFlow
    let name: String
    let prompt: String
    let maximumOutputTokens: UInt32
    let defaultTargetDescription: String

    static func make(environment: [String: String]) -> Self {
        switch environment["INFERPEER_VALIDATION_SCENARIO"] {
        case "retry":
            return Self(
                flow: .retry,
                name: "retry",
                prompt: Self.longPrompt,
                maximumOutputTokens: 512,
                defaultTargetDescription: "scheduler-selected-retry"
            )
        case "reconnect":
            return longProfile(flow: .reconnect, name: "reconnect")
        case "restart-seed":
            return longProfile(flow: .restartSeed, name: "restart-seed")
        case "restart-resume":
            return longProfile(flow: .restartResume, name: "restart-resume")
        case "acceptance":
            return Self(
                flow: .acceptance,
                name: "acceptance",
                prompt: "Reply with exactly: OK",
                maximumOutputTokens: 8,
                defaultTargetDescription: "coordinator-local-worker"
            )
        default:
            return Self(
                flow: .stream,
                name: "stream",
                prompt: "Reply with exactly: InferPeer network OK",
                maximumOutputTokens: 32,
                defaultTargetDescription: "coordinator-local-worker"
            )
        }
    }

    private static let longPrompt =
        "Write a numbered list from 1 to 200, one item per line, without stopping early."

    private static func longProfile(flow: SandboxCallerFlow, name: String) -> Self {
        Self(
            flow: flow,
            name: name,
            prompt: longPrompt,
            maximumOutputTokens: 512,
            defaultTargetDescription: "coordinator-local-worker"
        )
    }
}

struct SandboxReplayCheckpoint: Codable, Sendable {
    let requestID: String
    let cursor: UInt64
}

struct SandboxStreamPrefix: Sendable {
    let requestID: RequestID
    let cursor: UInt64
    let eventCount: Int
}

actor SandboxCallerScenario {
    func run(
        environment: [String: String],
        network: SandboxWiFiNetwork
    ) async throws -> String {
        let invitation = try SandboxClusterSupport.invitation()
        let identity = try await SandboxClusterSupport.makeIdentity(approvedRoles: [.caller])
        let outboxURL = try outboxDatabaseURL(environment: environment)
        let node = try makeNode(
            invitation: invitation,
            identity: identity,
            network: network,
            outboxURL: outboxURL
        )
        try await node.start()
        _ = try await node.join(invitation)
        let targetWorker = try requestedWorker(environment["INFERPEER_ALLOWED_WORKER_ID"])
        let profile = SandboxCallerRequestProfile.make(environment: environment)
        let result = try await run(
            profile: profile,
            node: node,
            invitation: invitation,
            targetWorker: targetWorker
        )
        await node.stop()
        return result
    }

    private func run(
        profile: SandboxCallerRequestProfile,
        node: InferPeerNode,
        invitation: PairingInvitation,
        targetWorker: PeerID?
    ) async throws -> String {
        switch profile.flow {
        case .stream, .retry:
            let metrics = try await runRequest(
                node: node,
                targetWorker: targetWorker,
                profile: profile
            )
            try writeEvidence(metrics, targetWorker: targetWorker, profile: profile)
            return "Caller completed \(metrics.eventCount) streamed events"
        case .reconnect:
            return try await runReconnect(
                node: node,
                invitation: invitation,
                targetWorker: targetWorker,
                profile: profile
            )
        case .restartSeed:
            return try await seedCoordinatorRestart(
                node: node,
                targetWorker: targetWorker,
                profile: profile
            )
        case .restartResume:
            return try await resumeAfterCoordinatorRestart(node: node)
        case .acceptance:
            return try await runAcceptanceBenchmark(
                node: node,
                targetWorker: targetWorker,
                profile: profile
            )
        }
    }

    private func makeNode(
        invitation: PairingInvitation,
        identity: SandboxNodeIdentity,
        network: SandboxWiFiNetwork,
        outboxURL: URL
    ) throws -> InferPeerNode {
        let status = try SystemStatusProvider(participation: .unavailable)
        let outbox = try SQLiteOutboxStore(databaseURL: outboxURL)
        return try InferPeerNode(
            configuration: InferPeerNodeConfiguration(roles: [.caller]),
            dependencies: InferPeerDependencies(
                identity: identity.provider,
                transport: SandboxClusterSupport.makeTransport(
                    identity: identity,
                    clusterID: invitation.coordinator.clusterID,
                    endpoint: invitation.coordinator.endpoint,
                    roles: [.caller],
                    interfaceName: network.interfaceName
                ),
                discovery: BonjourPeerDiscovery(),
                status: status,
                optional: InferPeerOptionalServices(callerOutbox: outbox)
            )
        )
    }

    private func outboxDatabaseURL(environment: [String: String]) throws -> URL {
        let filename: String
        if let runID = environment["INFERPEER_VALIDATION_RUN_ID"] {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard
                (1...64).contains(runID.utf8.count),
                runID.unicodeScalars.allSatisfy(allowed.contains)
            else {
                throw SandboxClusterError.invalidRunID
            }
            filename = "cluster-outbox-\(runID).sqlite"
        } else {
            filename = "cluster-outbox.sqlite"
        }
        return try SandboxEvidenceStore.directory().appendingPathComponent(filename)
    }

    func runRequest(
        node: InferPeerNode,
        targetWorker: PeerID?,
        profile: SandboxCallerRequestProfile
    ) async throws -> SandboxClusterRequestMetrics {
        let started = ContinuousClock.now
        let handle = try await node.submit(
            try request(allowedWorker: targetWorker, profile: profile)
        )
        let stream = try await node.events(requestID: handle.requestID)
        return try await collect(stream, node: node, started: started)
    }

    private func requestedWorker(_ value: String?) throws -> PeerID? {
        guard let value else { return nil }
        guard let workerID = PeerID(rawValue: value) else {
            throw SandboxClusterError.invalidWorkerID
        }
        return workerID
    }

    func request(
        allowedWorker: PeerID?,
        profile: SandboxCallerRequestProfile
    ) throws -> TextGenerationRequest {
        let reference = try ModelReference(
            modelID: SandboxClusterSupport.identifier(
                ModelID.self,
                value: SandboxPinnedModel.modelID
            ),
            revision: SandboxPinnedModel.revision
        )
        let context = try ConversationContext(
            conversationID: SandboxClusterSupport.identifier(
                ConversationID.self,
                value: "conversation-\(UUID().uuidString.lowercased())"
            ),
            revision: 1,
            messages: [
                try TextMessage(role: .user, text: profile.prompt)
            ]
        )
        let options = try GenerationOptions(
            modelRequirement: .exact(reference),
            maximumOutputTokens: profile.maximumOutputTokens,
            sampling: try SamplingOptions(temperature: 0),
            deadline: Date().addingTimeInterval(120)
        )
        return TextGenerationRequest(
            context: context,
            options: options,
            allowedWorkerIDs: allowedWorker.map { Set([$0]) } ?? []
        )
    }

}
