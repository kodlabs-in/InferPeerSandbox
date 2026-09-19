#if DEBUG || INFERPEER_PHYSICAL_TESTING
  import Foundation
  import InferPeerCore
  import UIKit

  private struct SandboxPhysicalSmokeConfiguration {
    let pairingCode: String
    let modelID: String
    let prompt: String
    let expectedText: String
    let usesImage: Bool
    let iterations: Int

    var mode: String { usesImage ? "vision" : "text" }

    static var current: Self? {
      let environment = ProcessInfo.processInfo.environment
      guard
        let pairingCode = environment["INFERPEER_SMOKE_PAIRING_CODE"],
        let modelID = environment["INFERPEER_SMOKE_MODEL_ID"]
      else { return nil }
      let usesImage = environment["INFERPEER_SMOKE_MODE"] == "vision"
      return Self(
        pairingCode: pairingCode,
        modelID: modelID,
        prompt: usesImage
          ? "What color is the square? Answer with one color word."
          : "Reply with exactly INFERPEER_OK.",
        expectedText: usesImage ? "red" : "INFERPEER_OK",
        usesImage: usesImage,
        iterations: min(max(Int(environment["INFERPEER_SMOKE_ITERATIONS"] ?? "1") ?? 1, 1), 5)
      )
    }
  }

  private struct SandboxPhysicalSmokeSample {
    let seconds: Double
    let outputTokens: UInt32
  }

  private enum SandboxPhysicalSmokeError: LocalizedError {
    case modelUnavailable(String)
    case runTimedOut
    case unexpectedResponse(String)

    var errorDescription: String? {
      switch self {
      case .modelUnavailable(let modelID):
        "Model \(modelID) did not become available."
      case .runTimedOut:
        "The inference run timed out."
      case .unexpectedResponse(let response):
        "Unexpected response: \(response)"
      }
    }
  }

  extension SandboxChatController {
    func runConfiguredPhysicalSmokeTest() async {
      guard let smoke = SandboxPhysicalSmokeConfiguration.current else { return }
      do {
        let resourceID = try await runtime.pair(code: smoke.pairingCode)
        let choice = try await waitForSmokeChoice(
          modelID: smoke.modelID,
          resourceID: resourceID
        )
        selectedChoiceID = choice.id
        let samples = try await performSmokeSamples(smoke, choice: choice)
        let median = samples.map(\.seconds).sorted()[samples.count / 2]
        let tokenCount = samples.map(\.outputTokens).reduce(0, +)
        status = String(
          format: "Physical %@ passed on %@ · p50 %.2fs · %u tokens",
          smoke.mode,
          choice.resourceName,
          median,
          tokenCount
        )
        print(
          "INFERPEER_SMOKE_SUCCESS mode=\(smoke.mode) "
            + "model=\(choice.model.modelID.rawValue) p50=\(median)s tokens=\(tokenCount)"
        )
      } catch {
        status = "Physical smoke test failed: \(error.localizedDescription)"
        print("INFERPEER_SMOKE_FAILURE \(String(reflecting: error))")
      }
    }

    private func performSmokeSamples(
      _ smoke: SandboxPhysicalSmokeConfiguration,
      choice: SandboxExecutionChoice
    ) async throws -> [SandboxPhysicalSmokeSample] {
      var samples: [SandboxPhysicalSmokeSample] = []
      for _ in 0..<smoke.iterations {
        samples.append(try await performSmokeSample(smoke, choice: choice))
      }
      return samples
    }

    private func performSmokeSample(
      _ smoke: SandboxPhysicalSmokeConfiguration,
      choice: SandboxExecutionChoice
    ) async throws -> SandboxPhysicalSmokeSample {
      messages.removeAll()
      selectedChoiceID = choice.id
      if smoke.usesImage { attachImage(Self.smokeImageData()) }
      prompt = smoke.prompt
      let clock = ContinuousClock()
      let startedAt = clock.now
      send()
      let response = try await waitForSmokeCompletion()
      guard response.localizedCaseInsensitiveContains(smoke.expectedText) else {
        throw SandboxPhysicalSmokeError.unexpectedResponse(response)
      }
      return SandboxPhysicalSmokeSample(
        seconds: Self.seconds(startedAt.duration(to: clock.now)),
        outputTokens: lastUsage?.outputTokens ?? 0
      )
    }

    private func waitForSmokeChoice(
      modelID: String,
      resourceID: ResourceID
    ) async throws -> SandboxExecutionChoice {
      for _ in 0..<60 {
        if let choice = choices.first(where: {
          $0.resourceID == resourceID && $0.model.modelID.rawValue == modelID
        }) {
          return choice
        }
        try await Task.sleep(for: .seconds(1))
      }
      throw SandboxPhysicalSmokeError.modelUnavailable(modelID)
    }

    private func waitForSmokeCompletion() async throws -> String {
      for _ in 0..<300 {
        if !isRunning {
          guard status.hasPrefix("Completed") else {
            throw SandboxPhysicalSmokeError.unexpectedResponse(status)
          }
          return messages.last?.text ?? ""
        }
        try await Task.sleep(for: .seconds(1))
      }
      cancel()
      throw SandboxPhysicalSmokeError.runTimedOut
    }

    private static func smokeImageData() -> Data {
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
      return renderer.pngData { context in
        UIColor.white.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        UIColor.red.setFill()
        context.cgContext.fill(CGRect(x: 40, y: 40, width: 176, height: 176))
      }
    }

    private static func seconds(_ duration: Duration) -> Double {
      let components = duration.components
      return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
  }
#endif
