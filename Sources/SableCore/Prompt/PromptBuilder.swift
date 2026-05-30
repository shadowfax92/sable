import Foundation

public enum PromptBuilder {
    /// Builds the single-shot runtime prompt used for paste-ready text transformations.
    /// `screenshotPath` is optional context — when empty (screen-recording off or
    /// capture failed) the section is omitted so the run still proceeds.
    public static func build(
        instruction: String,
        selectedText: String,
        screenshotPath: String
    ) -> String {
        var prompt = """
        You edit selected text for paste-back into the user's current app.
        Return only the replacement text. Do not explain the changes.

        Instruction:
        \(instruction)

        Selected text:
        \(selectedText)
        """

        if !screenshotPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\n\nScreenshot path:\n\(screenshotPath)"
        }

        return prompt
    }
}
