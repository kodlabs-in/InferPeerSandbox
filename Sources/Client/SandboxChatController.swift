import Foundation
import InferPeer
import InferPeerCore
import InferPeerInference
import SwiftUI
import UIKit

@MainActor
final class SandboxChatController: ObservableObject {
  @Published var messages: [SandboxChatMessage] = []
  @Published private(set) var resources: [ResourceSnapshot] = []
  @Published private(set) var choices: [SandboxExecutionChoice] = []
  @Published private(set) var candidates: [SandboxDiscoveryCandidate] = []
  @Published var status = "Starting InferPeer…"
  @Published private(set) var attachedImageData: Data?
  @Published var prompt = ""
  @Published var pairingCode = ""
  @Published var selectedChoiceID: String?
  @Published private(set) var isRunning = false
  @Published private(set) var lastUsage: TokenUsage?

  let runtime = SandboxClientRuntime()
  private var resourceTask: Task<Void, Never>?
  private var discoveryTask: Task<Void, Never>?
  private var runTask: Task<Void, Never>?
  private var discoveryHandle: DiscoveryHandle?
  private var activeHandle: RunHandle?
  private var imageURL: URL?
  private var modelNames: [ModelKey: String] = [:]
  private var started = false

  func start() async {
    guard !started else { return }
    started = true
    do {
      let facade = try await runtime.facade()
      modelNames = try await runtime.modelNames()
      observeResources(facade)
      try await startDiscovery(facade)
      _ = await facade.reconnectPairedResources()
      status = "Choose a resource and model."
    } catch {
      status = "Startup failed: \(error.localizedDescription)"
      started = false
    }
  }

  func pair() {
    let code = pairingCode
    Task {
      do {
        _ = try await runtime.pair(code: code)
        pairingCode = ""
        status = "Resource paired securely."
      } catch {
        status = "Pairing failed: \(error.localizedDescription)"
      }
    }
  }

  func refreshResources() {
    Task {
      do {
        let facade = try await runtime.facade()
        let snapshots = await facade.reconnectPairedResources()
        status = "Refreshed \(snapshots.count) paired resource(s)."
      } catch {
        status = "Refresh failed: \(error.localizedDescription)"
      }
    }
  }

  func attachImage(_ data: Data) {
    guard let image = UIImage(data: data), let png = image.pngData() else {
      status = "That image format could not be prepared."
      return
    }
    do {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("png")
      try png.write(to: url, options: .atomic)
      removeAttachedImage()
      imageURL = url
      attachedImageData = png
      chooseCompatibleSelection()
    } catch {
      status = "Image preparation failed: \(error.localizedDescription)"
    }
  }

  func removeAttachedImage() {
    if let imageURL { try? FileManager.default.removeItem(at: imageURL) }
    imageURL = nil
    attachedImageData = nil
  }

  func send() {
    let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isRunning, !text.isEmpty, let choice = selectedChoice else { return }
    guard imageURL == nil || choice.tasks.contains(.imageUnderstanding) else {
      status = "Choose a vision-capable model for this image."
      return
    }
    let history = inferenceHistory(adding: text)
    let runImageURL = imageURL
    let runImageData = attachedImageData
    messages.append(
      SandboxChatMessage(id: UUID(), role: .user, text: text, imageData: runImageData)
    )
    messages.append(
      SandboxChatMessage(id: UUID(), role: .assistant, text: "", imageData: nil)
    )
    prompt = ""
    imageURL = nil
    attachedImageData = nil
    lastUsage = nil
    isRunning = true
    status = "Preparing \(choice.modelName) on \(choice.resourceName)…"
    runTask = Task { [weak self] in
      await self?.performRun(choice: choice, messages: history, imageURL: runImageURL)
    }
  }

  func cancel() {
    let handle = activeHandle
    runTask?.cancel()
    Task { await handle?.cancel() }
    finishRun(status: "Cancelled.")
  }

  func enteredBackground() {
    cancel()
    status = "Paused while InferPeer Sandbox is not in the foreground."
  }

}

extension SandboxChatController {
  fileprivate var selectedChoice: SandboxExecutionChoice? {
    choices.first { $0.id == selectedChoiceID }
  }

  fileprivate func observeResources(_ facade: InferPeer) {
    resourceTask?.cancel()
    resourceTask = Task { [weak self] in
      let updates = await facade.watchResources(.known)
      for await snapshots in updates {
        self?.applyResources(snapshots)
      }
    }
  }

  fileprivate func startDiscovery(_ facade: InferPeer) async throws {
    let handle = try await facade.discovery()
    discoveryHandle = handle
    discoveryTask = Task { [weak self] in
      do {
        for try await event in handle.events { self?.applyDiscovery(event) }
      } catch {
        self?.status = "Discovery stopped: \(error.localizedDescription)"
      }
    }
  }

  fileprivate func applyResources(_ snapshots: [ResourceSnapshot]) {
    let remoteResources = snapshots.filter { $0.id != .local }
    resources = remoteResources
    choices = remoteResources.flatMap { resource in
      resource.models.map { model in
        SandboxExecutionChoice(
          resourceID: resource.id,
          resourceName: resource.displayName,
          model: model.key,
          modelName: modelNames[model.key] ?? model.key.modelID.rawValue,
          tasks: model.supportedTasks
        )
      }
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    chooseCompatibleSelection()
  }

  fileprivate func applyDiscovery(_ event: DiscoveryEvent) {
    switch event {
    case .candidateFound(let candidate):
      candidates.removeAll { $0.id == candidate.id }
      candidates.append(
        SandboxDiscoveryCandidate(
          id: candidate.id,
          name: candidate.serviceName,
          endpoint: candidate.endpoint
        )
      )
    case .candidateRemoved(let id):
      candidates.removeAll { $0.id == id }
    case .permissionRequired:
      status = "Allow Local Network access to discover resources."
    case .permissionDenied:
      status = "Local Network access is disabled in Settings."
    case .discoveryUnavailable:
      status = "Resource discovery is currently unavailable."
    }
  }

  fileprivate func chooseCompatibleSelection() {
    let task: InferenceTask = imageURL == nil ? .textGeneration : .imageUnderstanding
    let compatible = choices.filter { $0.tasks.contains(task) }
    if !compatible.contains(where: { $0.id == selectedChoiceID }) {
      selectedChoiceID = compatible.first?.id
    }
  }

  fileprivate func inferenceHistory(adding prompt: String) -> [InferenceMessage] {
    let previous = messages.compactMap { message -> InferenceMessage? in
      guard !message.text.isEmpty else { return nil }
      switch message.role {
      case .user: return .user(message.text)
      case .assistant: return .assistant(message.text)
      }
    }
    return previous + [.user(prompt)]
  }

  fileprivate func performRun(
    choice: SandboxExecutionChoice,
    messages: [InferenceMessage],
    imageURL: URL?
  ) async {
    defer { if let imageURL { try? FileManager.default.removeItem(at: imageURL) } }
    do {
      let facade = try await runtime.facade()
      let query = makeQuery(choice: choice, messages: messages, imageURL: imageURL)
      let handle = try await facade.run(query, resourceId: choice.resourceID)
      activeHandle = handle
      for try await event in handle.events { apply(event) }
      let result = try await handle.result()
      lastUsage = result.usage
      finishRun(status: "Completed on \(choice.resourceName).")
    } catch is CancellationError {
      finishRun(status: "Cancelled.")
    } catch {
      finishRun(status: "Run failed: \(error.localizedDescription)")
    }
  }

  fileprivate func makeQuery(
    choice: SandboxExecutionChoice,
    messages: [InferenceMessage],
    imageURL: URL?
  ) -> InferenceQuery {
    let generation = TextQueryGenerationOptions(maxOutputTokens: 512, temperature: 0.2)
    guard let imageURL else {
      return .text(model: .exact(choice.model), messages: messages, generation: generation)
    }
    return .vision(
      model: .exact(choice.model),
      messages: messages,
      images: [.file(imageURL)],
      generation: generation
    )
  }

  fileprivate func apply(_ event: RunEvent) {
    guard let index = messages.indices.last else { return }
    switch event {
    case .textDelta(let text):
      messages[index].text += text
      status = "Streaming from selected resource…"
    case .completed(let result):
      messages[index].text = result.text
      status = "Completed · \(result.usage.outputTokens) output tokens"
    case .loadingModel:
      status = "Loading selected model…"
    case .preprocessing:
      status = "Preparing image…"
    default:
      break
    }
  }

  fileprivate func finishRun(status: String) {
    activeHandle = nil
    runTask = nil
    isRunning = false
    self.status = status
  }

}
