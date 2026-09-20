import SwiftUI

@main
struct InferPeerSandboxApp: App {
  @StateObject private var controller = SandboxChatController()
  @Environment(\.scenePhase) private var scenePhase

  var body: some Scene {
    WindowGroup {
      SandboxChatView(controller: controller)
        .task {
          await controller.start()
          #if DEBUG || INFERPEER_PHYSICAL_TESTING
            await controller.runConfiguredPhysicalSmokeTest()
          #endif
        }
        .onChange(of: scenePhase) { _, phase in
          if phase != .active { controller.enteredBackground() }
        }
    }
  }
}
