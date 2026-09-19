import Foundation
import InferPeer
import InferPeerApple
import InferPeerCore
import InferPeerDiscovery
import InferPeerGRPC
import InferPeerModelStore
import InferPeerSecurity
import SwiftUI

#if os(iOS)
  import UIKit
#else
  import AppKit
#endif

private struct HostComposition {
  let invitations: DirectResourceInvitationAuthority
  let resourceID: ResourceID
  let endpoint: PeerEndpoint
  let fingerprint: CertificateFingerprint
  let exposure: PosixDirectResourceExposure
}

@MainActor
final class ResourceHostController: ObservableObject {
  @Published private(set) var catalog: [AppCatalogModel] = []
  @Published private(set) var installed: [AppInstalledModel] = []
  @Published private(set) var status = "Preparing this resource…"
  @Published private(set) var invitationCode = ""
  @Published private(set) var installProgress: ModelInstallationProgress?
  @Published private(set) var isSharing = false
  @Published private(set) var installingModelID: ModelCatalogKey?
  @Published var sharingRequested = true

  let models = AppModelEnvironment()
  private var invitationAuthority: DirectResourceInvitationAuthority?
  private var hostResourceID: ResourceID?
  private var endpoint: PeerEndpoint?
  private var fingerprint: CertificateFingerprint?
  private var exposure: PosixDirectResourceExposure?
  private var exposureHandle: ExposureHandle?
  private var initialized = false

  func enteredForeground() async {
    do {
      try await initialize()
      await refreshModels()
      if sharingRequested { try await startSharing() }
    } catch {
      status = "Resource startup failed: \(String(reflecting: error))"
    }
  }

  func enteredBackground() {
    Task { await stopSharing(backgrounded: true) }
  }

  func setSharing(_ enabled: Bool) {
    sharingRequested = enabled
    Task {
      if enabled {
        do { try await startSharing() } catch {
          status = "Sharing failed: \(error.localizedDescription)"
        }
      } else {
        await stopSharing(backgrounded: false)
      }
    }
  }

  func renewInvitation() {
    Task {
      do { try await issueInvitation() } catch {
        status = "Invitation failed: \(error.localizedDescription)"
      }
    }
  }

  func install(_ model: AppCatalogModel) {
    guard installingModelID == nil, model.support.isInstallable else { return }
    installingModelID = model.key
    installProgress = nil
    status = "Starting package-managed download…"
    Task { [weak self] in _ = await self?.performInstall(model) }
  }

  func remove(_ model: AppInstalledModel) {
    Task {
      do {
        try await models.remove(model.key)
        await refreshModels()
        status = "Removed \(model.name)."
      } catch {
        status = "Removal failed: \(error.localizedDescription)"
      }
    }
  }

  func copyInvitation() {
    #if os(iOS)
      UIPasteboard.general.string = invitationCode
    #else
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(invitationCode, forType: .string)
    #endif
    status = "One-time invitation copied."
  }

  #if DEBUG || INFERPEER_PHYSICAL_TESTING
    func installConfiguredPhysicalTestModels() async {
      let value = ProcessInfo.processInfo.environment["INFERPEER_HOST_INSTALL_MODEL_IDS"]
      #if INFERPEER_PHYSICAL_TESTING
        let fallbackModelIDs = [
          "mlx-community-qwen3-0.6b-4bit",
          "ggml-smolvlm2-500m-q8-gguf",
        ]
      #else
        let fallbackModelIDs: [String] = []
      #endif
      let modelIDs = value?.split(separator: ",").map(String.init) ?? fallbackModelIDs
      guard !modelIDs.isEmpty else { return }
      for modelID in modelIDs {
        guard let model = catalog.first(where: { $0.key.modelID.rawValue == modelID }) else {
          status = "Physical setup could not find \(modelID)."
          return
        }
        if installed.contains(where: { $0.matches(model.key) }) { continue }
        installingModelID = model.key
        guard await performInstall(model) else { return }
      }
      await refreshModels()
      guard
        modelIDs.allSatisfy({ modelID in
          installed.contains(where: { $0.key.modelID.rawValue == modelID })
        })
      else {
        status = "Physical setup did not install every requested model."
        return
      }
      copyInvitation()
      status = "Physical text and vision models are ready; invitation copied."
    }
  #endif
}

extension ResourceHostController {
  fileprivate func initialize() async throws {
    guard !initialized else { return }
    let store = try await models.store()
    let device = try await models.snapshot()
    let secrets = try KeychainSecretStore(service: keychainService)
    let composition = try await makeComposition(
      store: store,
      device: device,
      secrets: secrets
    )
    invitationAuthority = composition.invitations
    hostResourceID = composition.resourceID
    endpoint = composition.endpoint
    fingerprint = composition.fingerprint
    exposure = composition.exposure
    initialized = true
  }

  fileprivate func makeComposition(
    store: InferPeerModelStore,
    device: AppleDeviceProfileSnapshot,
    secrets: KeychainSecretStore
  ) async throws -> HostComposition {
    let identity = try await DeviceIdentityManager(secretStore: secrets).credentials()
    let invitations = DirectResourceInvitationAuthority(secretStore: secrets)
    let access = try DirectResourceAccessController(
      secretStore: secrets,
      invitations: invitations
    )
    let resourceID = ResourceID(rawValue: identity.identity.peerID.rawValue)
    let endpoint = try LocalNetworkEndpoint.current()
    let service = try makeService(
      store: store,
      device: device,
      access: access,
      resourceID: resourceID
    )
    let credentials = try GRPCDeviceCredentials(
      identity: identity.identity,
      certificateDER: identity.certificateDER,
      privateKeyDER: identity.privateKeyDER
    )
    let exposure = try PosixDirectResourceExposure(
      endpoint: endpoint,
      credentials: credentials,
      service: service,
      advertise: Self.advertiser(name: resourceName, resourceID: resourceID)
    )
    return HostComposition(
      invitations: invitations,
      resourceID: resourceID,
      endpoint: endpoint,
      fingerprint: identity.identity.certificateFingerprint,
      exposure: exposure
    )
  }

  fileprivate func makeService(
    store: InferPeerModelStore,
    device: AppleDeviceProfileSnapshot,
    access: DirectResourceAccessController,
    resourceID: ResourceID
  ) throws -> DirectResourceGRPCService {
    let handler = try DirectResourceHostHandler(
      resourceID: resourceID,
      displayName: resourceName,
      platform: device.platform,
      telemetry: device.telemetry,
      store: store,
      deviceProfile: device.modelStoreProfile,
      accessController: access,
      assetRoot: try assetRoot()
    )
    return try DirectResourceGRPCService(
      handler: handler,
      authorizer: DirectResourceRequestAuthorizer { credential in
        (try await access.authorize(credential)).rawValue
      }
    )
  }

  fileprivate func startSharing() async throws {
    guard !isSharing, let exposure else { return }
    exposureHandle = try await exposure.start(configuration: .default)
    isSharing = true
    try await issueInvitation()
    status = "Foreground resource ready at \(endpointLabel)."
  }

  fileprivate func stopSharing(backgrounded: Bool) async {
    await exposureHandle?.stop()
    exposureHandle = nil
    invitationCode = ""
    isSharing = false
    status =
      backgrounded
      ? "Paused because this app left the foreground."
      : "Resource sharing is off."
  }

  fileprivate func issueInvitation() async throws {
    guard isSharing, let invitationAuthority, let hostResourceID,
      let endpoint, let fingerprint
    else {
      throw InferPeerError(code: .resourceUnavailable, isRetryable: true)
    }
    let invitation = try await invitationAuthority.issue(
      resourceID: hostResourceID,
      endpoint: endpoint,
      certificateFingerprint: fingerprint
    )
    invitationCode = try ResourcePairingInvitationCodec.encode(invitation)
      .base64EncodedString()
  }

  fileprivate func refreshModels() async {
    do {
      async let catalog = models.catalog()
      async let installed = models.installedModels()
      self.catalog = try await catalog
      self.installed = try await installed
    } catch {
      status = "Model library failed: \(error.localizedDescription)"
    }
  }

  fileprivate func performInstall(_ model: AppCatalogModel) async -> Bool {
    do {
      let installation = try await models.install(model)
      for try await event in installation.events { apply(event) }
      await refreshModels()
      status = "\(model.displayName) is verified and ready to share."
      installingModelID = nil
      installProgress = nil
      return true
    } catch {
      status = "Installation failed: \(error.localizedDescription)"
      installingModelID = nil
      installProgress = nil
      return false
    }
  }

  fileprivate func apply(_ event: ModelInstallationEvent) {
    switch event {
    case .state(let state): status = "Model download: \(String(describing: state))"
    case .progress(let progress):
      installProgress = progress
      status = "Downloading \(progress.filePath)"
    case .installed(let model): status = "Verified \(model.manifest.name)."
    }
  }

  fileprivate var endpointLabel: String {
    guard let endpoint else { return "Wi-Fi" }
    return "\(endpoint.host):\(endpoint.port)"
  }

  fileprivate var keychainService: String {
    (Bundle.main.bundleIdentifier ?? "in.kodlabs.inferpeer.resource") + ".host"
  }

  fileprivate var resourceName: String {
    #if os(iOS)
      UIDevice.current.name
    #else
      Host.current().localizedName ?? "This Mac"
    #endif
  }

  fileprivate func assetRoot() throws -> URL {
    try FileManager.default.url(
      for: .cachesDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("InferPeerAssets", isDirectory: true)
  }

  fileprivate static func advertiser(
    name: String,
    resourceID: ResourceID
  ) -> PosixDirectResourceExposure.Advertise {
    { endpoint in
      let advertiser = try await MainActor.run {
        try BonjourServiceAdvertiser(serviceName: name, port: endpoint.port)
      }
      let metadata = try DirectBonjourAdvertisementMetadata(
        installationHint: Data(resourceID.rawValue.utf8.prefix(64)),
        capabilityVersion: 1
      )
      try await MainActor.run { try advertiser.startDirect(metadata: metadata) }
      return { await MainActor.run { advertiser.stop() } }
    }
  }
}
