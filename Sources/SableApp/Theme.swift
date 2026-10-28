import AppKit
import SwiftUI

/// Shared design tokens for Sable's utility window and floating overlay.
///
/// Every color resolves against the appearance of the view that draws it, so
/// the utility window follows the system light/dark setting. A window that pins
/// its own appearance (the overlay panel did, as of the UI-contracts PR) gets the
/// matching variant. `Palette` and `Overlay` member names are a compatibility
/// surface for overlay code that predates these adaptive values; keep them.
enum Theme {
    enum Palette {
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let sidebarBackground = Color.adaptive(light: .init(white: 0.965, alpha: 1), dark: .init(white: 0.14, alpha: 1))
        static let detailBackground = Color(nsColor: .textBackgroundColor)
        static let card = Color(nsColor: .controlBackgroundColor)
        static let cardStroke = Color.hairline
        static let code = Color.adaptive(
            light: NSColor(red: 0.965, green: 0.968, blue: 0.976, alpha: 1),
            dark: NSColor(white: 1, alpha: 0.05)
        )
        static let codeStroke = Color.adaptive(light: .init(white: 0, alpha: 0.07), dark: .init(white: 1, alpha: 0.08))
        static let separator = Color.hairline
        static let rowSelected = Accent.wash
        static let chip = Color.adaptive(light: .init(white: 0, alpha: 0.05), dark: .init(white: 1, alpha: 0.08))

        static let ok = Color(nsColor: .systemGreen)
        static let warn = Color(nsColor: .systemOrange)
        static let error = Color(nsColor: .systemRed)
        static let running = Color(nsColor: .systemBlue)
    }

    /// Floating popup palette. The overlay piece owns its own tokens going
    /// forward (`Overlay/OverlayTheme.swift`); these stay so existing overlay
    /// views keep compiling and render correctly in either appearance.
    enum Overlay {
        static let panel = Color.adaptive(light: .white, dark: NSColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1))
        static let panelStroke = Color.adaptive(light: .init(white: 0, alpha: 0.10), dark: .init(white: 1, alpha: 0.12))
        static let field = Color.adaptive(light: .init(white: 0, alpha: 0.035), dark: .init(white: 1, alpha: 0.06))
        static let fieldStroke = Color.adaptive(light: .init(white: 0, alpha: 0.08), dark: .init(white: 1, alpha: 0.10))
        static let chip = Color.adaptive(light: .init(white: 0, alpha: 0.055), dark: .init(white: 1, alpha: 0.08))
        static let textPrimary = Color(nsColor: .labelColor)
        static let textSecondary = Color(nsColor: .secondaryLabelColor)
        static let textTertiary = Color(nsColor: .tertiaryLabelColor)
        static let accent = Color.accentColor
        static let ok = Palette.ok
        static let error = Palette.error
    }

    /// The warm amber accent shared by the overlay and the utility window (Focus
    /// amber, ux-design §9). Use it for Sable's own glyphs, washes and carets.
    /// Native controls keep the system accent, so don't apply it as `.tint`.
    enum Accent {
        /// `#FFAA28`. Fills and washes only; too light for text on white.
        static let fill = Color(nsColor: NSColor(red: 1, green: 0xAA / 255, blue: 0x28 / 255, alpha: 1))
        /// Text and glyphs: `#A35F00` in light (about 5:1 on white), `#FFC86E` in dark.
        static let ink = Color.adaptive(
            light: NSColor(red: 0xA3 / 255, green: 0x5F / 255, blue: 0, alpha: 1),
            dark: NSColor(red: 1, green: 0xC8 / 255, blue: 0x6E / 255, alpha: 1)
        )
        /// Highlighted-row wash.
        static let wash = fill.opacity(0.16)
        /// Text selection.
        static let selection = fill.opacity(0.28)
    }

    enum Metric {
        static let rowCorner: CGFloat = 8
        static let cardCorner: CGFloat = 12
        static let codeCorner: CGFloat = 8
        static let sidebarWidth: CGFloat = 220
        static let overlayWidth: CGFloat = 620
        static let overlayCorner: CGFloat = 16
    }
}

extension Color {
    /// A color that picks its light or dark variant at draw time from the
    /// drawing view's effective appearance, not from a value captured at launch.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// Black 8% in light, white 10% in dark.
    static let hairline = Color.adaptive(light: .init(white: 0, alpha: 0.08), dark: .init(white: 1, alpha: 0.10))
}
