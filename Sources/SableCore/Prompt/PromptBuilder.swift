import Foundation

public enum PromptBuilder {
    /// Builds the single-shot Claude prompt used for paste-ready text transformations.
    public static func build(
        instruction: String,
        selectedText: String,
        screenshotPath: String
    ) -> String {
        """
        You edit selected text for paste-back into the user's current app.
        Return only the replacement text. Do not explain the changes.

        Instruction:
        \(instruction)

        Selected text:
        \(selectedText)

        Screenshot path:
        \(screenshotPath)
        """
    }
}
