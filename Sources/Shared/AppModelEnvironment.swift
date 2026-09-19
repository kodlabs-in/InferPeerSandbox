import Foundation
import InferPeerApple
import InferPeerCore
import InferPeerInference
import InferPeerLlama
import InferPeerMLX
import InferPeerModelStore

struct AppCatalogModel: Identifiable, Sendable {
  var id: ModelCatalogKey { key }
  let key: ModelCatalogKey
  let displayName: String
  let runtime: String
  let downloadBytes: UInt64
  let tasks: Set<InferenceTask>
  let support: ModelSupport

  var installationTask: InferenceTask {
    tasks.contains(.imageUnderstanding) ? .imageUnderstanding : .textGeneration
  }

  var supportTitle: String {
    switch support {
    case .supported: "Supported"
    case .experimental: "Experimental"
    case .unsupported: "Unsupported"
    }
  }
}

struct AppInstalledModel: Identifiable, Sendable {
  var id: ModelKey { key }
  let key: ModelKey
  let name: String
  let runtime: String
  let tasks: Set<InferenceTask>
  let installedBytes: UInt64
  let isLoaded: Bool

  func matches(_ catalogKey: ModelCatalogKey) -> Bool {
    key.modelID == catalogKey.modelID && key.revision == catalogKey.version
  }
}

actor AppModelEnvironment {
  private var storeValue: InferPeerModelStore?

  func store() async throws -> InferPeerModelStore {
    if let storeValue { return storeValue }
    let starter = try InferPeerStarterCatalog.load()
    let opened = try await InferPeerModelStore.open(
      configuration: InferPeerModelStoreConfiguration(
        rootDirectory: try modelRoot(),
        builtInCatalog: starter.signedCatalog,
        trustedCatalogKeys: starter.trustedCatalogKeys,
        runtimeAdapters: [MLXRuntimeAdapter(), LlamaRuntimeAdapter()]
      )
    )
    storeValue = opened
    return opened
  }

  func profile() throws -> ModelStoreDeviceProfile {
    try snapshot().modelStoreProfile
  }

  func snapshot() throws -> AppleDeviceProfileSnapshot {
    try AppleDeviceProfiler(storageURL: modelRoot()).snapshot()
  }

  func catalog() async throws -> [AppCatalogModel] {
    let store = try await store()
    let profile = try profile()
    var candidates: [ModelCatalogKey: ModelCandidate] = [:]
    for task in [InferenceTask.textGeneration, .imageUnderstanding] {
      for candidate in await store.catalog(task: task, resource: profile) {
        let current = candidates[candidate.entry.metadata.key]
        if current == nil || candidate.rank < (current?.rank ?? .max) {
          candidates[candidate.entry.metadata.key] = candidate
        }
      }
    }
    return candidates.values.map(Self.catalogModel).sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }

  func installedModels() async throws -> [AppInstalledModel] {
    let store = try await store()
    var result: [AppInstalledModel] = []
    for model in try await store.installedModels() {
      let status = try await store.status(of: model.key)
      result.append(
        AppInstalledModel(
          key: model.key,
          name: model.manifest.name,
          runtime: model.manifest.runtime.runtimeIdentifier,
          tasks: Set(model.manifest.capabilities.map(\.task)),
          installedBytes: model.installedByteCount,
          isLoaded: status?.isLoaded == true
        )
      )
    }
    return result.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  func install(_ model: AppCatalogModel) async throws -> ModelInstallation {
    let store = try await store()
    return try await store.install(
      model.key,
      task: model.installationTask,
      on: profile(),
      authorization: ModelDownloadAuthorization(resourceID: .local)
    )
  }

  func remove(_ model: ModelKey) async throws {
    let store = try await store()
    try await store.remove(model, policy: .unloadAndRemove)
  }

  private func modelRoot() throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let namespace = Bundle.main.bundleIdentifier ?? "in.kodlabs.inferpeer"
    return
      applicationSupport
      .appendingPathComponent(namespace, isDirectory: true)
      .appendingPathComponent("Models", isDirectory: true)
  }

  private static func catalogModel(_ candidate: ModelCandidate) -> AppCatalogModel {
    let entry = candidate.entry
    return AppCatalogModel(
      key: entry.metadata.key,
      displayName: entry.metadata.displayName,
      runtime: entry.manifest.runtime.runtimeIdentifier,
      downloadBytes: entry.approximateDownloadBytes,
      tasks: Set(entry.manifest.capabilities.map(\.task)),
      support: candidate.support
    )
  }
}

func appByteCount(_ value: UInt64) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
}
