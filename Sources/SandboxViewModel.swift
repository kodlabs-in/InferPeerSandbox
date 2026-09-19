import Foundation
import SwiftUI
#if os(iOS)
    import UIKit
#endif

@MainActor
final class SandboxViewModel: ObservableObject {
    @Published private(set) var checks: [SandboxCheck] = []
    @Published private(set) var isRunningChecks = false
    @Published private(set) var lifecycleDescription = "active"

    private let validationRunner = SandboxValidationRunner()

    var platformDescription: String {
        #if os(iOS)
            UIDevice.current.model + " · " + UIDevice.current.systemVersion
        #else
            "Mac · " + ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    var platformLabel: String {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
            "Mac"
        #endif
    }

    var platformSystemImage: String {
        #if os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
            "desktopcomputer"
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
        }
    }

}
