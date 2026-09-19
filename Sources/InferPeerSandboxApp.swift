import SwiftUI

@main
struct InferPeerSandboxApp: App {
    @StateObject private var validation = SandboxViewModel()
    @StateObject private var resources: SandboxResourceController
    @StateObject private var models: SandboxModelLibraryController
    @StateObject private var chat: SandboxChatController
    @StateObject private var transcription: SandboxTranscriptionController
    @StateObject private var benchmarks: SandboxBenchmarkController
    private let automation: SandboxAutomationRunner

    init() {
        let service = SandboxLocalAIService()
        let automation = SandboxAutomationRunner(service: service)
        self.automation = automation
        _resources = StateObject(
            wrappedValue: SandboxResourceController(service: service)
        )
        _models = StateObject(
            wrappedValue: SandboxModelLibraryController(service: service)
        )
        _chat = StateObject(
            wrappedValue: SandboxChatController(service: service)
        )
        _transcription = StateObject(
            wrappedValue: SandboxTranscriptionController(service: service)
        )
        _benchmarks = StateObject(
            wrappedValue: SandboxBenchmarkController(service: service)
        )
        Task { await automation.runIfRequested() }
    }

    var body: some Scene {
        WindowGroup {
            SandboxView(
                validation: validation,
                resources: resources,
                models: models,
                chat: chat,
                transcription: transcription,
                benchmarks: benchmarks
            )
    }
}
}
