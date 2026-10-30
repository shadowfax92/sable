import AppKit
import SwiftUI

/// Overlay-private design tokens. They are adaptive (light/dark follow the
/// panel's effective appearance) and independent of the app-wide `Theme`,
/// which the utility window owns. The warm accent is borrowed from the Focus
/// HUD's amber; fills use it directly, while text uses a darker or lighter ink
/// so small labels stay legible in both appearances.
enum OverlayTheme {
    enum Metric {
        static let width: CGFloat = 600
        static let padding: CGFloat = 14
        static let corner: CGFloat = 16
        static let rowHeight: CGFloat = 32
        static let maxVisibleRows = 7
        /// Transparent margin around the panel so its shadow is not clipped.
        static let shadowMargin: CGFloat = 24
        static let editorFontSize: CGFloat = 13
        static let editorLineHeight: CGFloat = 18
        static let editorInset: CGFloat = 8
        static let editorMaxHeight: CGFloat = 440
    }

    // MARK: AppKit colors (shared by SwiftUI and the native review editor)

    static let accentFillNS = NSColor(srgbRed: 1.0, green: 0.667, blue: 0.157, alpha: 1) // #FFAA28
    static let accentInkNS = dynamic(
        light: NSColor(srgbRed: 0.639, green: 0.373, blue: 0.0, alpha: 1),               // #A35F00
        dark: NSColor(srgbRed: 1.0, green: 0.784, blue: 0.431, alpha: 1)                 // #FFC86E
    )
    /// Normal-mode block caret and Visual selection.
    static let caretBlockNS = accentFillNS.withAlphaComponent(0.55)
    static let selectionNS = accentFillNS.withAlphaComponent(0.30)
    /// The current search match while the query field is open (incsearch). The
    /// underline keeps it visible inside a Visual selection, whose highlight
    /// overrides background tints.
    static let searchMatchNS = accentFillNS.withAlphaComponent(0.22)
    static let searchUnderlineNS = accentInkNS
    static let insertCaretNS = dynamic(
        light: NSColor(srgbRed: 0.878, green: 0.541, blue: 0.0, alpha: 1),               // #E08A00
        dark: accentFillNS
    )

    // MARK: SwiftUI colors

    static let accentFill = Color(nsColor: accentFillNS)
    static let accentInk = Color(nsColor: accentInkNS)
    static let rowWash = accentFill.opacity(0.16)
    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color(nsColor: dynamic(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.10)
    ))
    static let chip = Color(nsColor: dynamic(
        light: NSColor.black.withAlphaComponent(0.055),
        dark: NSColor.white.withAlphaComponent(0.09)
    ))
    /// Laid over the behind-window blur to guarantee text contrast.
    static let panelTint = Color(nsColor: dynamic(
        light: NSColor.white.withAlphaComponent(0.72),
        dark: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.118, alpha: 0.70)
    ))
    /// Used instead of blur when Reduce Transparency is on.
    static let panelOpaque = Color(nsColor: dynamic(
        light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.975, alpha: 1),
        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.125, alpha: 1)
    ))
    static let editorSurface = Color(nsColor: dynamic(
        light: NSColor.white.withAlphaComponent(0.92),
        dark: NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 0.88)
    ))
    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    static let error = Color(nsColor: .systemRed)

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
