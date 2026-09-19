import InferPeerInference
import InferPeerModelStore
import SwiftUI

struct ResourceHostView: View {
  @ObservedObject var controller: ResourceHostController

  var body: some View {
    NavigationStack {
      List {
        sharingSection
        invitationSection
        installedSection
        catalogSection
        if let progress = controller.installProgress { progressSection(progress) }
        Section("Status") { Text(controller.status) }
      }
      .navigationTitle("InferPeer Resource")
    }
  }

  private var sharingSection: some View {
    Section("Foreground sharing") {
      Toggle(
        "Available to paired apps",
        isOn: Binding(
          get: { controller.sharingRequested },
          set: controller.setSharing
        )
      )
      LabeledContent("State", value: controller.isSharing ? "Ready" : "Paused")
      Text("This device accepts work only while this app is open in the foreground.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var invitationSection: some View {
    Section("Pair a client app") {
      if controller.invitationCode.isEmpty {
        Text("Start sharing to create a short-lived, single-use invitation.")
          .foregroundStyle(.secondary)
      } else {
        Text(controller.invitationCode)
          .font(.caption2.monospaced())
          .textSelection(.enabled)
          .lineLimit(5)
        HStack {
          Button("Copy code", systemImage: "doc.on.doc") {
            controller.copyInvitation()
          }
          ShareLink(item: controller.invitationCode) {
            Label("Share", systemImage: "square.and.arrow.up")
          }
          Button("Renew", systemImage: "arrow.clockwise") {
            controller.renewInvitation()
          }
        }
      }
    }
  }

  private var installedSection: some View {
    Section("Models on this device") {
      if controller.installed.isEmpty {
        Text("Install a text or vision model below.")
          .foregroundStyle(.secondary)
      }
      ForEach(controller.installed) { model in
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(model.name)
            Text(
              "\(taskTitle(model.tasks)) · \(model.runtime) · "
                + appByteCount(model.installedBytes)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Remove", role: .destructive) { controller.remove(model) }
        }
      }
    }
  }

  private var catalogSection: some View {
    Section("Signed starter models") {
      ForEach(controller.catalog) { model in
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(model.displayName)
            Text(
              "\(taskTitle(model.tasks)) · \(model.runtime) · "
                + appByteCount(model.downloadBytes)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button(
            controller.installingModelID == model.key ? "Installing" : "Install"
          ) { controller.install(model) }
          .disabled(controller.installingModelID != nil || !model.support.isInstallable)
          .accessibilityIdentifier("catalog.install.\(model.key.modelID.rawValue)")
        }
      }
    }
  }

  private func progressSection(_ progress: ModelInstallationProgress) -> some View {
    Section("Download") {
      ProgressView(
        value: Double(progress.totalCompletedBytes),
        total: Double(progress.totalBytes)
      )
      Text(
        "\(appByteCount(progress.totalCompletedBytes)) of "
          + appByteCount(progress.totalBytes)
      )
      .font(.caption)
    }
  }

  private func taskTitle(_ tasks: Set<InferenceTask>) -> String {
    tasks.contains(.imageUnderstanding) ? "Text + Vision" : "Text"
  }
}
