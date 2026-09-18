import Foundation
import SwiftUI

@MainActor
final class SandboxViewModel: ObservableObject {
    @Published private(set) var checks: [SandboxCheck] = []
    @Published private(set) var isRunningChecks = false
    @Published private(set) var isRunningModel = false
    @Published private(set) var generatedText = ""
    @Published private(set) var modelStatus = "Preparing the bundled pinned model."
    @Published private(set) var clusterStatus = "Physical-device cluster run is not configured."
    @Published private(set) var lifecycleDescription = "active"

    private let validationRunner = SandboxValidationRunner()
    private let modelRunner = SandboxMLXRunner()
    private let clusterRunner = SandboxClusterRunner()

    var platformDescription: String {
        #if os(iOS)
            UIDevice.current.model + " · " + UIDevice.current.systemVersion
        #else
            "Mac · " + ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    func runChecks() {
        guard !isRunningChecks else { return }
        isRunningChecks = true
        Task {
            checks = await validationRunner.run()
            isRunningChecks = false
        }
    }

    func handle(_ phase: ScenePhase) {
        lifecycleDescription = String(describing: phase)
        Task {
            await validationRunner.setParticipation(
                phase == .active ? .available : .unavailable
            )
            await clusterRunner.setParticipation(
                phase == .active ? .available : .unavailable
            )
        }
    }

    func receiveModelSelection(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            runModel(at: url)
        } catch {
            modelStatus = "Selection failed: \(error.localizedDescription)"
        }
    }

    func runBundledModel() {
        guard
            let url = Bundle.main.url(
                forResource: SandboxPinnedModel.directoryName,
                withExtension: nil
            )
        else {
            let message = "Bundled model resource is missing."
            modelStatus = message
            try? SandboxEvidenceStore.writeModelFailure(message)
            return
        }
        runModel(at: url)
    }

    private func runModel(at url: URL) {
        guard !isRunningModel else { return }
        isRunningModel = true
        generatedText = ""
        modelStatus = "Preparing \(url.lastPathComponent)…"
        Task {
            do {
                let result = try await modelRunner.run(directoryURL: url)
                generatedText = result.text
                modelStatus = result.summary
                try SandboxEvidenceStore.writeModelSuccess(result)
                if let result = await clusterRunner.runIfConfigured(modelURL: url) {
                    clusterStatus = result
                }
            } catch {
                modelStatus = "Model run failed: \(error.localizedDescription)"
                try? SandboxEvidenceStore.writeModelFailure(error.localizedDescription)
            }
            isRunningModel = false
        }
    }
}
