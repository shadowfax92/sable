import AppKit
import SableCore
import SwiftUI

/// SwiftUI bridge for the review editor shown in `OverlayModel.Phase.review`.
///
/// SKELETON: this renders the session's text read-only and handles no keys. No
/// production path reaches it yet, because the coordinator never calls
/// `OverlayModel.presentReview`. The overlay piece replaces the internals with
/// the native adapter below, keeping this type's name and its `session` input.
///
/// Adapter contract (see fast-rewrite/editor-report.md and ux-design.md §6):
/// - keyDown with marked text (IME): `flushPendingInput`, then native handling,
///   then a single `nativeUpdate`. Never intercept keys while composing.
/// - Other keys become `.key(..., timestamp: monotonic)` and go to `session.send`:
///   - `.handled` / `.unsupported` / nil: consume the key and render the snapshot.
///   - `.passToNative`: let NSTextView handle the key, then send exactly ONE
///     `nativeUpdate(text:selection:)` with the real native text and selection.
/// - Don't send a separate `setSelection` for a native edit's own selection
///   change; that would disarm jk/jj. Suppress selection callbacks while applying
///   engine snapshots. Mouse clicks, Cmd-A and display-line moves are separate
///   changes and use `setSelection` (an additive editor event).
/// - Send `flushPendingInput` before IME starts, before paste/drop, on resign key,
///   and before delivery.
/// - `NSTextView.allowsUndo = false`: the engine owns undo, including Cmd-Z.
/// - Map ranges only through `GraphemeRangeMapper`.
struct ReviewEditorView: NSViewRepresentable {
    @ObservedObject var session: ReviewSession

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = false
            textView.allowsUndo = false
            textView.drawsBackground = false
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = session.state.text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != session.state.text else { return }
        textView.string = session.state.text
    }
}
