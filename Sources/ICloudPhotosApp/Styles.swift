#if canImport(SwiftUI) && os(macOS)
import SwiftUI

// The app draws its own look, but on top of the system's controls: these styles dress a native
// ProgressView, Gauge, DisclosureGroup, Toggle and LabeledContent, so keyboard focus, VoiceOver
// and state come from the system while the pixels stay ours.

// MARK: Progress

/// A capsule bar: a soft track with a filled part. Height and fill are the caller's.
struct CapsuleProgressStyle: ProgressViewStyle {
    var height: CGFloat = 14
    var fill: AnyShapeStyle = AnyShapeStyle(LinearGradient(colors: [Color(red: 0.04, green: 0.34, blue: 0.84),
                                                                    Color(red: 0.24, green: 0.55, blue: 1)],
                                                           startPoint: .leading, endPoint: .trailing))
    /// The smallest filled width, so a bar that has just started still shows it has.
    var minimumFill: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            Capsule().fill(Color.white.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(minimumFill, geo.size.width * CGFloat(configuration.fractionCompleted ?? 0)))
                }
        }
        .frame(height: height)
    }
}

/// An icon-sized ring: filled to the fraction, or spinning while there is none yet.
struct RingProgressStyle: ProgressViewStyle {
    var size: CGFloat = 15
    var lineWidth: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        Ring(fraction: configuration.fractionCompleted, size: size, lineWidth: lineWidth)
    }

    private struct Ring: View {
        let fraction: Double?
        let size: CGFloat
        let lineWidth: CGFloat
        @State private var spins = false

        var body: some View {
            ZStack {
                Circle().stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction.map { max(0.03, $0) } ?? 0.3)
                    .stroke(Theme.accentSoft, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(fraction == nil && spins ? 270 : -90))
                    .animation(fraction == nil ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .smooth(duration: 0.3),
                               value: spins)
            }
            .frame(width: size, height: size)
            .onAppear { spins = true }
        }
    }
}

// MARK: Capacity

/// A thin bar for how full a disk is: the used part, and inside it the part our photos take.
struct CapacityBarStyle: GaugeStyle {
    var height: CGFloat = 6
    /// The share of the whole disk the photos take, drawn in the accent at the start of the bar.
    var photos: Double?
    var used: Color = Color.white.opacity(0.26)

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 1) {
                if let photos {
                    Rectangle().fill(Theme.accent).frame(width: max(2, width * photos))
                    Rectangle().fill(used).frame(width: max(0, width * (configuration.value - photos)))
                } else {
                    Rectangle().fill(used).frame(width: width * configuration.value)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.white.opacity(0.08))
        .clipShape(.capsule)
    }
}

// MARK: Fold-outs

/// A fold-out in a card: its title and a turning chevron as the header, the content under a hairline.
struct CardDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.smooth(duration: 0.2)) { configuration.isExpanded.toggle() } } label: {
                HStack {
                    configuration.label.font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 0 : -90))
                }
                .foregroundStyle(Color(white: 0.8))
                .padding(.horizontal, 18)
                .frame(height: 46)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                VStack(spacing: 0) {
                    CardDivider()
                    configuration.content
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
        }
        .panel(cornerRadius: 16, fill: Color.white.opacity(0.02), stroke: Color.white.opacity(0.07))
    }
}

/// A quiet text fold-out ("Show details"): a small label with a chevron, the content below it.
struct LinkDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.smooth(duration: 0.2)) { configuration.isExpanded.toggle() } } label: {
                HStack(spacing: 6) {
                    configuration.label
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 0 : -90))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 4)
                .frame(height: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if configuration.isExpanded {
                configuration.content.transition(.opacity)
            }
        }
    }
}

// MARK: Toggles and rows

/// An on-off capsule with a tick or a plus, for choosing what to include.
struct ChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: configuration.isOn ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                configuration.label.lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isOn ? Color.white : Theme.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(configuration.isOn ? Theme.accent.opacity(0.24) : Color.white.opacity(0.04), in: .capsule)
            .overlay(Capsule().strokeBorder(configuration.isOn ? Theme.accent.opacity(0.7) : Color.white.opacity(0.12)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

/// A row of a settings card: the label (a title, maybe a line under it) on the left, the control on
/// the right.
struct SettingRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    }
}
#endif
