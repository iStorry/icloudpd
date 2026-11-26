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
        case .freeUp: return "Make room in iCloud by keeping photos on this Mac instead."
        case .photos: return "Which photos come to this Mac, how good they look, and where they go."
        case .general: return "Your account, when it runs by itself, and how it lets you know."
        case .advanced: return "Extra options. You don't need to change anything here."
        }
    }

    var symbol: String {
        switch self {
        case .freeUp: return "icloud.slash"
        case .photos: return "photo.on.rectangle"
        case .general: return "clock"
        case .advanced: return "gearshape.2"
        }
    }
}

/// The chosen section of Settings, beside the main sidebar.
struct SettingsStage: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: SettingsPane
    @State private var showingAlbums = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pane.title)
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-0.9)
                        Text(pane.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { model.page = .setup } label: {
                        Label("Easy Setup", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 32))
                    .help("Answer the three easy questions again")
                    .disabled(model.isDownloading)
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
    var icon: RowIcon?
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        // A native labelled row underneath, so the title, its line and the control are read as one.
        LabeledContent {
            control
        } label: {
            HStack(spacing: 12) {
                if let icon { icon }
                rowText
            }
        }
        .labeledContentStyle(SettingRowStyle())
    }

    private var rowText: some View {
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
    }
}

/// The small coloured tile at the start of a settings row, as System Settings has.
struct RowIcon: View {
    let symbol: String
    let color: Color

    init(_ symbol: String, _ color: Color) {
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct SettingSwitch: View {
    var icon: RowIcon?
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(icon: icon, title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct SettingPicker<Value: Hashable, Options: View>: View {
    var icon: RowIcon?
    let title: String
    var detail: String?
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        SettingRow(icon: icon, title: title, detail: detail) {
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
            NumberStepper(title: title, value: $value, range: range)
        }
    }
}

/// One of two or more answers in a card, with a radio mark.
struct ChoiceRow: View {
    var icon: RowIcon?
    let title: String
    let detail: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingRow(icon: icon, title: title, detail: detail) {
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

        SettingsSection(title: "When a photo is safely on this Mac") {
            ChoiceRow(icon: RowIcon("icloud.fill", .blue), title: "Keep it in iCloud too",
                      detail: "This Mac gets a copy. iCloud doesn't change.", isOn: !removing) {
                model.config.keepICloudRecentDays = nil
                model.config.deleteAfterDownload = false
            }
            ChoiceRow(icon: RowIcon("icloud.slash.fill", .orange), title: "Remove it from iCloud",
                      detail: "Makes room in iCloud. This Mac keeps the photo in full quality.", isOn: removing) {
                if model.config.keepICloudRecentDays == nil { model.config.keepICloudRecentDays = 365 }
                model.config.deleteAfterDownload = false
                // Both are refused next to deleting from iCloud.
                model.config.ignoreIndexingState = false
                model.config.xmpSidecarOnly = false
            }
        }

        if removing {
            SettingsSection(title: "Which photos leave iCloud",
                            footer: "Newer photos stay in iCloud, so they're still on your iPhone. This moves forward by itself every day.") {
                SettingPicker(icon: RowIcon("clock.arrow.circlepath", .purple), title: "Photos older than", selection: ageBinding) {
                    ForEach(ageChoices, id: \.self) { Text($0 == 0 ? "Any age" : RemovalAge.label($0)).tag($0) }
                }
                SettingRow(icon: RowIcon("calendar", .red), title: "Dates", detail: PhotoSettings.plainRange(model.config)) {
                    Button("Change") { pane = .photos }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                }
            }
        }

        SettingsSection(title: "Safety",
                        footer: "Removed photos wait in Recently Deleted in iCloud for 30 days, so you can still get them back.") {
            SettingRow(icon: RowIcon("checkmark.shield.fill", .green), title: "Only once the photo is safely here",
                       detail: "Always on. If a photo didn't download, it stays in iCloud.") {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Theme.secondary)
                    .accessibilityLabel("Always on")
            }
            SettingSwitch(icon: RowIcon("hand.raised.fill", .yellow), title: "Ask me before removing photos",
                          detail: "Not asked when it runs by itself at night", isOn: $model.askBeforeRemoving)
            SettingRow(icon: RowIcon("eye.fill", .teal), title: "Try it first",
                       detail: "See what would happen, without changing anything") {
                Button("Preview") { model.startDownload(dryRun: true) }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                    .disabled(model.phase != .signedIn || model.directory == nil)
            }
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
                    Text("Next sync \(HomeStage.dayAndTime(next))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.66, green: 0.8, blue: 1))
                }
            }
            HStack(spacing: 2) {
                if removing {
                    bar("Only on this Mac", isOn: true).layoutPriority(1)
                    if age > 0 { bar("Also in iCloud", isOn: false).frame(width: 120) }
                } else {
                    bar("In iCloud and on this Mac", isOn: false)
                }
            }
            .frame(height: 26)
            .clipShape(.rect(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            HStack {
                Text(removing && age > 0 ? "Older photos" : PhotoSettings.plainRange(model.config))
                Spacer()
                if removing, age > 0 {
                    Text("Since \(RemovalAge.cutoff(age).formatted(date: .abbreviated, time: .omitted))")
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
                SettingPicker(icon: RowIcon("books.vertical.fill", .brown), title: "Library", selection: libraryBinding) {
                    ForEach(model.libraries, id: \.self) { Text(model.libraryLabel($0)).tag($0) }
                }
            }
            SettingRow(icon: RowIcon("rectangle.stack.fill", .blue), title: "Albums", detail: albumSummary) {
                Button("Choose…") { showingAlbums = true }
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
                    .disabled(model.phase != .signedIn)
            }
            SettingPicker(icon: RowIcon("calendar", .red), title: "Dates", detail: "By the day each photo was taken", selection: rangeBinding) {
                Text("Any date").tag(DateRange.anyTime)
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
        }

        SettingsSection(title: "What to bring over") {
            SettingSwitch(icon: RowIcon("photo.fill", .blue), title: "Photos", isOn: inverted(\.skipPhotos))
            SettingSwitch(icon: RowIcon("video.fill", .pink), title: "Videos", isOn: inverted(\.skipVideos))
            SettingSwitch(icon: RowIcon("livephoto", .yellow), title: "Live Photo videos",
                          detail: "The few seconds of movement saved with a Live Photo", isOn: inverted(\.skipLivePhotos))
            SettingSwitch(icon: RowIcon("camera.viewfinder", .gray), title: "Screenshots", isOn: inverted(\.skipScreenshots))
        }

        SettingsSection(title: "Quality",
                        footer: "Choose full quality when you're removing photos from iCloud: this Mac will have the only copy.") {
            SettingPicker(icon: RowIcon("photo", .indigo), title: "Photos", selection: photoQuality) {
                ForEach([PhotoSize.original, .adjusted, .medium, .thumb], id: \.self) { Text($0.qualityLabel).tag(Optional($0)) }
                if model.config.sizes.count > 1 || model.config.sizes == [.alternative] {
                    Text("Several (set in Advanced)").tag(PhotoSize?.none)
                }
            }
            SettingPicker(icon: RowIcon("video", .pink), title: "Videos", selection: videoQuality) {
                Text("Same as photos").tag("same")
                Text("Full quality").tag("original")
                Text("Smaller").tag("medium")
                Text("Tiny preview").tag("thumb")
                Divider()
                Text("Don't bring videos").tag("none")
            }
            SettingPicker(icon: RowIcon("livephoto", .yellow), title: "Live Photo videos", selection: liveQuality) {
                Text("Full quality").tag("original")
                Text("Smaller").tag("medium")
                Text("Tiny preview").tag("thumb")
                Divider()
                Text("Just the photo").tag("none")
            }
        }

        SettingsSection(title: "On this Mac") {
            SettingRow(icon: RowIcon("folder.fill", .cyan), title: model.directory?.lastPathComponent ?? "No folder yet",
                       detail: folderDetail) {
                if model.directory != nil {
                    Button("Show") { model.openDirectory() }
                }
                Button("Change…") { model.chooseDirectory() }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 28))
            .help(model.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
            SettingPicker(icon: RowIcon("folder.badge.gearshape", .orange), title: "Sort into folders by",
                          detail: Self.layoutExample(model.config.folderStructure), selection: layoutBinding) {
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
        DateButton(date: date)
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

    /// The same, for a row: "Any date", "Before 26 Nov 2025", "3 Jan 2015 to 26 Nov 2025".
    static func plainRange(_ config: SyncConfiguration) -> String {
        let from = config.skipCreatedBefore?.resolve().formatted(date: .abbreviated, time: .omitted)
        let to = config.skipCreatedAfter?.resolve().formatted(date: .abbreviated, time: .omitted)
        switch (from, to) {
        case let (from?, to?): return "\(from) to \(to)"
        case let (from?, nil): return "After \(from)"
        case let (nil, to?): return "Before \(to)"
        case (nil, nil): return "Any date"
        }
    }

    /// "2026 › 11 › 26" for a photo taken today, or "All in one folder".
    static func layoutExample(_ format: String) -> String {
        let folder = (try? FolderFormat(format))?.path(for: Date()) ?? ""
        return folder.isEmpty ? "All in one folder" : "Like " + folder.split(separator: "/").joined(separator: " › ")
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

    /// "234 GB free on Macintosh HD": where the folder is, without the path.
    private var folderDetail: String {
        guard let directory = model.directory else { return "Choose where your photos go" }
        guard let space = DiskSpace.of(directory.path) else { return "On this Mac" }
        return "\(AppSidebar.size(space.available)) free on \(space.name)"
    }

    private var albumSummary: String {
        switch model.config.albums.count {
        case 0: return "All your photos"
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
                Text(model.appleID)
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

        SettingsSection(title: "Runs by itself",
                        footer: "It runs while the app is open, in this window or in the menu bar.") {
            SettingPicker(icon: RowIcon("arrow.triangle.2.circlepath", .green), title: "Check for new photos",
                          selection: $model.schedule) {
                ForEach(ScheduleInterval.allCases) { interval in
                    Text(interval == .off ? "Only when I press Sync Now" : interval.label).tag(interval)
                }
            }
            if model.schedule == .daily {
                SettingPicker(icon: RowIcon("moon.stars.fill", .indigo), title: "At", selection: $model.scheduleHour) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(DateComponents(calendar: .current, hour: hour, minute: 0).date?
                            .formatted(date: .omitted, time: .shortened) ?? "\(hour):00").tag(hour)
                    }
                }
            }
            if let next = model.nextRun {
                SettingRow(icon: RowIcon("calendar.badge.clock", .red), title: "Next time") {
                    Text(HomeStage.dayAndTime(next).prefix(1).uppercased() + HomeStage.dayAndTime(next).dropFirst())
                        .foregroundStyle(Theme.secondary)
                }
            }
            SettingSwitch(icon: RowIcon("power", .gray), title: "Start when I log in",
                          detail: "So it can run at night without you opening it", isOn: $model.launchAtLogin)
        }

        SettingsSection(title: "Keeping you posted",
                        footer: AppModel.canNotify ? nil
                            : "Notifications and starting at login need the app bundle: build it with scripts/build-app.sh.") {
            SettingSwitch(icon: RowIcon("menubar.rectangle", .blue), title: "Show in the menu bar",
                          detail: "See how it's going and press Sync Now from the top of the screen", isOn: $model.showInMenuBar)
            SettingSwitch(icon: RowIcon("bell.badge.fill", .red), title: "Tell me when it's done",
                          detail: "Only when photos were saved, removed or couldn't be", isOn: $model.notifyWhenDone)
        }
    }
}

// MARK: Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newPattern = ""
    @State private var allowUndated = false

    var body: some View {
        SettingsSection(title: "Keep this Mac in step with iCloud",
                        footer: "Set-aside files go into a .icloudpd-swift-pruned folder inside your photos folder; nothing is deleted.") {
            SettingSwitch(title: "Delete photos here when they're deleted in iCloud",
                          detail: "When a photo is in Recently Deleted, its file on this Mac goes too",
                          isOn: $model.config.autoDelete)
            SettingSwitch(title: "Set aside files whose photo is gone from iCloud",
                          detail: "Only files this app downloaded", isOn: $model.config.pruneOrphans)
        }

        SettingsSection(title: "Runs",
                        footer: "More parallel downloads finish sooner on a fast connection. \"Stop after N already downloaded\" always downloads one at a time.") {
            SettingStepper(title: "Parallel downloads", value: $model.config.concurrentDownloads, range: 1...16)
            SettingPicker(title: "Activity details show", selection: $model.logLevel) {
                Text("Each file and any problem").tag(SyncLogLevel.info)
                Text("Everything, in detail").tag(SyncLogLevel.debug)
                Text("Problems only").tag(SyncLogLevel.error)
            }
            SettingSwitch(title: "Always just preview", detail: "Nothing is downloaded, moved or removed", isOn: $model.config.dryRun)
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
