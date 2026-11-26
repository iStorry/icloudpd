#if canImport(SwiftUI) && os(macOS)
import SwiftUI

/// The app's dark "gallery" look: a near-black window, translucent panels and one blue accent.
enum Theme {
    static let background = Color(red: 0.047, green: 0.047, blue: 0.055)
    static let sheet = Color(red: 0.094, green: 0.094, blue: 0.106)
    static let accent = Color(red: 0.031, green: 0.4, blue: 0.961)
    /// The accent lightened for text and icons on the dark ground.
    static let accentSoft = Color(red: 0.43, green: 0.7, blue: 1)
    static let secondary = Color(white: 0.64)
    static let tertiary = Color(white: 0.6)
    static let panelFill = Color.white.opacity(0.05)
    static let panelStroke = Color.white.opacity(0.09)
    static let fieldFill = Color.white.opacity(0.06)
    static let fieldStroke = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.07)
    static let danger = Color(red: 0.79, green: 0.153, blue: 0.106)
    static let dangerSoft = Color(red: 1, green: 0.71, blue: 0.66)
    static let warning = Color(red: 1, green: 0.7, blue: 0.25)
}

extension View {
    /// The floating sidebar panel in the window's top-left corner. The window buttons are moved
    /// inside it (see `WindowButtons`), so its content starts below them.
    func sidebarColumn(width: CGFloat) -> some View {
        padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, WindowButtons.clearance)
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .top)
            .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
    }

    /// A translucent rounded panel with a hairline edge.
    func panel(cornerRadius: CGFloat = 16, fill: Color = Theme.panelFill, stroke: Color = Theme.panelStroke) -> some View {
        background(fill, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(stroke))
    }
}

// MARK: Buttons

/// Capsule buttons: the blue primary action, a quiet secondary one and a red destructive one.
struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var height: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        Pill(kind: kind, height: height, configuration: configuration)
    }

    private struct Pill: View {
        let kind: Kind
        let height: CGFloat
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        private var isLarge: Bool { height >= 40 }

        var body: some View {
            configuration.label
                .font(.system(size: isLarge ? 15 : 13, weight: kind == .secondary ? .medium : .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, isLarge ? 24 : 12)
                .frame(height: height)
                .background(fill, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.white.opacity(kind == .secondary ? 0.14 : 0)))
                .shadow(color: kind == .primary && isEnabled && isLarge ? Theme.accent.opacity(0.4) : .clear, radius: 14, y: 8)
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
                .contentShape(.capsule)
        }

        private var fill: Color {
            switch kind {
            case .primary: return Theme.accent
            case .secondary: return Color.white.opacity(0.08)
            case .destructive: return Theme.danger
            }
        }
    }
}

/// The small round icon button used in the sidebar header.
struct CircleIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 32, height: 32)
            .background(Theme.fieldFill, in: .circle)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.1)))
            .contentShape(.circle)
    }
}

// MARK: Cards and rows

/// Small capitals label above a card.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 4)
    }
}

/// A panel whose rows are separated by hairlines.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(subviews) { subview in
                    subview
                    if subview.id != subviews.last?.id {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
        }
        .panel()
    }
}

struct CardRow<Content: View>: View {
    var minHeight: CGFloat = 40
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
    }
}

/// A text field with its label above it, in the rounded well the sign-in screens use.
struct LabeledField<Content: View>: View {
    let title: String
    var isFocused: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            content
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Theme.fieldFill, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isFocused ? Theme.accent : Theme.fieldStroke))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Theme.accent.opacity(isFocused ? 0.28 : 0), lineWidth: 4)
                    .padding(-3))
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(Theme.dangerSoft)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(cornerRadius: 14, fill: Theme.danger.opacity(0.14), stroke: Theme.dangerSoft.opacity(0.3))
    }
}

/// The square glass tile holding a symbol at the top of the verification screens.
struct HeroTile: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .regular))
            .frame(width: 72, height: 72)
            .panel(cornerRadius: 22, fill: Theme.fieldFill, stroke: Theme.fieldStroke)
            .shadow(color: .black.opacity(0.5), radius: 20, y: 16)
    }
}
#endif
