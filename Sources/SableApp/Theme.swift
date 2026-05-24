import SwiftUI

/// Clean light-only design system for Sable's main window, modeled on Riff's
/// token approach but trimmed to a single light palette.
enum Theme {
    enum Palette {
        static let windowBackground = Color(red: 0.98, green: 0.98, blue: 0.99)
        static let sidebarBackground = Color(red: 0.965, green: 0.965, blue: 0.975)
        static let detailBackground = Color.white
        static let card = Color.white
        static let cardStroke = Color.black.opacity(0.08)
        static let code = Color(red: 0.965, green: 0.968, blue: 0.976)
        static let codeStroke = Color.black.opacity(0.07)
        static let separator = Color.black.opacity(0.08)
        static let rowSelected = Color.accentColor.opacity(0.14)
        static let chip = Color.black.opacity(0.05)

        static let ok = Color(red: 0.18, green: 0.64, blue: 0.34)
        static let warn = Color(red: 0.85, green: 0.53, blue: 0.06)
        static let error = Color(red: 0.83, green: 0.24, blue: 0.20)
        static let running = Color(red: 0.0, green: 0.48, blue: 1.0)
    }

    enum Metric {
        static let rowCorner: CGFloat = 8
        static let cardCorner: CGFloat = 12
        static let codeCorner: CGFloat = 10
        static let sidebarWidth: CGFloat = 300
    }
}
