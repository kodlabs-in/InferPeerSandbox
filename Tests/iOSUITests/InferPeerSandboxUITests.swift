import XCTest

@MainActor
final class InferPeerSandboxUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testPairsWithMacAndStreamsTextFromItsExactModel() throws {
    guard ProcessInfo.processInfo.environment["INFERPEER_UI_PAIRING_READY"] == "1" else {
      throw XCTSkip(
        "Requires a foreground resource host and its invitation on the device pasteboard.")
    }
    executionTimeAllowance = 90
    let application = XCUIApplication()
    application.launch()

    let pairingButton = application.buttons["sandbox.pair"]
    XCTAssertTrue(pairingButton.waitForExistence(timeout: 30))
    pairingButton.tap()

    let codeEditor = application.textViews["pairing.code"]
    XCTAssertTrue(codeEditor.waitForExistence(timeout: 10))
    codeEditor.tap()
    codeEditor.press(forDuration: 1)
    let paste = application.menuItems["Paste"]
    XCTAssertTrue(paste.waitForExistence(timeout: 10))
    paste.tap()
    application.buttons["pairing.submit"].tap()

    let paired = application.staticTexts["Resource paired securely."]
    XCTAssertTrue(paired.waitForExistence(timeout: 30))
    application.buttons["Done"].tap()

    let model = application.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS[c] %@", "Qwen3 0.6B 4-bit")
    ).firstMatch
    XCTAssertTrue(model.waitForExistence(timeout: 300))
    model.tap()

    let prompt = application.textFields["sandbox.prompt"]
    XCTAssertTrue(prompt.waitForExistence(timeout: 10))
    prompt.tap()
    let request = "Reply with exactly INFERPEER_OK."
    prompt.typeText(request)
    XCTAssertEqual(prompt.value as? String, request)
    let send = application.buttons["sandbox.send"]
    XCTAssertTrue(send.isEnabled)
    send.tap()

    let started = application.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@",
        "Preparing",
        "Streaming"
      )
    ).firstMatch
    XCTAssertTrue(started.waitForExistence(timeout: 30))

    let completion = application.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Completed on")
    ).firstMatch
    XCTAssertTrue(completion.waitForExistence(timeout: 30))

    let attachment = XCTAttachment(screenshot: application.screenshot())
    attachment.name = "Remote text completion"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
