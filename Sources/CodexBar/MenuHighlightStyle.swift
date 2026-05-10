import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var menuItemHighlighted: Bool = false
}

enum MenuHighlightStyle {
    static let selectionText = Color(nsColor: .controlTextColor)
    static let normalPrimaryText = Color(nsColor: .controlTextColor)
    static let normalSecondaryText = Color(nsColor: .secondaryLabelColor)

    static func primary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalPrimaryText
    }

    static func secondary(_ highlighted: Bool) -> Color {
        highlighted ? self.selectionText : self.normalSecondaryText
    }

    static func error(_ highlighted: Bool) -> Color {
        Color(nsColor: .systemRed)
    }

    static func progressTrack(_ highlighted: Bool) -> Color {
        Color(nsColor: .tertiaryLabelColor).opacity(highlighted ? 0.32 : 0.22)
    }

    static func progressTint(_ highlighted: Bool, fallback: Color) -> Color {
        fallback
    }

    static func selectionBackground(_ highlighted: Bool) -> Color {
        highlighted ? CodexBarOrangeTheme.selectionBackgroundColor : .clear
    }
}

enum CodexBarOrangeTheme {
    static let selectionBackgroundNSColor = NSColor(
        calibratedRed: 1.00,
        green: 0.88,
        blue: 0.68,
        alpha: 1)
    static let selectionHoverNSColor = NSColor(
        calibratedRed: 1.00,
        green: 0.92,
        blue: 0.80,
        alpha: 1)
    static let selectionTextNSColor = NSColor(
        calibratedRed: 0.30,
        green: 0.16,
        blue: 0.05,
        alpha: 1)
    static let actionNSColor = NSColor(
        calibratedRed: 0.79,
        green: 0.28,
        blue: 0.05,
        alpha: 1)
    static let actionSecondaryNSColor = NSColor(
        calibratedRed: 0.91,
        green: 0.43,
        blue: 0.10,
        alpha: 1)

    static let selectionBackgroundColor = Color(nsColor: selectionBackgroundNSColor)
    static let selectionHoverColor = Color(nsColor: selectionHoverNSColor)
    static let selectionTextColor = Color(nsColor: selectionTextNSColor)
    static let actionColor = Color(nsColor: actionNSColor)
    static let actionSecondaryColor = Color(nsColor: actionSecondaryNSColor)
}
