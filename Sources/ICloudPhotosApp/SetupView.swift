#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

/// The easy setup's steps, in order: three questions, then a review.
enum SetupStep: Int, CaseIterable, Identifiable {
    case goal, photos, folder, review

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .goal: return "Goal"
        case .photos: return "Which photos"
        case .folder: return "Where to save"
        case .review: return "Review and start"
        }
    }
}

/// The easy setup: three questions, then the download starts. Nothing is saved until Start or Preview.
struct SetupFlow: View {
    @EnvironmentObject var model: AppModel
    @State private var step: SetupStep = .goal
    /// The furthest step reached: the steps up to it can be revisited from the sidebar.
    @State private var furthest: SetupStep = .goal
    @State private var answers = SetupAnswers(config: SyncConfiguration(directoryPath: ""), schedule: .off, isFirstTime: true)
    @State private var loaded = false
    @State private var understood = false
    @State private var showsOptions = false

    var body: some View {
        HStack(spacing: WindowButtons.margin) {
            sidebar
            stage.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            guard !loaded else { return }
            answers = SetupAnswers(config: model.config, schedule: model.schedule, isFirstTime: !model.hasOnboarded)
            loaded = true
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get started")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                Text("Three questions, then you start")
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 2) {
                ForEach(SetupStep.allCases) { item in stepRow(item) }
            }

            Spacer(minLength: 0)

            Button("Cancel") { model.page = .library }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, 10)
        }
        .sidebarColumn(width: 264)
    }

    private func stepRow(_ item: SetupStep) -> some View {
        let isCurrent = item == step
        let isDone = item.rawValue < furthest.rawValue && !isCurrent
        return Button { step = item } label: {
            HStack(spacing: 12) {
                ZStack {
                    if isCurrent {
                        Circle().fill(Theme.accent)
                        Text("\(item.rawValue + 1)").font(.system(size: 11, weight: .bold))
                    } else if isDone {
                        Circle().fill(Color(red: 0.2, green: 0.78, blue: 0.44).opacity(0.2))
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(red: 0.5, green: 0.89, blue: 0.66))
                    } else {
                        Circle().strokeBorder(Color.white.opacity(0.18))
                        Text("\(item.rawValue + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                        .foregroundStyle(isCurrent || isDone ? Color.primary : Color(white: 0.8))
                    Text(answer(item))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isCurrent ? Theme.accent.opacity(0.18) : Color.clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(item.rawValue > furthest.rawValue)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func answer(_ item: SetupStep) -> String {
        if item.rawValue > furthest.rawValue { return item == .review ? "Nothing runs until you start" : "Not answered yet" }
        switch item {
        case .goal: return answers.goal == .freeUp ? "Free up iCloud space" : "Back up only"
        case .photos:
            if case .between = answers.photos { return answers.photosSummary }
            return SetupAnswers.title(answers.photos)
        case .folder: return answers.directoryPath.isEmpty ? "Not chosen yet" : folderName
        case .review: return "Nothing runs until you start"
        }
    }

    private var folderName: String { (answers.directoryPath as NSString).lastPathComponent }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Capsule().fill(Color.white.opacity(0.07))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent).frame(width: geo.size.width * CGFloat(step.rawValue + 1) / 4)
                    }
            }
            .frame(height: 4)
            .frame(maxWidth: 680)
            .padding(.top, 18)
            .animation(.smooth(duration: 0.3), value: step)
            .accessibilityHidden(true)

            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heading
                        content
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
                .scrollIndicators(.never)
            }
            .id(step)
            .transition(.opacity)

            footer
        }
        .padding(.horizontal, 24)
        .animation(.smooth(duration: 0.2), value: step)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step == .review ? "Review" : "Question \(step.rawValue + 1) of 3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accentSoft)
            Text(title)
                .font(.system(size: 34, weight: .bold))
                .tracking(-1)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation)
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch step {
        case .goal: return "What would you like to do?"
        case .photos: return answers.goal == .freeUp ? "Which photos should move off iCloud?" : "Which photos should be downloaded?"
        case .folder: return "Where should they go?"
        case .review: return answers.goal == .freeUp ? "Ready to free up iCloud" : "Ready to back up"
        }
    }

    private var explanation: String {
        switch step {
        case .goal: return "You can change this later in Settings."
        case .photos:
            return answers.goal == .freeUp
                ? "Pick by the date they were taken. Anything newer stays in iCloud, so your iPhone keeps your recent photos."
                : "Pick by the date they were taken."
        case .folder: return "This folder becomes the home of these photos. An external drive works too. Photos already in it are skipped."
        case .review: return "\(answers.photosSummary). Nothing has been downloaded or removed yet."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .goal: goalChoices
        case .photos: photosChoices
        case .folder: folderChoice
        case .review: review
        }
    }

    // MARK: 1 · Goal

    private var goalChoices: some View {
        HStack(alignment: .top, spacing: 12) { goalCards }
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var goalCards: some View {
        GoalCard(symbol: "icloud.slash", title: "Free up iCloud space", isRecommended: true,
                 text: "Download the photos you pick, then remove them from iCloud. This Mac keeps the full-quality copy.",
                 points: ["Room in iCloud again, maybe a smaller plan", "Removed only after each file is safely saved"],
                 isOn: answers.goal == .freeUp) { choose(.freeUp) }
        GoalCard(symbol: "macbook.and.iphone", title: "Back up only", isRecommended: false,
                 text: "Download a copy to this Mac and leave iCloud exactly as it is.",
                 points: ["Nothing is ever removed from iCloud", "Doesn't free any iCloud storage"],
                 isOn: answers.goal == .backUp) { choose(.backUp) }
    }

    private func choose(_ goal: SetupAnswers.Goal) {
        answers.goal = goal
        // "Older than" only means something when photos leave iCloud.
        if goal == .backUp, case .olderThan = answers.photos { answers.photos = .everything }
    }

    // MARK: 2 · Which photos

    private var photosChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(answers.presets, id: \.self) { preset in
                    PresetCard(title: SetupAnswers.title(preset), detail: answers.detail(preset), isOn: answers.photos == preset) {
                        answers.photos = preset
                    }
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                if answers.photos == .between {
                    HStack(spacing: 12) {
                        dateField("From", $answers.from)
                        dateField("To", $answers.to)
                    }
                }
                RangeBar(answers: answers)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
        }
    }

    private func dateField(_ title: String, _ date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
            DatePicker(title, selection: date, in: ...Date(), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 3 · Where to save

    private var folderChoice: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accentSoft)
                        .frame(width: 52, height: 52)
                        .background(Theme.accent.opacity(0.18), in: .rect(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(answers.directoryPath.isEmpty ? "No folder chosen yet" : folderName)
                            .font(.system(size: 16, weight: .semibold))
                        Text(answers.directoryPath.isEmpty ? "Pick one on this Mac or an external drive"
                             : (answers.directoryPath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(Theme.secondary)
                            .truncationMode(.middle)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(answers.directoryPath.isEmpty ? "Choose Folder…" : "Change…") {
                        if let url = model.pickFolder(message: "Choose where to save your iCloud photos") {
                            answers.directoryPath = url.path
                        }
                    }
                    .buttonStyle(PillButtonStyle(kind: answers.directoryPath.isEmpty ? .primary : .secondary, height: 34))
                    .fixedSize()
                }
                if let space = DiskSpace.of(answers.directoryPath) {
                    DiskBar(space: space)
                }
            }
            .padding(22)
            .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))

            VStack(alignment: .leading, spacing: 0) {
                Button { showsOptions.toggle() } label: {
                    HStack {
                        Text("Quality and folders").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(showsOptions ? 0 : -90))
                    }
                    .foregroundStyle(Color(white: 0.8))
                    .padding(.horizontal, 18)
                    .frame(height: 46)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                if showsOptions {
                    VStack(spacing: 0) {
                        CardDivider()
                        OptionRow(title: "Quality", detail: "Originals are the full files, exactly as taken") {
                            Picker("Quality", selection: $answers.size) {
                                ForEach([PhotoSize.original, .adjusted, .medium], id: \.self) { Text($0.qualityLabel).tag($0) }
                            }
                        }
                        CardDivider()
                        OptionRow(title: "Folders", detail: FolderExample.path(for: answers.folderStructure), monospaced: true) {
                            Picker("Folders", selection: $answers.folderStructure) {
                                ForEach(FolderStructure.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                                if FolderStructure(rawValue: answers.folderStructure) == nil {
                                    Text("Custom").tag(answers.folderStructure)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 6)
                }
            }
            .panel(cornerRadius: 16, fill: Color.white.opacity(0.02), stroke: Color.white.opacity(0.07))
            .animation(.smooth(duration: 0.2), value: showsOptions)
        }
    }

    // MARK: 4 · Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                SummaryRow(symbol: "calendar", tint: Color(white: 0.9), title: "Photos", value: answers.photosSummary) { step = .photos }
                SummaryRow(symbol: "folder.fill", tint: Theme.accentSoft, title: "Saved to",
                           value: (answers.directoryPath as NSString).abbreviatingWithTildeInPath, detail: savedToDetail) { step = .folder }
                SummaryRow(symbol: answers.goal == .freeUp ? "icloud.slash" : "icloud",
                           tint: answers.goal == .freeUp ? Theme.warning : Color(white: 0.9),
                           title: "Then", value: thenText) { step = .goal }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep it going").font(.system(size: 14))
                    Text(keepGoingText).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                Toggle("Keep it going", isOn: $answers.keepGoing).labelsHidden().toggleStyle(.switch)
            }
            .padding(.horizontal, 4)

            if answers.goal == .freeUp {
                Toggle(isOn: $understood) {
                    Text("I understand these photos will leave iCloud and all my devices. They wait in Recently Deleted for 30 days, then the copy on this Mac is the only one.")
                        .foregroundStyle(Color(red: 0.95, green: 0.85, blue: 0.74))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(cornerRadius: 14, fill: Theme.warning.opacity(0.07), stroke: Theme.warning.opacity(0.3))
            }

            if model.phase != .signedIn {
                Label("Connecting to iCloud…", systemImage: "icloud")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private var savedToDetail: String {
        let folders = FolderStructure(rawValue: answers.folderStructure)?.label ?? "Custom folders"
        return "\(answers.size.qualityLabel), in folders by \(folders.lowercased())"
    }

    private var thenText: String {
        guard answers.goal == .freeUp else { return "iCloud stays as it is" }
        if case .olderThan = answers.photos {
            return "Removed from iCloud once saved here. Newer photos are saved too, and stay in iCloud."
        }
        return "Removed from iCloud once each file is saved here"
    }

    private var keepGoingText: String {
        let time = DateComponents(calendar: .current, hour: model.scheduleHour, minute: 0).date?
            .formatted(date: .omitted, time: .shortened) ?? "\(model.scheduleHour):00"
        if answers.goal == .freeUp, case .olderThan(let days) = answers.photos {
            return "Each night at \(time), save new photos and move ones that turn \(RemovalAge.label(days).lowercased()) old"
        }
        return "Each night at \(time), save new photos"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button { if let previous = SetupStep(rawValue: step.rawValue - 1) { step = previous } } label: {
                Text("Back").frame(minWidth: 40)
            }
            .buttonStyle(HeroButtonStyle(isPrimary: false))
            .disabled(step == .goal)

            Spacer(minLength: 0)

            if step == .review {
                Button { start(preview: true) } label: { Text("Preview First") }
                    .buttonStyle(HeroButtonStyle(isPrimary: false))
                    .help("See what would be downloaded and removed, without changing anything")
                    .disabled(!canStart)
                Button { start(preview: false) } label: {
                    Label("Start", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(HeroButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart || (answers.goal == .freeUp && !understood))
            } else {
                Button(action: next) {
                    HStack(spacing: 8) {
                        Text("Continue")
                        Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(HeroButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(step == .folder && answers.directoryPath.isEmpty)
            }
        }
        .frame(maxWidth: 680)
        .padding(.bottom, 26)
    }

    private var canStart: Bool { model.phase == .signedIn && !answers.directoryPath.isEmpty && !model.isDownloading }

    private func next() {
        guard let following = SetupStep(rawValue: step.rawValue + 1) else { return }
        step = following
        if following.rawValue > furthest.rawValue { furthest = following }
    }

    private func start(preview: Bool) {
        answers.apply(to: &model.config)
        model.schedule = answers.keepGoing ? .daily : .off
        model.hasOnboarded = true
        if preview {
            model.startDownload(dryRun: true)
        } else {
            // The box above is the confirmation the app would otherwise ask for.
            model.startDownload(confirmed: true)
        }
    }
}

// MARK: Pieces

/// One of the two big answers to "What would you like to do?".
struct GoalCard: View {
    let symbol: String
    let title: String
    let isRecommended: Bool
    let text: String
    let points: [String]
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Theme.accentSoft : Color(white: 0.9))
                    .frame(width: 48, height: 48)
                    .background(isOn ? Theme.accent.opacity(0.22) : Color.white.opacity(0.07), in: .rect(cornerRadius: 14, style: .continuous))
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    if isRecommended {
                        Text("Recommended")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.5, green: 0.89, blue: 0.66))
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Color(red: 0.2, green: 0.78, blue: 0.44).opacity(0.16), in: .capsule)
                    }
                }
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.75))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(isRecommended ? Color(red: 0.5, green: 0.89, blue: 0.66) : Theme.secondary)
                            Text(point)
                        }
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(Color(white: 0.8))
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(isOn ? Theme.accent.opacity(0.1) : Color.white.opacity(0.03), in: .rect(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isOn ? Theme.accent : Color.white.opacity(0.1), lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Theme.accent, in: .circle)
                        .padding(18)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A small card for one answer to "Which photos?".
struct PresetCard: View {
    let title: String
    let detail: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Color(red: 0.66, green: 0.8, blue: 1) : Theme.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isOn ? Theme.accent.opacity(0.1) : Color.white.opacity(0.03), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isOn ? Theme.accent : Color.white.opacity(0.1), lineWidth: 1.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A bar across time: which photos come to this Mac, which leave iCloud and which stay.
struct RangeBar: View {
    let answers: SetupAnswers

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                switch answers.photos {
                case .olderThan:
                    segment("Move to this Mac, then off iCloud", isOn: true).layoutPriority(1)
                    segment("Stays in iCloud", isOn: false).frame(width: 120)
                case .everything:
                    segment(answers.goal == .freeUp ? "Move to this Mac, then off iCloud" : "Download a copy to this Mac", isOn: true)
                case .between:
                    segment("Left alone", isOn: false).frame(width: 90)
                    segment(answers.goal == .freeUp ? "Move to this Mac, then off iCloud" : "Download", isOn: true).layoutPriority(1)
                    segment("Left alone", isOn: false).frame(width: 90)
                }
            }
            .frame(height: 34)
            .clipShape(.rect(cornerRadius: 10, style: .continuous))

            HStack {
                Text(leadingLabel)
                Spacer()
                Text(trailingLabel)
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(answers.photosSummary)
    }

    private func segment(_ text: String, isOn: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            .foregroundStyle(isOn ? Color.white : Color(white: 0.8))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isOn ? .leading : .center)
            .background(isOn ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.04, green: 0.34, blue: 0.84), Color(red: 0.17, green: 0.48, blue: 1)],
                                                            startPoint: .leading, endPoint: .trailing))
                             : AnyShapeStyle(Color.white.opacity(0.1)))
    }

    private var leadingLabel: String {
        if case .between = answers.photos { return min(answers.from, answers.to).formatted(date: .abbreviated, time: .omitted) }
        return "Your first photo"
    }

    private var trailingLabel: String {
        switch answers.photos {
        case .olderThan(let days): return "\(RemovalAge.cutoff(days).formatted(date: .abbreviated, time: .omitted)) · Today"
        case .everything: return "Today"
        case .between: return max(answers.from, answers.to).formatted(date: .abbreviated, time: .omitted)
        }
    }
}

/// A row of the review: what was answered, and a way back to change it.
struct SummaryRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    var detail: String?
    let change: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                if let detail {
                    // A path: one line, cut in the middle where it says least.
                    Text(value)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    Text(value)
                        .font(.system(size: 14, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            CardLink(title: "Change", action: change)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// A label with a line under it, and a menu on the right.
struct OptionRow<Choice: View>: View {
    let title: String
    var detail: String?
    var monospaced = false
    @ViewBuilder var choice: Choice

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            choice
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.white)
                .fixedSize()
        }
        .frame(minHeight: 52)
    }
}

/// The disk a folder is on: its name, size and free space.
struct DiskSpace {
    var name: String
    var capacity: Int64
    var available: Int64

    /// Looks at the folder, or the nearest folder above it that exists.
    static func of(_ path: String) -> DiskSpace? {
        guard !path.isEmpty else { return nil }
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        guard let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                                             .volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return DiskSpace(name: values.volumeLocalizedName ?? "Disk", capacity: Int64(capacity), available: available)
    }
}

/// How full the folder's disk is.
struct DiskBar: View {
    let space: DiskSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                Capsule().fill(Color.white.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.3))
                            .frame(width: geo.size.width * CGFloat(Double(space.capacity - space.available) / Double(max(space.capacity, 1))))
                    }
            }
            .frame(height: 8)
            HStack {
                Text("\(space.name) · \(AppSidebar.size(space.capacity))")
                Spacer()
                Text("\(AppSidebar.size(space.available)) free")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Where a photo taken today would land with a folder layout.
enum FolderExample {
    static func path(for format: String) -> String {
        let folder = (try? FolderFormat(format))?.path(for: Date()) ?? ""
        return (folder.isEmpty ? "" : folder + "/") + "IMG_0001.HEIC"
    }
}
#endif
