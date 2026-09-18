import Foundation
import InferPeer
import InferPeerCore
import InferPeerProtocol

extension SandboxCallerScenario {
    func runReconnect(
        node: InferPeerNode,
        invitation: PairingInvitation,
        targetWorker: PeerID?,
        profile: SandboxCallerRequestProfile
    ) async throws -> String {
        let prefix = try await consumePrefix(
            node: node,
            targetWorker: targetWorker,
            profile: profile
        )
        await node.leaveCoordinator()
        try await Task.sleep(for: .seconds(1))
        _ = try await node.join(invitation)
        let stream = try await node.events(requestID: prefix.requestID, after: prefix.cursor)
        let replay = try await collect(stream, node: node, started: ContinuousClock.now)
        try writeReplayEvidence(
            name: "disconnect-reconnect",
            checkpoint: prefix,
            replay: replay
        )
        return "Reconnect replay completed \(replay.eventCount) events"
    }

    func seedCoordinatorRestart(
        node: InferPeerNode,
        targetWorker: PeerID?,
        profile: SandboxCallerRequestProfile
    ) async throws -> String {
        let prefix = try await consumePrefix(
            node: node,
            targetWorker: targetWorker,
            profile: profile
        )
        try writeCheckpoint(prefix)
        await node.leaveCoordinator()
        try SandboxEvidenceStore.writeCluster([
            "PASS\tCoordinator restart seed committed",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "request_id\t\(prefix.requestID.rawValue)",
            "acknowledged_cursor\t\(prefix.cursor)",
            "events_before_restart\t\(prefix.eventCount)",
        ])
        return "Coordinator restart checkpoint saved at cursor \(prefix.cursor)"
    }

    func resumeAfterCoordinatorRestart(node: InferPeerNode) async throws -> String {
        let checkpoint = try readCheckpoint()
        guard let requestID = RequestID(rawValue: checkpoint.requestID) else {
            throw SandboxClusterError.invalidCheckpoint
        }
        let stream = try await node.events(requestID: requestID, after: checkpoint.cursor)
        let replay = try await collect(stream, node: node, started: ContinuousClock.now)
        let prefix = SandboxStreamPrefix(
            requestID: requestID,
            cursor: checkpoint.cursor,
            eventCount: 0
        )
        try writeReplayEvidence(
            name: "coordinator-restart",
            checkpoint: prefix,
            replay: replay
        )
        return "Coordinator restart replay completed \(replay.eventCount) events"
    }

    func consumePrefix(
        node: InferPeerNode,
        targetWorker: PeerID?,
        profile: SandboxCallerRequestProfile
    ) async throws -> SandboxStreamPrefix {
        let handle = try await node.submit(
            try request(allowedWorker: targetWorker, profile: profile)
        )
        let stream = try await node.events(requestID: handle.requestID)
        var latestCursor: UInt64?
        var eventCount = 0
        for try await event in stream {
            try Self.validateCursor(event.cursor, after: latestCursor)
            latestCursor = event.cursor
            eventCount += 1
            try await node.acknowledge(requestID: event.requestID, through: event.cursor)
            if eventCount >= 12 { break }
        }
        guard let latestCursor else { throw SandboxClusterError.requestDidNotComplete }
        return SandboxStreamPrefix(
            requestID: handle.requestID,
            cursor: latestCursor,
            eventCount: eventCount
        )
    }

    func writeCheckpoint(_ prefix: SandboxStreamPrefix) throws {
        let data = try JSONEncoder().encode(
            SandboxReplayCheckpoint(
                requestID: prefix.requestID.rawValue,
                cursor: prefix.cursor
            )
        )
        try data.write(
            to: SandboxEvidenceStore.directory()
                .appendingPathComponent("cluster-restart-checkpoint.json"),
            options: .atomic
        )
    }

    func readCheckpoint() throws -> SandboxReplayCheckpoint {
        try JSONDecoder().decode(
            SandboxReplayCheckpoint.self,
            from: Data(
                contentsOf: SandboxEvidenceStore.directory()
                    .appendingPathComponent("cluster-restart-checkpoint.json")
            )
        )
    }
}
