import SwiftUI

struct SandboxPairingView: View {
  @ObservedObject var controller: SandboxChatController
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Discovered resource apps") {
          if controller.candidates.isEmpty {
            Text("Open InferPeer Resource on an iPhone or Mac connected to this Wi-Fi.")
              .foregroundStyle(.secondary)
          }
          ForEach(controller.candidates) { candidate in
            LabeledContent(candidate.name) {
              Text("\(candidate.endpoint.host):\(candidate.endpoint.port)")
                .font(.caption.monospaced())
            }
          }
        }
        Section("Pair securely") {
          Text("Copy the one-time code shown by the resource app and paste it here.")
            .font(.caption)
            .foregroundStyle(.secondary)
          TextEditor(text: $controller.pairingCode)
            .font(.caption.monospaced())
            .frame(minHeight: 120)
            .accessibilityIdentifier("pairing.code")
          Button("Pair resource") { controller.pair() }
            .buttonStyle(.borderedProminent)
            .disabled(controller.pairingCode.isEmpty)
            .accessibilityIdentifier("pairing.submit")
        }
        Section("Status") { Text(controller.status) }
      }
      .navigationTitle("Pair Resource")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
  }
}
