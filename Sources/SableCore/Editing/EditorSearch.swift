import Foundation

/// A literal search index in the same Character coordinate space as editing.
/// Foundation supplies Unicode case/canonical comparison; only complete native
/// graphemes can become results. Search never normalizes or rewrites the buffer.
struct EditorSearchMatches {
    let ranges: [Range<Int>]

    init(text: String, query: String) {
        guard !query.isEmpty else { ranges = []; return }
        let boundaries = Array(text.indices) + [text.endIndex]
        let offsets = Dictionary(uniqueKeysWithValues: boundaries.enumerated().map { ($0.element, $0.offset) })
        let smartcase = query.unicodeScalars.contains { $0.properties.isUppercase || $0.properties.generalCategory == .titlecaseLetter }
        let options: String.CompareOptions = smartcase ? [.anchored] : [.anchored, .caseInsensitive]
        let locale = Locale(identifier: "en_US_POSIX")
        var matches: [Range<Int>] = []
        // Anchoring at each Character boundary includes overlapping results
        // (aa in aaa), while rejecting a prefix inside an emoji or combining
        // sequence. Fixed locale keeps results independent of the user's region.
        for (offset, start) in boundaries.dropLast().enumerated() {
            if let range = text.range(of: query, options: options, range: start..<text.endIndex, locale: locale),
               range.lowerBound == start, let end = offsets[range.upperBound], end > offset {
                matches.append(offset..<end)
            }
        }
        ranges = matches
    }

    /// Strict next/previous match start, wrapping at either end. Counts are
    /// bounded by the parser and resolved arithmetically, including full cycles.
    func next(from cursor: Int, direction: EditorSearchDirection, count: Int) -> (range: Range<Int>, didWrap: Bool)? {
        guard !ranges.isEmpty else { return nil }
        let first: Int
        let wrappedInitially: Bool
        if direction == .forward {
            let next = ranges.firstIndex { $0.lowerBound > cursor }
            first = next ?? 0
            wrappedInitially = next == nil
        } else {
            let next = ranges.lastIndex { $0.lowerBound < cursor }
            first = next ?? (ranges.count - 1)
            wrappedInitially = next == nil
        }
        let delta = max(1, count) - 1
        let unwrapped = direction == .forward ? first + delta : first - delta
        let index = ((unwrapped % ranges.count) + ranges.count) % ranges.count
        return (ranges[index], wrappedInitially || unwrapped < 0 || unwrapped >= ranges.count)
    }
}
