import AppKit
import SableCore

/// The review editor's NSTextView. It renders engine snapshots and routes every
/// input path through `ReviewEditorAdapter`: typing, menu and context-menu
/// paste/cut, drag and drop, IME composition, and selection changes.
///
/// It is built on an explicit TextKit 1 stack (see `ReviewEditorView`). TextKit 1
/// provides temporary attributes, used for the Normal-mode block caret, and
/// line-fragment geometry, used for display-line j/k.
final class ReviewTextView: NSTextView, ReviewTextSurface {
    var adapter: ReviewEditorAdapter?
    /// Reports the laid-out text height whenever it changes, so the overlay can
    /// grow the editor (top-anchored) up to its cap.
    var onContentHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = -1
    private var resignKeyObserver: NSObjectProtocol?

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
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        switch state.mode {
        case .normal:
            if let cell = Self.blockRange(for: state) {
                // A background on the cursor's grapheme reads as a block caret. It is
                // redrawn reliably by TextKit and doesn't blink.
                layoutManager.addTemporaryAttribute(.backgroundColor, value: OverlayTheme.caretBlockNS, forCharacterRange: cell)
                insertionPointColor = .clear
            } else {
                // Empty line or end of text: there's no glyph to tint, so use a bar.
                insertionPointColor = OverlayTheme.insertCaretNS
            }
        case .visual:
            insertionPointColor = .clear
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
        let glyph = layoutManager.glyphIndexForCharacter(at: min(utf16Offset, length - 1))
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = goalX ?? (lineRect.minX + layoutManager.location(forGlyphAt: glyph).x)
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

    /// UTF-16 range of the grapheme under the Normal-mode cursor, or nil on an
    /// empty line or past the end of the text.
    static func blockRange(for state: EditorState) -> NSRange? {
        let text = state.text
        guard state.cursor < text.count else { return nil }
        let character = text[text.index(text.startIndex, offsetBy: state.cursor)]
        guard !character.isNewline else { return nil }
        let location = GraphemeRangeMapper.utf16Offset(forGrapheme: state.cursor, in: text)
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
