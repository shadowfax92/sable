import Foundation
import SableCore

/// Translates between the editor core's grapheme offsets (Swift `Character`s)
/// and AppKit's UTF-16 `NSRange`s. This is the only place the review editor
/// crosses that boundary. Getting it wrong splits emoji, flags or combining
/// marks, and makes the engine and NSTextView disagree about the cursor.
///
/// Offsets inside a grapheme round down to its start. Direction is not part of
/// an `NSRange`, so callers say which end is the anchor.
enum GraphemeRangeMapper {
    /// UTF-16 offset of the boundary before grapheme `offset`, clamped to the text.
    static func utf16Offset(forGrapheme offset: Int, in text: String) -> Int {
        let clamped = min(max(offset, 0), text.count)
        let index = text.index(text.startIndex, offsetBy: clamped)
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    /// Grapheme offset of the boundary at or before UTF-16 `offset`.
    static func graphemeOffset(forUTF16 offset: Int, in text: String) -> Int {
        var utf16 = 0
        var graphemes = 0
        for character in text {
            let next = utf16 + character.utf16.count
            if next > offset { break }
            utf16 = next
            graphemes += 1
        }
        return graphemes
    }

    static func nsRange(for selection: EditorSelection, in text: String) -> NSRange {
        let lower = utf16Offset(forGrapheme: selection.range.lowerBound, in: text)
        let upper = utf16Offset(forGrapheme: selection.range.upperBound, in: text)
        return NSRange(location: lower, length: upper - lower)
    }

    /// - Parameter headAtEnd: True when the cursor (head) sits at the range's
    ///   upper end, as for forward drags and plain carets.
    static func selection(for range: NSRange, in text: String, headAtEnd: Bool = true) -> EditorSelection {
        let lower = graphemeOffset(forUTF16: range.location, in: text)
        let upper = graphemeOffset(forUTF16: range.location + range.length, in: text)
        return headAtEnd
            ? EditorSelection(anchor: lower, head: upper)
            : EditorSelection(anchor: upper, head: lower)
    }
}
