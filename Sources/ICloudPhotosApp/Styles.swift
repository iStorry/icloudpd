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
// MARK: Dates and numbers

/// A date as a pill ("26 Nov 2016"). Clicking it opens the system's calendar in a popover, so the
/// calendar never covers the rows around it.
struct DateButton: View {
    @Binding var date: Date
    var range: PartialRangeThrough<Date> = ...Date()
    var label: String?
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                .monospacedDigit()
        }
        .buttonStyle(PillButtonStyle(kind: .secondary, height: 30))
        .fixedSize()
        .accessibilityLabel(label.map { "\($0), \(date.formatted(date: .long, time: .omitted))" }
                            ?? date.formatted(date: .long, time: .omitted))
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            CalendarPicker(date: $date, latest: range.upperBound) { picking = false }
        }
    }
}

/// A month calendar in the app's look: the month and year as menus to jump far back, arrows for
/// the next and previous month, and big days to click. Clicking a day picks it.
struct CalendarPicker: View {
    @Binding var date: Date
    /// The last day that can be picked; later days are dimmed.
    var latest: Date = Date()
    var onPick: () -> Void = {}

    @State private var month: Date = Date()
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            weekdays
            days
        }
        .padding(18)
        .frame(width: 320)
        .background(Theme.sheet)
        .onAppear { month = startOfMonth(date) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(Array(calendar.monthSymbols.enumerated()), id: \.offset) { index, name in
                    Button(name) { setMonth(index + 1) }
                }
            } label: {
                Text(month.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 18, weight: .bold))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a month")

            Menu {
                ForEach(years, id: \.self) { year in
                    Button(String(year)) { setYear(year) }
                }
            } label: {
                Text(String(calendar.component(.year, from: month)))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.accentSoft)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a year")

            Spacer(minLength: 8)

            arrow("chevron.left", by: -1)
                .accessibilityLabel("Previous month")
            arrow("chevron.right", by: 1)
                .accessibilityLabel("Next month")
                .disabled(startOfMonth(latest) <= month)
        }
    }

    private func arrow(_ symbol: String, by months: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                month = calendar.date(byAdding: .month, value: months, to: month) ?? month
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(.circle)
        }
        .buttonStyle(CircleHoverStyle())
    }

    /// From this year back to 1990, and further back if the chosen date is older.
    private var years: [Int] {
        let newest = calendar.component(.year, from: latest)
        let oldest = min(1990, calendar.component(.year, from: date))
        return Array((oldest...newest).reversed())
    }

    // MARK: Grid

    private var weekdays: some View {
        HStack(spacing: 0) {
            ForEach(orderedWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private var days: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayButton(day)
                } else {
                    Color.clear.frame(height: 38)
                }
            }
        }
        .id(month)
        .transition(.opacity)
    }

    private func dayButton(_ day: Date) -> some View {
        let isChosen = calendar.isDate(day, inSameDayAs: date)
        let isToday = calendar.isDateInToday(day)
        let isLate = day > latest && !calendar.isDate(day, inSameDayAs: latest)
        return Button {
            // Keep the time of day the binding had: only the day changes.
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            date = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? day
            onPick()
        } label: {
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 14, weight: isChosen || isToday ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isChosen ? Color.white : isToday ? Theme.accentSoft : Color.primary)
                .frame(width: 36, height: 36)
                .background {
                    if isChosen {
                        Circle().fill(Theme.accent)
                    } else if isToday {
                        Circle().strokeBorder(Theme.accentSoft.opacity(0.6), lineWidth: 1.5)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .contentShape(.rect)
        }
        .buttonStyle(DayHoverStyle(isChosen: isChosen))
        .disabled(isLate)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// The days of the shown month, with blanks before the first so it falls on its weekday.
    private var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: month)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let days = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
        return Array(repeating: nil, count: leading) + days
    }

    private var orderedWeekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    private func startOfMonth(_ day: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
    }

    private func setMonth(_ value: Int) {
        var parts = calendar.dateComponents([.year, .month], from: month)
        parts.month = value
        month = calendar.date(from: parts).map { min($0, startOfMonth(latest)) } ?? month
    }

    private func setYear(_ value: Int) {
        var parts = calendar.dateComponents([.year, .month], from: month)
        parts.year = value
        month = calendar.date(from: parts).map { min($0, startOfMonth(latest)) } ?? month
    }

    /// A round button that lights up under the pointer.
    private struct CircleHoverStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { HoverCircle(configuration: configuration) }

        private struct HoverCircle: View {
            let configuration: Configuration
            @State private var hovered = false
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .foregroundStyle(isEnabled ? Color.primary : Color.white.opacity(0.25))
                    .background(Color.white.opacity(configuration.isPressed ? 0.16 : hovered && isEnabled ? 0.08 : 0), in: .circle)
                    .onHover { hovered = $0 }
            }
        }
    }

    /// A day: a soft circle under the pointer, unless it is the chosen one.
    private struct DayHoverStyle: ButtonStyle {
        let isChosen: Bool

        func makeBody(configuration: Configuration) -> some View { HoverDay(isChosen: isChosen, configuration: configuration) }

        private struct HoverDay: View {
            let isChosen: Bool
            let configuration: Configuration
            @State private var hovered = false
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .background {
                        if !isChosen && isEnabled && (hovered || configuration.isPressed) {
                            Circle().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)).frame(width: 36, height: 36)
                        }
                    }
                    .opacity(isEnabled ? 1 : 0.28)
                    .onHover { hovered = $0 }
            }
        }
    }
}

/// A small whole number between a minus and a plus, in one capsule. VoiceOver adjusts it like a
/// stepper.
struct NumberStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        HStack(spacing: 0) {
            step("minus", by: -1).disabled(value <= range.lowerBound)
            Text(value.formatted())
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 30)
                .contentTransition(.numericText())
            step("plus", by: 1).disabled(value >= range.upperBound)
        }
        .padding(2)
        .background(Theme.fieldFill, in: .capsule)
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
        .animation(.snappy(duration: 0.2), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.formatted())
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + 1, range.upperBound)
            case .decrement: value = max(value - 1, range.lowerBound)
            @unknown default: break
            }
        }
    }

    private func step(_ symbol: String, by delta: Int) -> some View {
        Button { value = min(max(value + delta, range.lowerBound), range.upperBound) } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 26)
                .contentShape(.capsule)
        }
        .buttonStyle(StepButtonStyle())
    }

    /// The minus and plus: plain until pressed, then a light capsule.
    private struct StepButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            StepButton(configuration: configuration)
        }

        private struct StepButton: View {
            let configuration: Configuration
            @Environment(\.isEnabled) private var isEnabled

            var body: some View {
                configuration.label
                    .foregroundStyle(isEnabled ? Color.primary : Color.white.opacity(0.25))
                    .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0), in: .capsule)
            }
        }
    }
}
#endif
