import Foundation
import InferPeer
import InferPeerApple
import InferPeerCore
import InferPeerDiscovery
import InferPeerGRPC
import InferPeerInference
import InferPeerModelStore
import InferPeerSecurity

actor SandboxClientRuntime {
  private var facadeValue: InferPeer?

  func facade() throws -> InferPeer {
    if let facadeValue { return facadeValue }
    let profile = try AppleDeviceProfiler(
      storageURL: FileManager.default.temporaryDirectory
    ).snapshot()
    let secretStore = try KeychainSecretStore(service: keychainService)
    let credentialStore = DirectResourceCredentialVault(secretStore: secretStore)
    let verifier = CertificateIdentityVerifier()
    let endpointValidator = LANEndpointValidator()
    let factory = try PosixDirectResourceRPCFactory(
      certificateVerifier: GRPCCertificateVerifier { certificate, fingerprint in
        try verifier.verify(
          certificateDER: certificate,
          expectedFingerprint: fingerprint
        )
      },
      endpointValidator: { endpoint in
        _ = try endpointValidator.validate(endpoint)
      }
    )
    let sessions = DirectGRPCSessionManager(
      credentialStore: credentialStore,
      connectionFactory: factory,
      wireCodec: DefaultDirectResourceWireCodec()
    )
    let facade = try InferPeer(
      configuration: InferPeerConfiguration(
        localResource: LocalResourceConfiguration(
          displayName: "InferPeer Sandbox",
          platform: profile.platform
        ),
        discovery: BonjourResourceDiscovery(),
        sessionManager: sessions
      )
    )
    facadeValue = facade
    return facade
  }

  func pair(code: String) async throws -> ResourceID {
    guard let data = Data(base64Encoded: code.trimmingCharacters(in: .whitespacesAndNewlines))
    else {
      throw InferPeerError(code: .invalidRequest, isRetryable: false)
    }
    let invitation = try ResourcePairingInvitationCodec.decode(data)
    let peer = try facade()
    return try await peer.pair(invitation)
  }

  func modelNames() throws -> [ModelKey: String] {
    let bundle = try InferPeerStarterCatalog.load()
    let catalog = try ModelCatalogVerifier(
      trustedKeys: bundle.trustedCatalogKeys
    ).verify(bundle.signedCatalog)
    var names: [ModelKey: String] = [:]
    for entry in catalog.entries {
      let key = try ModelKey(
        modelID: entry.metadata.key.modelID,
        revision: entry.metadata.key.version
      )
      names[key] = entry.metadata.displayName
    }
    return names
  }

  func stop() async {
    await facadeValue?.stop()
    facadeValue = nil
  }

  private var keychainService: String {
    (Bundle.main.bundleIdentifier ?? "in.kodlabs.inferpeer.sandbox") + ".credentials"
  }
}
