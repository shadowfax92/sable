import Foundation

/// A per-command grapheme/line index. All edits use Character offsets, including
/// CRLF and composed emoji; newline cells belong to the line they terminate.
/// Rebuilding this small index keeps native snapshots and modal ranges in sync.
struct EditorBuffer {
    let characters: [Character]
    let starts: [Int]
    let ends: [Int]
    var count: Int { characters.count }

    init(_ text: String) {
        characters = Array(text)
        var starts = [0]
        var ends: [Int] = []
        for (index, character) in characters.enumerated() where character.isNewline {
            ends.append(index)
            starts.append(index + 1)
        }
        ends.append(characters.count)
        self.starts = starts
        self.ends = ends
    }

    func line(at position: Int) -> Int {
        // upper_bound also retains the final empty line after a trailing newline.
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }

    func normalCursor(_ position: Int) -> Int {
        let position = min(max(0, position), count)
        let row = line(at: position)
        return min(position, max(starts[row], ends[row] - 1))
    }

    func firstNonblank(_ row: Int) -> Int {
        var position = starts[row]
        while position < ends[row], characters[position].isWhitespace { position += 1 }
        return position == ends[row] ? starts[row] : position
    }

    /// Reuse a real separator so opening a line cannot accidentally merge a
    /// preceding CR with a new LF into one CRLF grapheme (and lose the new line).
    func lineSeparator(_ row: Int) -> String {
        if ends[row] < count { return String(characters[ends[row]]) }
        if row > 0 { return String(characters[starts[row] - 1]) }
        return "\n"
    }

    func text(in range: Range<Int>) -> String { String(characters[range]) }

    func replacing(_ range: Range<Int>, with replacement: String) -> String {
        String(characters[..<range.lowerBound]) + replacement + String(characters[range.upperBound...])
    }

    // Vim small words: letters/numbers/underscore form a run; punctuation forms
    // another run. Unicode letters participate without splitting their graphemes.
    func category(at index: Int) -> Int {
        let character = characters[index]
        if character.isWhitespace { return 0 }
        if character == "_" || character.unicodeScalars.contains(where: {
            $0.properties.isAlphabetic || $0.properties.numericType != nil
        }) { return 1 }
        return 2
    }

    func wordForward(_ start: Int, count repeats: Int) -> Int {
        var position = start
        for _ in 0..<repeats {
            if position >= count { break }
            let category = category(at: position)
            while position < count, self.category(at: position) == category { position += 1 }
            while position < count, self.category(at: position) == 0 { position += 1 }
        }
        return position
    }

    func wordBackward(_ start: Int, count repeats: Int) -> Int {
        var position = start
        for _ in 0..<repeats {
            if position == 0 { break }
            position -= 1
            while position > 0, category(at: position) == 0 { position -= 1 }
            let category = category(at: position)
            while position > 0, self.category(at: position - 1) == category { position -= 1 }
        }
        return position
    }

    func wordEnd(_ start: Int, count repeats: Int) -> Int {
        guard count > 0 else { return 0 }
        var position = start
        for _ in 0..<repeats {
            if position >= count - 1 { return count - 1 }
            if category(at: position) == 0 || category(at: position + 1) != category(at: position) {
                position += 1
                while position < count - 1, category(at: position) == 0 { position += 1 }
            }
            let category = category(at: position)
            while position < count - 1, self.category(at: position + 1) == category { position += 1 }
        }
        return position
    }

    /// cw includes the current word even on its last cell. Normal e must
    /// advance there; reusing e for the first count would erase the next word.
    func changeWordEnd(_ start: Int, count repeats: Int) -> Int {
        guard start < count else { return start }
        var end = start
        let category = category(at: start)
        while end < count - 1, self.category(at: end + 1) == category { end += 1 }
        return repeats > 1 ? wordEnd(end, count: repeats - 1) : end
    }

    func innerWord(_ start: Int) -> Range<Int> {
        guard start < count, !characters[start].isNewline else { return start..<start }
        let category = category(at: start)
        var lower = start
        var upper = start + 1
        while lower > 0, !characters[lower - 1].isNewline, self.category(at: lower - 1) == category { lower -= 1 }
        while upper < count, !characters[upper].isNewline, self.category(at: upper) == category { upper += 1 }
        return lower..<upper
    }
}
