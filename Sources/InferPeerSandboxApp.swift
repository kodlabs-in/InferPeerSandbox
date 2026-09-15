import SwiftUI

@main
struct InferPeerSandboxApp: App {
    @StateObject private var model = SandboxViewModel()

    var body: some Scene {
        WindowGroup {
            SandboxView(model: model)
        }
    }
}
