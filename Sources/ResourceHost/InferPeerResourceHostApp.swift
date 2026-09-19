import SwiftUI

@main
struct InferPeerResourceHostApp: App {
  @StateObject private var controller = ResourceHostController()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      ResourceHostView(controller: controller)
        .task {
          await controller.enteredForeground()
          #if DEBUG || INFERPEER_PHYSICAL_TESTING
            await controller.installConfiguredPhysicalTestModels()
          #endif
        }
        .onChange(of: scenePhase) { _, phase in
          updateSharing(for: phase)
        }
    }
  }

  private func updateSharing(for phase: ScenePhase) {
    #if os(iOS)
      let canShare = phase == .active
    #else
      // A visible macOS app remains a foreground host when another app is key.
      let canShare = phase != .background
    #endif
    if canShare {
      Task { await controller.enteredForeground() }
    } else {
      controller.enteredBackground()
    }
  }
}
