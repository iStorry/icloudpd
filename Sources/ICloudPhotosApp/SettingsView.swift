#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

/// The sections of the settings page, most important first.
enum SettingsPane: String, CaseIterable, Identifiable {
    case freeUp, photos, general, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeUp: return "Free up iCloud"
        case .photos: return "Photos and files"
        case .general: return "General"
        case .advanced: return "Advanced"
        }
    }

    var summary: String {
        switch self {
        case .freeUp: return "What leaves iCloud once it's safely on this Mac."
        case .photos: return "What comes down from iCloud, in what quality, and where it lands."
        case .general: return "When it runs, and how it keeps you posted."
        case .advanced: return "Every other option, for when the defaults aren't enough."
        }
    }

    var symbol: String {
        switch self {
        case .freeUp: return "icloud.slash"
        case .photos: return "photo.on.rectangle"
        case .general: return "clock"
        case .advanced: return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .freeUp: return Theme.accent
        case .photos: return Color(red: 0.88, green: 0.54, blue: 0.17)
        case .general: return Color(white: 0.43)
        case .advanced: return Color(white: 0.3)
        }
    }

    /// Words the search field matches, besides the title.
    var keywords: String {
        switch self {
        case .freeUp: return "delete remove keep recent days older safety preview recently deleted storage space mac auto-delete prune"
        case .photos: return "library albums dates taken from to include photos videos live screenshots quality size original folder layout"
        case .general: return "account sign out schedule automatic night time login menu bar notifications"
        case .advanced: return "parallel activity log dry run sizes raw naming unicode metadata exif xmp skip recent until found pattern delete list data protection indexing suffix command line"
        }
    }
}

/// The settings page's sidebar: the way back, search, the sections and the easy setup.
struct SettingsSidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: SettingsPane
    @State private var query = ""

    private var matches: [SettingsPane] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { item in
            let text = (item.title + " " + item.keywords).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button { model.page = .library } label: { CircleIcon(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Back to Home")
                    .accessibilityLabel("Back to Home")
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
            }
            .padding(.leading, 2)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.secondary)
                TextField("Search settings", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { if let first = matches.first { pane = first } }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .panel(cornerRadius: 9, fill: Theme.fieldFill, stroke: Color.white.opacity(0.08))

            VStack(spacing: 2) {
                ForEach(matches) { item in
                    let isOn = pane == item
                    Button { pane = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(item.tint, in: .rect(cornerRadius: 7, style: .continuous))
                            Text(item.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: isOn ? .medium : .regular))
                        .foregroundStyle(isOn ? Color.primary : Color(white: 0.8))
                        .padding(.horizontal, 8)
                        .frame(height: 36)
                        .background(isOn ? Theme.accent.opacity(0.2) : Color.clear, in: .rect(cornerRadius: 10, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                if matches.isEmpty {
                    Text("No settings match \"\(query)\".")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 8)
                }
            }

            Spacer(minLength: 0)

            Button { model.page = .setup } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run setup again").font(.system(size: 13, weight: .medium))
                        Text("The three easy questions").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .padding(10)
                .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.isDownloading)
        }
        .sidebarColumn(width: 264)
    }
}

/// The chosen section, beside the sidebar.
struct SettingsStage: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: SettingsPane
    @State private var showingAlbums = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(pane.title)
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.9)
                    Text(pane.summary)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondary)
                }

                if model.isDownloading {
                    Label("Settings can be changed again when the run is over.", systemImage: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .panel(cornerRadius: 17)
                }

                Group {
                    switch pane {
                    case .freeUp: FreeUpSettings(pane: $pane)
                    case .photos: PhotoSettings(showingAlbums: $showingAlbums)
                    case .general: GeneralSettings()
                    case .advanced: AdvancedSettings()
                    }
                }
                .disabled(model.isDownloading)
                .opacity(model.isDownloading ? 0.45 : 1)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 30)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showingAlbums) {
            AlbumPicker().environmentObject(model)
        }
    }
}

// MARK: Building blocks

/// A titled card of settings with an optional explanation under it.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { SectionHeader(title: title) }
            Card { content }
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A setting's name, with an optional line under it, on the left and its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
    }
}

struct SettingSwitch: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct SettingPicker<Value: Hashable, Options: View>: View {
    let title: String
    var detail: String?
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.white)
                .fixedSize()
        }
    }
}

struct SettingStepper: View {
    let title: String
    var detail: String?
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Text(value.formatted())
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
            Stepper(title, value: $value, in: range)
                .labelsHidden()
        }
    }
}

/// One of two or more answers in a card, with a radio mark.
struct ChoiceRow: View {
    let title: String
    let detail: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingRow(title: title, detail: detail) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Theme.accentSoft : Color.white.opacity(0.3))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The rounded well a text field sits in on the settings page.
struct FieldWell<Content: View>: View {
    var width: CGFloat? = 170
    var alignment: TextAlignment = .trailing
    @ViewBuilder var content: Content

    var body: some View {
        content
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(Theme.fieldFill, in: .rect(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.fieldStroke))
    }
}

/// An optional whole number edited as text: empty means "not set".
struct OptionalNumberRow: View {
    let title: String
    let prompt: String
    @Binding var value: Int?

    var body: some View {
        SettingRow(title: title) {
            FieldWell(width: 110) {
                TextField(title, text: Binding(
                    get: { value.map(String.init) ?? "" },
                    set: { text in
                        let digits = text.filter(\.isNumber)
                        value = digits.isEmpty ? nil : Int(digits)
                    }), prompt: Text(prompt))
            }
        }
    }
}

// MARK: Free up iCloud

struct FreeUpSettings: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: SettingsPane

    private var removing: Bool { model.config.deletesFromICloud }
    private var age: Int { model.config.keepICloudRecentDays ?? 0 }

    var body: some View {
        PlanSummary()

        SettingsSection(title: "After a photo is saved here") {
            ChoiceRow(title: "Keep it in iCloud", detail: "A backup. iCloud stays as it is.", isOn: !removing) {
                model.config.keepICloudRecentDays = nil
                model.config.deleteAfterDownload = false
            }
            ChoiceRow(title: "Remove it from iCloud", detail: "Frees space. This Mac keeps the full-quality copy.", isOn: removing) {
                if model.config.keepICloudRecentDays == nil { model.config.keepICloudRecentDays = 365 }
                model.config.deleteAfterDownload = false
                // Both are refused next to deleting from iCloud.
                model.config.ignoreIndexingState = false
                model.config.xmpSidecarOnly = false
            }
        }

        if removing {
            SettingsSection(title: "Which photos leave iCloud") {
                SettingPicker(title: "Older than", detail: "Your recent photos stay in iCloud. This moves forward each day.", selection: ageBinding) {
                    ForEach(ageChoices, id: \.self) { Text(RemovalAge.label($0)).tag($0) }
                }
                SettingRow(title: "Taken", detail: PhotoSettings.rangeText(model.config) + ". Only these are downloaded, so only these can leave iCloud.") {
                    Button("Change") { pane = .photos }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                }
            }
        }

        SettingsSection(title: "Safety",
                        footer: "Removed photos wait in Recently Deleted for 30 days. You can bring them back in Photos or on iCloud.com until then.") {
            SettingRow(title: "Only after the file is on this Mac", detail: "Always on. A photo that didn't download stays in iCloud.") {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.secondary)
                    .accessibilityLabel("Always on")
            }
            SettingSwitch(title: "Ask before a run I start", detail: "Scheduled runs go ahead without asking", isOn: $model.askBeforeRemoving)
            SettingRow(title: "Preview", detail: "See what would be downloaded and leave iCloud, without changing anything") {
                Button("Run Preview") { model.startDownload(dryRun: true) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                    .disabled(model.phase != .signedIn || model.directory == nil)
            }
        }

        SettingsSection(title: "This Mac",
                        footer: "Set-aside files go into a .icloudpd-swift-pruned folder inside your download folder; nothing is deleted.") {
            SettingSwitch(title: "Delete here when deleted in iCloud", detail: "When a photo is in Recently Deleted, its file on this Mac goes too",
                          isOn: $model.config.autoDelete)
            SettingSwitch(title: "Set aside files whose photo is gone from iCloud", detail: "Only files this app downloaded",
                          isOn: $model.config.pruneOrphans)
        }
    }

    private var ageBinding: Binding<Int> {
        Binding(get: { age }, set: {
            model.config.keepICloudRecentDays = $0
            model.config.deleteAfterDownload = false
        })
    }

    /// The usual ages, plus one set some other way.
    private var ageChoices: [Int] {
        RemovalAge.choices.contains(age) ? RemovalAge.choices : (RemovalAge.choices + [age]).sorted()
    }
}

/// The top of Free up iCloud: what happens, in a sentence and a bar.
struct PlanSummary: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let removing = model.config.deletesFromICloud
        let age = model.config.keepICloudRecentDays ?? 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(headline(removing: removing, age: age))
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let next = model.nextRun {
                    Text("Next run \(HomeStage.dayAndTime(next))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.66, green: 0.8, blue: 1))
                }
            }
            HStack(spacing: 2) {
                if removing {
                    bar("On this Mac only", isOn: true).layoutPriority(1)
                    if age > 0 { bar("Also in iCloud", isOn: false).frame(width: 120) }
                } else {
                    bar("In iCloud and on this Mac", isOn: false)
                }
            }
            .frame(height: 26)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            HStack {
                Text(PhotoSettings.rangeText(model.config))
                Spacer()
                if removing, age > 0 {
                    Text("Taken after \(RemovalAge.cutoff(age).formatted(date: .abbreviated, time: .omitted)): stays in iCloud")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
        }
        .padding(20)
        .background(LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.04)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.accentSoft.opacity(0.22)))
    }

    private func headline(removing: Bool, age: Int) -> String {
        guard removing else { return "iCloud stays as it is" }
        return age > 0 ? "Photos older than \(RemovalAge.label(age).lowercased()) leave iCloud" : "Photos leave iCloud once they're on this Mac"
    }

    private func bar(_ text: String, isOn: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : Color(white: 0.82))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isOn ? .leading : .center)
            .background(isOn ? Color(red: 0.17, green: 0.48, blue: 1) : Color.white.opacity(0.14))
    }
}

// MARK: Photos and files

struct PhotoSettings: View {
    @EnvironmentObject var model: AppModel
    @Binding var showingAlbums: Bool

    /// Which dates are downloaded: the two optional bounds, as one choice.
    enum DateRange: Hashable { case anyTime, before, after, between }

    var body: some View {
        SettingsSection(title: "From iCloud") {
            if model.libraries.count > 1 {
                SettingPicker(title: "Library", selection: libraryBinding) {
                    ForEach(model.libraries, id: \.self) { Text(model.libraryLabel($0)).tag($0) }
                }
            }
            SettingRow(title: "Albums", detail: albumSummary) {
                Button("Choose…") { showingAlbums = true }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                    .disabled(model.phase != .signedIn)
            }
            SettingPicker(title: "Taken", detail: "By the date each photo was taken", selection: rangeBinding) {
                Text("Any time").tag(DateRange.anyTime)
                Text("Before a date").tag(DateRange.before)
                Text("After a date").tag(DateRange.after)
                Text("Between two dates").tag(DateRange.between)
            }
            if model.config.skipCreatedBefore != nil {
                SettingRow(title: "From") { datePicker(fromBinding) }
            }
            if model.config.skipCreatedAfter != nil {
                SettingRow(title: model.config.skipCreatedBefore == nil ? "Before" : "To") { datePicker(toBinding) }
            }
            SettingRow(title: "Include") {
                HStack(spacing: 6) {
                    IncludeChip(title: "Photos", isOn: inverted(\.skipPhotos))
                    IncludeChip(title: "Videos", isOn: inverted(\.skipVideos))
                    IncludeChip(title: "Live Photo videos", isOn: inverted(\.skipLivePhotos))
                    IncludeChip(title: "Screenshots", isOn: inverted(\.skipScreenshots))
                }
            }
        }

        SettingsSection(title: "Quality") {
            SettingPicker(title: "Photos", detail: "Originals are exactly as taken. Pick these when clearing iCloud.", selection: photoQuality) {
                ForEach([PhotoSize.original, .adjusted, .medium, .thumb], id: \.self) { Text($0.qualityLabel).tag(Optional($0)) }
                if model.config.sizes.count > 1 || model.config.sizes == [.alternative] {
                    Text("Several (set in Advanced)").tag(PhotoSize?.none)
                }
            }
            SettingPicker(title: "Videos", selection: videoQuality) {
                Text("Same as photos").tag("same")
                Text("Originals").tag("original")
                Text("Medium").tag("medium")
                Text("Thumbnail").tag("thumb")
                Divider()
                Text("Don't download").tag("none")
            }
            SettingPicker(title: "Live Photo videos", selection: liveQuality) {
                Text("Originals").tag("original")
                Text("Medium").tag("medium")
                Text("Thumbnail").tag("thumb")
                Divider()
                Text("Don't download").tag("none")
            }
        }

        SettingsSection(title: "On this Mac") {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.accentSoft)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent.opacity(0.18), in: .rect(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.directory?.lastPathComponent ?? "No folder chosen").font(.system(size: 14))
                    Text(folderDetail).font(.system(size: 12)).foregroundStyle(Theme.secondary).truncationMode(.middle)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if model.directory != nil {
                    Button("Show") { model.openDirectory() }
                }
                Button("Change…") { model.chooseDirectory() }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            SettingPicker(title: "Folders", detail: FolderExample.path(for: model.config.folderStructure), selection: layoutBinding) {
                ForEach(FolderStructure.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                Text("Custom").tag("custom")
            }
            if FolderStructure(rawValue: model.config.folderStructure) == nil {
                SettingRow(title: "Format", detail: "Fields like {:%Y}, {:%m}, {:%d}, {:%B}") {
                    FieldWell(width: 200) {
                        TextField("Format", text: $model.config.folderStructure, prompt: Text("{:%Y}/{:%m}"))
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
    }

    private func datePicker(_ date: Binding<Date>) -> some View {
        DatePicker("", selection: date, in: ...Date(), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .fixedSize()
    }

    /// "Any time", "Taken before 26 Nov 2025", "Taken 3 Jan 2015 to 26 Nov 2025".
    static func rangeText(_ config: SyncConfiguration) -> String {
        let from = config.skipCreatedBefore?.resolve().formatted(date: .abbreviated, time: .omitted)
        let to = config.skipCreatedAfter?.resolve().formatted(date: .abbreviated, time: .omitted)
        switch (from, to) {
        case let (from?, to?): return "Taken \(from) to \(to)"
        case let (from?, nil): return "Taken after \(from)"
        case let (nil, to?): return "Taken before \(to)"
        case (nil, nil): return "Taken any time"
        }
    }

    private var rangeBinding: Binding<DateRange> {
        Binding(get: {
            switch (model.config.skipCreatedBefore != nil, model.config.skipCreatedAfter != nil) {
            case (true, true): return .between
            case (true, false): return .after
            case (false, true): return .before
            case (false, false): return .anyTime
            }
        }, set: { range in
            let calendar = Calendar.current
            let yearAgo = calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            let tenYearsAgo = calendar.date(byAdding: .year, value: -10, to: Date()) ?? Date()
            let from = model.config.skipCreatedBefore ?? .date(calendar.startOfDay(for: range == .between ? tenYearsAgo : yearAgo))
            let to = model.config.skipCreatedAfter ?? .date(endOfDay(range == .between ? Date() : yearAgo))
            switch range {
            case .anyTime: model.config.skipCreatedBefore = nil; model.config.skipCreatedAfter = nil
            case .before: model.config.skipCreatedBefore = nil; model.config.skipCreatedAfter = to
            case .after: model.config.skipCreatedBefore = from; model.config.skipCreatedAfter = nil
            case .between: model.config.skipCreatedBefore = from; model.config.skipCreatedAfter = to
            }
        })
    }

    private var fromBinding: Binding<Date> {
        Binding(get: { model.config.skipCreatedBefore?.resolve() ?? Date() },
                set: { model.config.skipCreatedBefore = .date(Calendar.current.startOfDay(for: $0)) })
    }

    private var toBinding: Binding<Date> {
        Binding(get: { model.config.skipCreatedAfter?.resolve() ?? Date() },
                set: { model.config.skipCreatedAfter = .date(endOfDay($0)) })
    }

    private func endOfDay(_ date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: date)) ?? date
    }

    private var photoQuality: Binding<PhotoSize?> {
        Binding(get: {
            let sizes = model.config.sizes
            return sizes.count == 1 && sizes != [.alternative] ? sizes[0] : nil
        }, set: { if let size = $0 { model.config.sizes = [size] } })
    }

    private var videoQuality: Binding<String> {
        Binding(get: {
            if model.config.skipVideos { return "none" }
            return model.config.videoSize?.rawValue ?? "same"
        }, set: { value in
            model.config.skipVideos = value == "none"
            switch value {
            case "none": break
            case "same": model.config.videoSize = nil
            default: model.config.videoSize = PhotoSize(rawValue: value)
            }
        })
    }

    private var liveQuality: Binding<String> {
        Binding(get: { model.config.skipLivePhotos ? "none" : model.config.livePhotoSize.rawValue },
                set: { value in
                    model.config.skipLivePhotos = value == "none"
                    if let size = LivePhotoSize(rawValue: value) { model.config.livePhotoSize = size }
                })
    }

    private var layoutBinding: Binding<String> {
        Binding(get: { FolderStructure(rawValue: model.config.folderStructure) != nil ? model.config.folderStructure : "custom" },
                set: { value in
                    if value != "custom" {
                        model.config.folderStructure = value
                    } else if FolderStructure(rawValue: model.config.folderStructure) != nil {
                        model.config.folderStructure = "{:%Y}/{:%m-%B}"
                    }
                })
    }

    private var folderDetail: String {
        guard let directory = model.directory else { return "Choose where photos go" }
        var text = (directory.path as NSString).abbreviatingWithTildeInPath
        if let space = DiskSpace.of(directory.path) { text += " · \(AppSidebar.size(space.available)) free" }
        return text
    }

    private var albumSummary: String {
        switch model.config.albums.count {
        case 0: return "All Photos"
        case 1: return model.config.albums[0]
        default: return "\(model.config.albums.count) albums"
        }
    }

    private var libraryBinding: Binding<String> {
        Binding(get: { model.config.library ?? model.libraries.first ?? "PrimarySync" },
                set: { name in
                    model.config.library = name
                    model.config.albums = []
                    Task { await model.loadAlbums() }
                })
    }

    private func inverted(_ key: WritableKeyPath<SyncConfiguration, Bool>) -> Binding<Bool> {
        Binding(get: { !model.config[keyPath: key] }, set: { model.config[keyPath: key] = !$0 })
    }
}

// MARK: General

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text(Initials.of(model.accountName ?? model.appleID))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [Theme.accent, Color(red: 0.36, green: 0.61, blue: 1)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.accountName ?? model.appleID).font(.system(size: 15, weight: .semibold))
                Text("\(model.appleID) · \(model.domain == .cn ? "China mainland (icloud.com.cn)" : "Worldwide (icloud.com)")")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Sign Out") { model.signOut() }
                .buttonStyle(PillButtonStyle(kind: .secondary, height: 30))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .panel()

        SettingsSection(title: "Schedule",
                        footer: "Runs while the app is open, in the window or the menu bar. New photos are picked up and your Free up iCloud choice is applied.") {
            SettingPicker(title: "Sync automatically", selection: $model.schedule) {
                ForEach(ScheduleInterval.allCases) { Text($0.label).tag($0) }
            }
            if model.schedule == .daily {
                SettingPicker(title: "At", selection: $model.scheduleHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(DateComponents(calendar: .current, hour: hour, minute: 0).date?
                            .formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
                    }
                }
            }
            if let next = model.nextRun {
                SettingRow(title: "Next run") {
                    Text(next.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Theme.secondary)
                }
            }
            SettingSwitch(title: "Open at login", detail: "So scheduled syncs happen without opening the app", isOn: $model.launchAtLogin)
        }

        SettingsSection(title: "Notifications and menu bar",
                        footer: AppModel.canNotify ? nil
                            : "Notifications and Open at Login need the app bundle: build it with scripts/build-app.sh.") {
            SettingSwitch(title: "Show in menu bar", detail: "Progress and Sync Now without opening the window", isOn: $model.showInMenuBar)
            SettingSwitch(title: "Notify when a sync finishes", detail: "When something was saved or failed", isOn: $model.notifyWhenDone)
        }
    }
}

// MARK: Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newPattern = ""
    @State private var allowUndated = false

    var body: some View {
        SettingsSection(title: "Runs",
                        footer: "More parallel downloads finish sooner on a fast connection. \"Stop after N already downloaded\" always downloads one at a time.") {
            SettingStepper(title: "Parallel downloads", value: $model.config.concurrentDownloads, range: 1...16)
            SettingPicker(title: "Activity list shows", selection: $model.logLevel) {
                Text("Each file and any problem").tag(SyncLogLevel.info)
                Text("Everything, in detail").tag(SyncLogLevel.debug)
                Text("Problems only").tag(SyncLogLevel.error)
            }
            SettingSwitch(title: "Always do a dry run", detail: "Nothing is downloaded, moved or removed", isOn: $model.config.dryRun)
        }

        SettingsSection(title: "Sizes",
                        footer: "Medium and thumbnail files get -medium and -thumb in their names; edited and alternative files get a suffix only when the name would clash.") {
            ForEach(PhotoSize.allCases, id: \.self) { size in
                SettingSwitch(title: size.label, isOn: Binding(
                    get: { model.config.sizes.contains(size) },
                    set: { on in
                        if on { model.config.sizes.append(size) } else { model.config.sizes.removeAll { $0 == size } }
                    }))
                    // At least one size stays chosen: the last one can't be switched off.
                    .disabled(model.config.sizes == [size])
            }
            SettingSwitch(title: "Only these sizes (don't fall back to the original)", isOn: $model.config.forceSize)
        }

        SettingsSection(title: "Live Photos") {
            SettingPicker(title: "Video file name", selection: $model.config.livePhotoMovFilenamePolicy) {
                Text("IMG_0001_HEVC.MOV").tag(LivePhotoMovFilenamePolicy.suffix)
                Text("IMG_0001.MOV").tag(LivePhotoMovFilenamePolicy.original)
            }
            SettingRow(title: "Video folder",
                       detail: model.config.livePhotoDirectoryPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Next to the photo") {
                if model.config.livePhotoDirectoryPath != nil {
                    Button("Reset") { model.config.livePhotoDirectoryPath = nil }
                }
                Button("Choose…") { model.chooseLivePhotoDirectory() }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
        }

        SettingsSection(title: "Naming",
                        footer: "To continue a folder made by icloudpd, match its settings: icloudpd removes non-ASCII characters unless --keep-unicode-in-filenames was used.") {
            SettingPicker(title: "RAW + JPEG", selection: $model.config.alignRaw) {
                Text("As stored in iCloud").tag(RawPolicy.asIs)
                Text("RAW is the original").tag(RawPolicy.original)
                Text("RAW is the alternative").tag(RawPolicy.alternative)
            }
            SettingPicker(title: "Same name, different photo", selection: $model.config.fileMatchPolicy) {
                Text("Add the file size").tag(FileMatchPolicy.nameSizeDedupWithSuffix)
                Text("Add the iCloud ID to every name").tag(FileMatchPolicy.nameID7)
            }
            SettingSwitch(title: "Keep accents and other non-ASCII characters", isOn: $model.config.keepUnicodeInFilenames)
        }

        SettingsSection(title: "Metadata") {
            SettingSwitch(title: "Write the photo date into JPEGs that have none", isOn: $model.config.setExifDatetime)
            SettingSwitch(title: "Write XMP sidecar files", isOn: $model.config.xmpSidecar)
            SettingSwitch(title: "Only write XMP sidecars", detail: "Downloads nothing, so it can't be combined with removing from iCloud",
                          isOn: $model.config.xmpSidecarOnly)
                .disabled(model.config.deletesFromICloud)
        }

        SettingsSection(title: "Skip", footer: "Both numbers make regular runs faster: iCloud lists the newest photos first.") {
            OptionalNumberRow(title: "Only the most recent", prompt: "All", value: $model.config.recent)
            OptionalNumberRow(title: "Stop after this many already downloaded in a row", prompt: "Never", value: $model.config.untilFound)
            ForEach(model.config.excludeFilenames, id: \.self) { pattern in
                SettingRow(title: pattern) {
                    Button { model.config.excludeFilenames.removeAll { $0 == pattern } } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.dangerSoft)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel("Remove \(pattern)")
                }
                .font(.system(.body, design: .monospaced))
            }
            HStack(spacing: 10) {
                FieldWell(width: nil, alignment: .leading) {
                    TextField("File names to skip", text: $newPattern, prompt: Text("File names to skip, like IMG_12*.JPG"))
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addPattern)
                }
                Button("Add", action: addPattern)
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }

        SettingsSection(title: "Delete list",
                        footer: "A text file with one FILENAME<TAB>SIZE<TAB>DATE per line. Matching photos go to Recently Deleted in iCloud; nothing is downloaded. Check the list first.") {
            SettingSwitch(title: "Accept lines without a date", isOn: $allowUndated)
            HStack(spacing: 10) {
                Button("Check a Delete List…") { model.runDeleteList(dryRun: true, allowUndated: allowUndated) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 30))
                Button("Delete Photos in a List…") { model.runDeleteList(dryRun: false, allowUndated: allowUndated) }
                    .buttonStyle(PillButtonStyle(kind: .destructive, height: 30))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .disabled(model.phase != .signedIn)
        }

        SettingsSection(title: "iCloud",
                        footer: "Some libraries keep reporting \"indexing\" even though they list normally. The listing may then be incomplete, so this can't be combined with removing from iCloud.") {
            SettingSwitch(title: "Advanced Data Protection: ask for web access",
                          detail: "Apple shows an approval request on your devices the first time", isOn: $model.adpWebAccess)
            SettingSwitch(title: "Continue when iCloud says the library is still indexing", isOn: $model.config.ignoreIndexingState)
                .disabled(model.config.deletesFromICloud)
        }

        SettingsSection(title: "Files in progress") {
            SettingRow(title: "Temporary suffix") {
                FieldWell(width: 110) {
                    TextField("Temporary suffix", text: $model.config.temporarySuffix)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }

        SettingsSection(title: "Command line") {
            Text("The same engine runs from Terminal with icloudpd's options: swift run icloudpd-swift --help")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addPattern() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        if !model.config.excludeFilenames.contains(p) { model.config.excludeFilenames.append(p) }
        newPattern = ""
    }
}

/// The menu bar extra: status, Sync Now, and the last few log lines.
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusLine)
        if let next = model.nextRun, !model.isDownloading {
            Text("Next run \(next.formatted(date: .omitted, time: .shortened))")
        }
        Divider()
        if model.isDownloading {
            Button("Stop") { model.stopDownload() }
        } else {
            Button("Sync Now") {
                // A run that removes from iCloud asks first, and it asks in the window.
                if model.config.deletesFromICloud && !model.config.dryRun && model.askBeforeRemoving { showWindow() }
                model.startDownload()
            }
            .disabled(model.phase != .signedIn || model.directory == nil)
        }
        Button("Show Downloads Folder") { model.openDirectory() }
            .disabled(model.directory == nil)
        Button("Open iCloud Photos") { showWindow() }
        Button("Settings…") {
            showWindow()
            model.page = .settings
        }
        .disabled(!model.isInside)
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
