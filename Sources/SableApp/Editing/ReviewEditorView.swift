import AppKit
import SableCore
import SwiftUI

/// SwiftUI bridge for the review editor shown in `OverlayModel.Phase.review`.
///
/// Builds a `ReviewTextView` on an explicit TextKit 1 stack and binds one
/// `ReviewEditorAdapter` per `ReviewSession`. A new session (a new interaction)
/// gets a fresh adapter. The adapter re-applies the engine snapshot on every
/// SwiftUI update; that is idempotent and skipped mid-transaction.
///
/// Focus: the text view becomes first responder only when the panel is already
/// key. A review that completes after the user clicked away therefore never
/// re-keys the panel or activates Sable.
struct ReviewEditorView: NSViewRepresentable {
    @ObservedObject var session: ReviewSession
    /// `OverlayModel.focusNonce`; a change asks for first responder again.
    var focusNonce: Int = 0
    var onContentHeightChange: (CGFloat) -> Void = { _ in }

    final class Coordinator {
        var adapter: ReviewEditorAdapter?
        var focusNonce: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Builds the configured TextKit 1 text view. Shared with headless tests,
    /// which drive the same view windowlessly.
    static func makeTextView() -> ReviewTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 2
        layoutManager.addTextContainer(container)

        // Start at the editor's real width so the first height report isn't a
        // zero-width, one-glyph-per-line layout that would flash the panel tall.
        let width = OverlayTheme.Metric.width - OverlayTheme.Metric.padding * 2
        let textView = ReviewTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0), textContainer: container)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: OverlayTheme.Metric.editorInset, height: OverlayTheme.Metric.editorInset)
        textView.typingAttributes = ReviewTextView.editorAttributes
        textView.selectedTextAttributes = [.backgroundColor: OverlayTheme.selectionNS]
        // Substitutions would make native text diverge from what was typed, and
        // the engine verifies native transactions exactly (jk/jj rollback).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false

        return textView
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView()
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        bind(textView, context: context)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ReviewTextView else { return }
        textView.onContentHeightChange = onContentHeightChange
        if context.coordinator.adapter?.session !== session {
            bind(textView, context: context)
        } else {
            context.coordinator.adapter?.applySnapshot()
        }
        if context.coordinator.focusNonce != focusNonce {
            context.coordinator.focusNonce = focusNonce
            focusIfPanelIsKey(textView)
        }
    }

    private func bind(_ textView: ReviewTextView, context: Context) {
        let adapter = ReviewEditorAdapter(session: session, surface: textView)
        context.coordinator.adapter = adapter
        textView.adapter = adapter
        textView.onContentHeightChange = onContentHeightChange
        adapter.applySnapshot()
        context.coordinator.focusNonce = focusNonce
        focusIfPanelIsKey(textView)
    }

    private func focusIfPanelIsKey(_ textView: ReviewTextView) {
        DispatchQueue.main.async { [weak textView] in
            guard let textView, let window = textView.window, window.isKeyWindow,
                  window.firstResponder !== textView else { return }
            window.makeFirstResponder(textView)
        }
    }
}
