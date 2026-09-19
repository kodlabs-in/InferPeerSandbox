import PhotosUI
import SwiftUI
import UIKit

struct SandboxChatView: View {
  @ObservedObject var controller: SandboxChatController
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var showsPairing = false

  var body: some View {
    NavigationSplitView {
      resourceSidebar
    } detail: {
      VStack(spacing: 0) {
        transcript
        Divider()
        composer
      }
      .navigationTitle("InferPeer")
      .toolbar { toolbar }
    }
    .sheet(isPresented: $showsPairing) {
      SandboxPairingView(controller: controller)
    }
  }

  private var resourceSidebar: some View {
    List {
      Section("Run on") {
        Picker("Model and resource", selection: $controller.selectedChoiceID) {
          Text("Choose a model").tag(String?.none)
          ForEach(compatibleChoices) { choice in
            Text(choice.title).tag(Optional(choice.id))
          }
        }
        .pickerStyle(.inline)
      }
      Section("Connected resources") {
        ForEach(controller.resources, id: \.id) { resource in
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(resource.displayName)
              Text(
                "\(resource.models.count) model(s) · "
                  + resource.execution.rawValue
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: resource.id == .local ? "ipad" : "cpu")
          }
        }
      }
    }
    .navigationTitle("Resources")
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 16) {
          if controller.messages.isEmpty { welcome }
          ForEach(controller.messages) { message in
            messageBubble(message)
              .id(message.id)
          }
        }
        .padding(24)
      }
      .onChange(of: controller.messages.count) { _, _ in
        if let id = controller.messages.last?.id {
          withAnimation { proxy.scrollTo(id, anchor: .bottom) }
        }
      }
    }
  }

  private var welcome: some View {
    ContentUnavailableView {
      Label("Your private model network", systemImage: "sparkles.rectangle.stack")
    } description: {
      Text("Pair an iPhone or Mac resource, choose its model, then send text or an image.")
    }
    .padding(.top, 80)
  }

  private func messageBubble(_ message: SandboxChatMessage) -> some View {
    HStack {
      if message.role == .user { Spacer(minLength: 80) }
      VStack(alignment: .leading, spacing: 10) {
        if let data = message.imageData, let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        Text(message.text.isEmpty ? "Thinking…" : message.text)
          .textSelection(.enabled)
      }
      .padding(14)
      .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12))
      .foregroundStyle(message.role == .user ? .white : .primary)
      .clipShape(RoundedRectangle(cornerRadius: 18))
      if message.role == .assistant { Spacer(minLength: 80) }
    }
  }

  private var composer: some View {
    VStack(spacing: 10) {
      if let data = controller.attachedImageData, let image = UIImage(data: data) {
        HStack {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
          Text("Image attached")
          Spacer()
          Button("Remove", systemImage: "xmark.circle.fill") {
            controller.removeAttachedImage()
          }
          .labelStyle(.iconOnly)
        }
      }
      HStack(alignment: .bottom, spacing: 12) {
        PhotosPicker(selection: $selectedPhoto, matching: .images) {
          Image(systemName: "photo.badge.plus")
            .font(.title2)
        }
        .accessibilityIdentifier("sandbox.photo")
        .onChange(of: selectedPhoto) { _, item in load(item) }
        TextField("Ask the selected model", text: $controller.prompt, axis: .vertical)
          .textFieldStyle(.roundedBorder)
          .lineLimit(1...6)
          .accessibilityIdentifier("sandbox.prompt")
        if controller.isRunning {
          Button("Stop", systemImage: "stop.fill") { controller.cancel() }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
          Button("Send", systemImage: "arrow.up") { controller.send() }
            .buttonStyle(.borderedProminent)
            .disabled(controller.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("sandbox.send")
        }
      }
      HStack {
        Text(controller.status)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
    }
    .padding()
    .background(.regularMaterial)
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .primaryAction) {
      Button("Refresh", systemImage: "arrow.clockwise") {
        controller.refreshResources()
      }
      Button("Pair", systemImage: "link.badge.plus") { showsPairing = true }
        .accessibilityIdentifier("sandbox.pair")
    }
  }

  private var compatibleChoices: [SandboxExecutionChoice] {
    let wantsVision = controller.attachedImageData != nil
    return controller.choices.filter {
      $0.tasks.contains(wantsVision ? .imageUnderstanding : .textGeneration)
    }
  }

  private func load(_ item: PhotosPickerItem?) {
    guard let item else { return }
    Task {
      if let data = try? await item.loadTransferable(type: Data.self) {
        controller.attachImage(data)
      }
      selectedPhoto = nil
    }
  }
}
