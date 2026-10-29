import AppKit
import SableCore

/// The review editor's NSTextView. It renders engine snapshots and routes every
/// input path through `ReviewEditorAdapter`: typing, menu and context-menu
/// paste/cut, drag and drop, IME composition, and selection changes.
///
/// It is built on an explicit TextKit 1 stack (see `ReviewEditorView`). TextKit 1
/// provides temporary attributes, used for the block caret and the search match,
/// and line-fragment geometry, used for display-line j/k and the Visual Line band.
final class ReviewTextView: NSTextView, ReviewTextSurface {
    var adapter: ReviewEditorAdapter?
    /// Reports the laid-out text height whenever it changes, so the overlay can
    /// grow the editor (top-anchored) up to its cap.
    var onContentHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = -1
    private var resignKeyObserver: NSObjectProtocol?

    /// The engine's Visual Line selection as drawn: the selected characters plus
    /// whether the band covers the empty line after a trailing newline. That
    /// line has no characters, so the half-open selection alone can't show it.
    struct LineBand: Equatable {
        var range: NSRange
        var includesTrailingEmptyLine: Bool
    }

    private(set) var lineBand: LineBand?
    /// The native highlight for Normal-to-Visual character selections.
    static let characterSelectionAttributes: [NSAttributedString.Key: Any] = [
        .backgroundColor: OverlayTheme.selectionNS,
    ]

    /// Attributes for every character. The editor is plain text in a single style.
    static var editorAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = OverlayTheme.Metric.editorLineHeight
        paragraph.maximumLineHeight = OverlayTheme.Metric.editorLineHeight
        return [
            .font: NSFont.monospacedSystemFont(ofSize: OverlayTheme.Metric.editorFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    // MARK: ReviewTextSurface

    var surfaceText: String { string }
    var surfaceSelectedRange: NSRange { selectedRange() }
    var surfaceHasMarkedText: Bool { hasMarkedText() }

    func surfaceReplaceCharacters(in range: NSRange, with string: String) {
        guard let storage = textStorage else { return }
        // Direct storage edits bypass shouldChangeText/didChangeText, so applying a
        // snapshot never looks like a native edit.
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: Self.editorAttributes))
        storage.endEditing()
    }

    func surfaceSetSelectedRange(_ range: NSRange) {
        setSelectedRange(range)
        scrollRangeToVisible(range)
    }

    func surfaceRender(_ state: EditorState) {
        guard let layoutManager else { return }
        let length = (string as NSString).length
        let all = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.backgroundColor, .underlineStyle, .underlineColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: all)
        }
        renderLineBand(Self.lineBand(for: state))
        if let search = state.search, search.isActive, let match = search.match, !match.isEmpty {
            // Incsearch: tint the current match under the caret block (added after).
            let range = GraphemeRangeMapper.nsRange(
                for: EditorSelection(anchor: match.lowerBound, head: match.upperBound), in: state.text
            )
            layoutManager.addTemporaryAttributes([
                .backgroundColor: OverlayTheme.searchMatchNS,
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: OverlayTheme.searchUnderlineNS,
            ], forCharacterRange: range)
        }
        switch state.mode {
        case .normal:
            if let cell = Self.blockRange(at: state.activeCursor, in: state.text) {
                // A background on the cursor's grapheme reads as a block caret. It is
                // redrawn reliably by TextKit and doesn't blink.
                layoutManager.addTemporaryAttribute(.backgroundColor, value: OverlayTheme.caretBlockNS, forCharacterRange: cell)
                insertionPointColor = .clear
            } else {
                // Empty line or end of text: there's no glyph to tint, so use a bar.
                insertionPointColor = OverlayTheme.insertCaretNS
            }
        case .visual:
            // The selection highlight plus a block on the engine's active cell. A
            // collapsed selection (a click inside Visual, `v` on an empty line)
            // would otherwise show no cursor at all. In Visual Line the active cell
            // is the caret inside its line, not either end of the line range.
            if let cell = Self.blockRange(at: state.activeCursor, in: state.text) {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: OverlayTheme.caretBlockNS, forCharacterRange: cell)
                insertionPointColor = .clear
            } else {
                insertionPointColor = state.selection.isEmpty ? OverlayTheme.insertCaretNS : .clear
            }
        case .insert:
            insertionPointColor = OverlayTheme.insertCaretNS
        }
        needsDisplay = true
        reportContentHeight()
    }

    func surfaceDisplayLineTarget(from utf16Offset: Int, down: Bool, goalX: inout CGFloat?) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let length = (string as NSString).length
        guard length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let lineRect: NSRect
        let x: CGFloat
        if utf16Offset >= length, layoutManager.extraLineFragmentTextContainer != nil {
            // The empty line after a trailing newline has no glyph. It is TextKit's
            // extra line fragment, not the line holding the final newline.
            lineRect = layoutManager.extraLineFragmentRect
            x = goalX ?? lineRect.minX
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(utf16Offset, length - 1))
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = goalX ?? (lineRect.minX + layoutManager.location(forGlyphAt: glyph).x)
        }
        goalX = x
        let used = layoutManager.usedRect(for: textContainer)
        let y = down ? lineRect.maxY + 1 : lineRect.minY - 1
        guard y >= used.minY, y < used.maxY else { return nil }
        let targetGlyph = layoutManager.glyphIndex(for: NSPoint(x: x, y: y), in: textContainer)
        let targetRect = layoutManager.lineFragmentRect(forGlyphAt: targetGlyph, effectiveRange: nil)
        // Landing on the same fragment (e.g. a trailing empty line) means there is
        // no real display line there; let the engine's logical motion decide.
        guard targetRect.minY != lineRect.minY else { return nil }
        return layoutManager.characterIndexForGlyph(at: targetGlyph)
    }

    /// The band for a Visual Line state, or nil for every other mode. The range is
    /// the engine's selection verbatim; the trailing empty line is included when
    /// either end of the selection (anchor or active cell) sits on it.
    static func lineBand(for state: EditorState) -> LineBand? {
        guard state.mode == .visual, state.visualSelectionKind == .line else { return nil }
        let count = state.text.count
        let endsOnEmptyLine = state.text.isEmpty || state.text.last?.isNewline == true
        let reachesEnd = max(state.activeCursor, state.visualAnchor ?? state.activeCursor) >= count
        return LineBand(
            range: GraphemeRangeMapper.nsRange(for: state.selection, in: state.text),
            includesTrailingEmptyLine: endsOnEmptyLine && reachesEnd
        )
    }

    /// Line mode swaps NSTextView's selection highlight for a full-width band, so
    /// partial and final lines read as whole lines and alpha never doubles. The
    /// native selection stays set, so ⌘C still copies exactly the selected lines.
    private func renderLineBand(_ band: LineBand?) {
        guard band != lineBand else { return }
        if (band == nil) != (lineBand == nil) {
            selectedTextAttributes = band == nil
                ? Self.characterSelectionAttributes
                : [.backgroundColor: NSColor.clear]
        }
        lineBand = band
        needsDisplay = true
    }

    /// View-coordinate rects of the Visual Line band: one full-width rect per line
    /// fragment the selection covers (wrapped fragments and blank lines included),
    /// plus TextKit's extra line fragment for a trailing empty line.
    func lineBandRects() -> [NSRect] {
        guard let band = lineBand, let layoutManager, let textContainer else { return [] }
        layoutManager.ensureLayout(for: textContainer)
        var rects: [NSRect] = []
        if band.range.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: band.range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                rects.append(rect)
            }
        }
        if band.includesTrailingEmptyLine, layoutManager.extraLineFragmentTextContainer != nil {
            rects.append(layoutManager.extraLineFragmentRect)
        }
        let origin = textContainerOrigin
        return rects.map { NSRect(x: origin.x, y: $0.minY + origin.y, width: textContainer.size.width, height: $0.height) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Drawn first so glyphs, the caret block and the match tint sit on top.
        if lineBand != nil {
            OverlayTheme.selectionNS.setFill()
            for rect in lineBandRects() where rect.intersects(dirtyRect) {
                rect.fill(using: .sourceOver)
            }
        }
        super.draw(dirtyRect)
    }

    /// UTF-16 range of the grapheme cell at `offset`, or nil on an empty line or
    /// past the end of the text, where there is no glyph to draw a block on.
    static func blockRange(at offset: Int, in text: String) -> NSRange? {
        guard offset >= 0, offset < text.count else { return nil }
        let character = text[text.index(text.startIndex, offsetBy: offset)]
        guard !character.isNewline else { return nil }
        let location = GraphemeRangeMapper.utf16Offset(forGrapheme: offset, in: text)
        return NSRange(location: location, length: character.utf16.count)
    }

    func reportContentHeight() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onContentHeightChange?(height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { reportContentHeight() }
    }

    // MARK: Key input

    override func keyDown(with event: NSEvent) {
        guard let adapter else { return super.keyDown(with: event) }
        let translation = hasMarkedText() ? nil : ReviewKeyTranslator.translate(event)
        switch adapter.handleKey(translation, timestamp: event.timestamp) {
        case .consumed:
            return
        case .native:
            adapter.performNative { super.keyDown(with: event) }
        }
    }

    /// ⌘Z, ⌘⇧Z and ⌘⏎ belong to the engine. The main menu's Undo/Redo would
    /// otherwise claim ⌘Z before keyDown, so intercept them here, first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard adapter != nil, window?.firstResponder === self,
              let translation = ReviewKeyTranslator.translate(event),
              translation.modifiers.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch translation.key {
        case .enter:
            if hasMarkedText() {
                // Commit the composition so the engine has every native character
                // before it delivers.
                adapter?.performNative {
                    unmarkText()
                    inputContext?.discardMarkedText()
                }
            }
            keyDown(with: event)
            return true
        case .character("z"), .character("Z"):
            keyDown(with: event)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    @objc func undo(_ sender: Any?) {
        sendCommand(.character("z"), [.command])
    }

    @objc func redo(_ sender: Any?) {
        sendCommand(.character("z"), [.command, .shift])
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) || item.action == #selector(redo(_:)) {
            return adapter != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    private func sendCommand(_ key: EditorKey, _ modifiers: EditorModifiers) {
        _ = adapter?.handleKey(
            ReviewKeyTranslator.Translation(key: key, modifiers: modifiers),
            timestamp: ProcessInfo.processInfo.systemUptime
        )
    }

    // MARK: Out-of-band native edits

    override func paste(_ sender: Any?) {
        nativeEdit(.paste) { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        nativeEdit(.paste) { super.pasteAsPlainText(sender) }
    }

    override func pasteAsRichText(_ sender: Any?) {
        nativeEdit(.paste) { super.pasteAsPlainText(sender) }
    }

    override func cut(_ sender: Any?) {
        nativeEdit(.cut) { super.cut(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let adapter else { return super.performDragOperation(sender) }
        guard adapter.allowsNativeEdit(.drop) else { return false }
        var accepted = false
        adapter.performNative(flushFirst: true) { accepted = super.performDragOperation(sender) }
        return accepted
    }

    private func nativeEdit(_ kind: ReviewEditorAdapter.NativeEditKind, _ body: () -> Void) {
        guard let adapter else { return body() }
        guard adapter.allowsNativeEdit(kind) else { return }
        adapter.performNative(flushFirst: true, body)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let adapter, !adapter.allowsNativeTextChange { return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func didChangeText() {
        super.didChangeText()
        adapter?.textDidChangeOutOfBand()
    }

    // MARK: Selection, composition, focus

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        adapter?.selectionDidChange(stillSelecting: stillSelecting)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if !hasMarkedText() { adapter?.willBeginComposition() }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { adapter?.focusDidResign() }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The panel resigning key doesn't make this view resign first responder,
        // so treat it as a blur too.
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.adapter?.focusDidResign() }
        }
    }
}
