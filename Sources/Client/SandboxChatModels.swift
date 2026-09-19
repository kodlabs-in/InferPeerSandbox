import Foundation
import InferPeerCore
import InferPeerInference

struct SandboxChatMessage: Identifiable, Sendable {
  enum Role: Equatable, Sendable {
    case user
    case assistant
  }

  let id: UUID
  let role: Role
  var text: String
  let imageData: Data?
}

struct SandboxExecutionChoice: Identifiable, Hashable, Sendable {
  let resourceID: ResourceID
  let resourceName: String
  let model: ModelKey
  let modelName: String
  let tasks: Set<InferenceTask>

  var id: String {
    resourceID.rawValue + "|" + model.modelID.rawValue + "|" + model.revision
  }
  var title: String { modelName + " on " + resourceName }
}

struct SandboxDiscoveryCandidate: Identifiable, Sendable {
  let id: CandidateID
  let name: String
  let endpoint: PeerEndpoint
}
