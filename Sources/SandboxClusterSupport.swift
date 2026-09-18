import Darwin
import Foundation
import InferPeer
import InferPeerCore
import InferPeerGRPC
import InferPeerInference
import InferPeerProtocol
import InferPeerSecurity
import InferPeerStorage
import Network

enum SandboxClusterRole: String, Sendable {
    case coordinator
    case caller
    case worker
}

enum SandboxClusterError: Error, LocalizedError, Sendable {
    case invitationMissing
    case invalidInvitation
    case invalidWorkerID
    case invalidRunID
    case invalidCheckpoint
    case localAddressUnavailable
    case requestDidNotComplete
    case nonMonotonicCursor

    var errorDescription: String? {
        switch self {
        case .invitationMissing:
            "The physical-device invitation file is missing."
        case .invalidInvitation:
            "The physical-device invitation is malformed."
        case .invalidWorkerID:
            "The requested remote worker identifier is invalid."
        case .invalidRunID:
            "The validation run identifier is invalid."
        case .invalidCheckpoint:
            "The coordinator restart checkpoint is invalid."
        case .localAddressUnavailable:
            "The selected Wi-Fi interface has no local IPv4 address."
        case .requestDidNotComplete:
            "The physical-device request ended without a completion event."
        case .nonMonotonicCursor:
            "The physical-device replay cursor did not increase monotonically."
        }
    }
}

struct SandboxInvitationRecord: Codable, Sendable {
    let invitationID: String
    let clusterID: String
    let coordinatorHost: String
    let coordinatorPort: UInt16
    let coordinatorFingerprint: Data
    let expiresAt: Date
    let proof: Data

    init(_ invitation: PairingInvitation) {
        invitationID = invitation.invitationID.rawValue
        clusterID = invitation.coordinator.clusterID.rawValue
        coordinatorHost = invitation.coordinator.endpoint.host
        coordinatorPort = invitation.coordinator.endpoint.port
        coordinatorFingerprint = invitation.coordinator.certificateFingerprint.bytes
        expiresAt = invitation.expiresAt
        proof = invitation.proof
    }

    func invitation() throws -> PairingInvitation {
        guard let invitationID = InvitationID(rawValue: invitationID),
            let clusterID = ClusterID(rawValue: clusterID)
        else {
            throw SandboxClusterError.invalidInvitation
        }
        let endpoint = try PeerEndpoint(host: coordinatorHost, port: coordinatorPort)
        let coordinator = PairingCoordinator(
            clusterID: clusterID,
            endpoint: endpoint,
            certificateFingerprint: try CertificateFingerprint(bytes: coordinatorFingerprint)
        )
        return PairingInvitation(
            invitationID: invitationID,
            coordinator: coordinator,
            expiresAt: expiresAt,
            proof: proof
        )
    }
}

struct SandboxNodeIdentity: Sendable {
    let provider: DefaultIdentityProvider
    let credentials: DeviceCredentials
    let invitationAuthority: PairingInvitationAuthority
}

struct SandboxWiFiNetwork: Sendable {
    let interfaceName: String
    let ipv4Address: String
}

enum SandboxClusterSupport {
    static let port: UInt16 = 8_443
    static let invitationFilename = "cluster-invitation.json"

    static func makeIdentity(approvedRoles: Set<NodeRole>) async throws -> SandboxNodeIdentity {
        let directory = try SandboxEvidenceStore.directory()
        let secretStore = try KeychainSecretStore(
            service: "in.kodlabs.inferpeer.sandbox.cluster"
        )
        let manager = DeviceIdentityManager(secretStore: secretStore)
        let authority = PairingInvitationAuthority(secretStore: secretStore)
        let peerStore = try SQLitePeerStore(
            databaseURL: directory.appendingPathComponent("cluster-peers.sqlite")
        )
        let provider = try DefaultIdentityProvider(
            identityManager: manager,
            invitationAuthority: authority,
            trustRepository: peerStore,
            approvedRoles: approvedRoles
        )
        return SandboxNodeIdentity(
            provider: provider,
            credentials: try await manager.credentials(),
            invitationAuthority: authority
        )
    }

    static func transportCredentials(
        _ credentials: DeviceCredentials
    ) throws -> GRPCDeviceCredentials {
        try GRPCDeviceCredentials(
            identity: credentials.identity,
            certificateDER: credentials.certificateDER,
            privateKeyDER: credentials.privateKeyDER
        )
    }

    static func makeTransport(
        identity: SandboxNodeIdentity,
        clusterID: ClusterID,
        endpoint: PeerEndpoint,
        roles: Set<NodeRole>,
        interfaceName: String,
        incarnationID: CoordinatorIncarnationID? = nil
    ) throws -> GRPCPeerTransport {
        let policy = try GRPCNetworkPolicy(
            interfaceName: interfaceName,
            allowedEndpoints: [endpoint]
        )
        let configuration = try GRPCTransportConfiguration(
            clusterID: clusterID,
            credentials: transportCredentials(identity.credentials),
            enabledRoles: roles,
            coordinatorIncarnationID: incarnationID,
            coordinatorPins: [],
            certificateVerifier: certificateVerifier(),
            sessionAuthorizer: InferPeerSessionAuthorizer.make(
                identityProvider: identity.provider
            ),
            networkPolicy: policy
        )
        return GRPCPeerTransport(configuration: configuration)
    }

    static func modelSnapshot(_ reference: ModelReference) throws -> WorkerModelSnapshot {
        try WorkerModelSnapshot(
            model: reference,
            isLoaded: true,
            measuredMemoryBytes: nil,
            estimatedLoadDuration: nil
        )
    }

    static func certificateVerifier() -> GRPCCertificateVerifier {
        let verifier = CertificateIdentityVerifier()
        return GRPCCertificateVerifier { certificate, fingerprint in
            try verifier.verify(
                certificateDER: certificate,
                expectedFingerprint: fingerprint
            )
        }
    }

    static func invitation() throws -> PairingInvitation {
        let url = try SandboxEvidenceStore.directory()
            .appendingPathComponent(invitationFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SandboxClusterError.invitationMissing
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SandboxInvitationRecord.self, from: Data(contentsOf: url))
            .invitation()
    }

    static func writeInvitation(
        _ invitation: PairingInvitation,
        filename: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SandboxInvitationRecord(invitation))
        try data.write(
            to: SandboxEvidenceStore.directory().appendingPathComponent(filename),
            options: .atomic
        )
    }

    static func identifier<Domain>(
        _ type: ProtocolIdentifier<Domain>.Type,
        value: String
    ) throws -> ProtocolIdentifier<Domain> {
        guard let identifier = ProtocolIdentifier<Domain>(rawValue: value) else {
            throw SandboxClusterError.invalidInvitation
        }
        return identifier
    }

    static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    static func wifiNetwork() async throws -> SandboxWiFiNetwork {
        let interfaceName = try await wifiInterfaceName()
        return try SandboxWiFiNetwork(
            interfaceName: interfaceName,
            ipv4Address: localIPv4Address(interfaceName: interfaceName)
        )
    }

    private static func wifiInterfaceName() async throws -> String {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let queue = DispatchQueue(label: "in.kodlabs.inferpeer.sandbox-wifi-path")
        monitor.start(queue: queue)
        defer { monitor.cancel() }
        for _ in 0..<20 {
            if let name = activeWiFiInterfaceName(in: monitor.currentPath) {
                return name
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SandboxClusterError.localAddressUnavailable
    }

    private static func activeWiFiInterfaceName(in path: NWPath) -> String? {
        guard path.status == .satisfied else { return nil }
        return path.availableInterfaces.first { $0.type == .wifi }?.name
    }

    private static func localIPv4Address(interfaceName: String) throws -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            throw SandboxClusterError.localAddressUnavailable
        }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard
                interfaceName.withCString({ strcmp(interface.pointee.ifa_name, $0) == 0 }),
                let address = interface.pointee.ifa_addr,
                address.pointee.sa_family == UInt8(AF_INET),
                let result = ipv4String(address)
            else {
                continue
            }
            return result
        }
        throw SandboxClusterError.localAddressUnavailable
    }

    private static func ipv4String(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }
}
