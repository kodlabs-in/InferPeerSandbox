import Foundation
import InferPeer
import InferPeerInference
import InferPeerProtocol

extension SandboxCallerScenario {
    func runAcceptanceBenchmark(
        node: InferPeerNode,
        targetWorker: PeerID?,
        profile: SandboxCallerRequestProfile
    ) async throws -> String {
        var samples: [Double] = []
        for _ in 0..<30 {
            let metrics = try await runRequest(
                node: node,
                targetWorker: targetWorker,
                profile: profile
            )
            samples.append(metrics.acceptanceSeconds)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let percentile95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        try SandboxEvidenceStore.writeCluster([
            "\(percentile95 < 0.250 ? "PASS" : "FAIL")\tIdle-LAN coordinator acceptance p95",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "samples\t\(sorted.count)",
            String(format: "minimum_seconds\t%.3f", sorted[0]),
            String(format: "median_seconds\t%.3f", median),
            String(format: "p95_seconds\t%.3f", percentile95),
            String(format: "maximum_seconds\t%.3f", sorted[sorted.count - 1]),
            "target_seconds\t0.250",
            "model\t\(SandboxPinnedModel.modelID)",
            "revision\t\(SandboxPinnedModel.revision)",
        ])
        return String(format: "Acceptance p95 %.3fs across %d samples", percentile95, sorted.count)
    }

    func collect(
        _ stream: InferPeerRequestEventStream,
        node: InferPeerNode,
        started: ContinuousClock.Instant
    ) async throws -> SandboxClusterRequestMetrics {
        try await withThrowingTaskGroup(of: SandboxClusterRequestMetrics.self) { group in
            group.addTask {
                try await Self.consume(stream, node: node, started: started)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(120))
                throw SandboxClusterError.requestDidNotComplete
            }
            defer { group.cancelAll() }
            guard let metrics = try await group.next() else {
                throw SandboxClusterError.requestDidNotComplete
            }
            return metrics
        }
    }

    static func consume(
        _ stream: InferPeerRequestEventStream,
        node: InferPeerNode,
        started: ContinuousClock.Instant
    ) async throws -> SandboxClusterRequestMetrics {
        var accumulator = SandboxStreamMetricsAccumulator(started: started)
        for try await event in stream {
            try await node.acknowledge(requestID: event.requestID, through: event.cursor)
            if let metrics = try accumulator.observe(event) {
                return metrics
            }
        }
        throw SandboxClusterError.requestDidNotComplete
    }

    static func validateCursor(_ cursor: UInt64, after previous: UInt64?) throws {
        guard previous.map({ cursor > $0 }) ?? true else {
            throw SandboxClusterError.nonMonotonicCursor
        }
    }

    func writeEvidence(
        _ metrics: SandboxClusterRequestMetrics,
        targetWorker: PeerID?,
        profile: SandboxCallerRequestProfile
    ) throws {
        try SandboxEvidenceStore.writeCluster([
            "PASS\tPhysical-device caller stream completed",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "scenario\t\(profile.name)",
            "target\t\(targetWorker?.rawValue ?? profile.defaultTargetDescription)",
            "maximum_output_tokens\t\(profile.maximumOutputTokens)",
            String(format: "acceptance_seconds\t%.3f", metrics.acceptanceSeconds),
            "events\t\(metrics.eventCount)",
            "attempts\t\(metrics.attemptCount)",
            "interruptions\t\(metrics.interruptionCount)",
            recoveryEvidence(metrics.interruptionRecoverySeconds),
            "output_characters\t\(metrics.outputCharacters)",
            "model\t\(metrics.model.modelID.rawValue)",
            "revision\t\(metrics.model.revision)",
        ])
    }

    private func recoveryEvidence(_ seconds: Double?) -> String {
        guard let seconds else { return "interruption_recovery_seconds\tnot_observed" }
        return String(format: "interruption_recovery_seconds\t%.3f", seconds)
    }

    func writeReplayEvidence(
        name: String,
        checkpoint: SandboxStreamPrefix,
        replay: SandboxClusterRequestMetrics
    ) throws {
        try SandboxEvidenceStore.writeCluster([
            "PASS\tPhysical-device \(name) replay completed",
            "timestamp\t\(ISO8601DateFormatter().string(from: Date()))",
            "request_id\t\(checkpoint.requestID.rawValue)",
            "acknowledged_cursor\t\(checkpoint.cursor)",
            "events_before_disconnect\t\(checkpoint.eventCount)",
            "replayed_events\t\(replay.eventCount)",
            "attempts_in_replay\t\(replay.attemptCount)",
            "interruptions_in_replay\t\(replay.interruptionCount)",
            recoveryEvidence(replay.interruptionRecoverySeconds),
            "model\t\(replay.model.modelID.rawValue)",
            "revision\t\(replay.model.revision)",
        ])
    }
}

private struct SandboxStreamMetricsAccumulator {
    let started: ContinuousClock.Instant
    private var acceptanceSeconds: Double?
    private var latestCursor: UInt64?
    private var eventCount = 0
    private var attemptIDs: Set<AttemptID> = []
    private var interruptionCount = 0
    private var interruptionStarted: ContinuousClock.Instant?
    private var interruptionRecoverySeconds: Double?

    mutating func observe(
        _ event: InferPeerRequestEvent
    ) throws -> SandboxClusterRequestMetrics? {
        try SandboxCallerScenario.validateCursor(event.cursor, after: latestCursor)
        latestCursor = event.cursor
        eventCount += 1
        if let attemptID = event.attemptID { attemptIDs.insert(attemptID) }
        recordAcceptance(event.payload)
        recordInterruption(event.payload)
        recordRecovery(event.payload)
        return try terminalMetrics(event.payload)
    }

    private mutating func recordAcceptance(_ payload: InferPeerRequestEventPayload) {
        guard case .accepted = payload, acceptanceSeconds == nil else { return }
        acceptanceSeconds = SandboxClusterSupport.seconds(started.duration(to: .now))
    }

    private mutating func recordInterruption(_ payload: InferPeerRequestEventPayload) {
        guard case .interrupted = payload else { return }
        interruptionCount += 1
        if interruptionStarted == nil { interruptionStarted = .now }
    }

    private mutating func recordRecovery(_ payload: InferPeerRequestEventPayload) {
        guard case .generation = payload,
            let interruptionStarted,
            interruptionRecoverySeconds == nil
        else {
            return
        }
        interruptionRecoverySeconds = SandboxClusterSupport.seconds(
            interruptionStarted.duration(to: .now)
        )
    }

    private func terminalMetrics(
        _ payload: InferPeerRequestEventPayload
    ) throws -> SandboxClusterRequestMetrics? {
        if case .failed(let error) = payload { throw error }
        guard case .generation(.completed(let result)) = payload else { return nil }
        return SandboxClusterRequestMetrics(
            acceptanceSeconds: acceptanceSeconds ?? 0,
            outputCharacters: result.fullText.count,
            eventCount: eventCount,
            attemptCount: attemptIDs.count,
            interruptionCount: interruptionCount,
            interruptionRecoverySeconds: interruptionRecoverySeconds,
            model: result.modelUsed
        )
    }
}
