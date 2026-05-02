import XCTest
@testable import SableCore

final class PromptBuilderTests: XCTestCase {
    func testBuildsQuickFixPrompt() {
        let prompt = PromptBuilder.build(
            instruction: "Fix grammar.",
            selectedText: "this are bad",
            screenshotPath: "/tmp/sable/run/screenshot.png"
        )

        XCTAssertTrue(prompt.contains("Return only the replacement text."))
        XCTAssertTrue(prompt.contains("Instruction:\nFix grammar."))
        XCTAssertTrue(prompt.contains("Selected text:\nthis are bad"))
        XCTAssertTrue(prompt.contains("Screenshot path:\n/tmp/sable/run/screenshot.png"))
    }

    func testDoesNotWrapSelectedTextInMarkdownFence() {
        let prompt = PromptBuilder.build(
            instruction: "Rewrite.",
            selectedText: "```swift\nlet x = 1\n```",
            screenshotPath: "/tmp/screenshot.png"
        )

        XCTAssertTrue(prompt.contains("```swift"))
        XCTAssertFalse(prompt.contains("Selected text:\n```text"))
    }
}
