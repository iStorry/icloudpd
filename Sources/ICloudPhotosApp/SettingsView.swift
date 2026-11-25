#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

/// The sections of the settings page: every icloudpd option, grouped by what it's for.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, files, filters, sync, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .files: return "Files"
        case .filters: return "Filters"
        case .sync: return "Sync"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .files: return "doc.on.doc"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .sync: return "arrow.triangle.2.circlepath"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

/// The settings page's sidebar: the way back, and its sections.
struct SettingsSidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button { model.showingSettings = false } label: { CircleIcon(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Back")
                    .accessibilityLabel("Back")
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
            }
            .padding(.leading, 4)

            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { item in
                    let isOn = pane == item
                    Button { pane = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .foregroundStyle(isOn ? Theme.accentSoft : Theme.secondary)
                                .frame(width: 22)
                            Text(item.title)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(isOn ? Theme.accent.opacity(0.22) : Color.clear, in: .rect(cornerRadius: 11, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }
        }
        .padding(14)
        // Clear the traffic lights, which sit over the top of the sidebar.
        .padding(.top, 26)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .panel(cornerRadius: 22)
    }
}

/// The chosen section, beside the sidebar.
struct SettingsStage: View {
    @EnvironmentObject var model: AppModel
    let pane: SettingsPane

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(pane.title)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(-0.7)

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
                    case .general: GeneralSettings()
                    case .files: FileSettings()
                    case .filters: FilterSettings()
                    case .sync: SyncSettings()
                    case .advanced: AdvancedSettings()
                    }
                }
                .disabled(model.isDownloading)
                .opacity(model.isDownloading ? 0.45 : 1)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A setting's name on the left, which may wrap, and its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

struct SettingSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

struct SettingPicker<Value: Hashable, Options: View>: View {
    let title: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        SettingRow(title: title) {
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
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        SettingRow(title: title) {
            Text(value.formatted())
                .monospacedDigit()
                .foregroundStyle(Theme.secondary)
            Stepper(title, value: $value, in: range)
                .labelsHidden()
        }
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

/// A date bound edited as "2025-01-02" or "20d".
struct DateBoundRow: View {
    let title: String
    @Binding var value: DateBound?
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        SettingRow(title: title) {
            FieldWell {
                TextField(title, text: $text, prompt: Text("2025-01-02 or 30d"))
                    .foregroundStyle(invalid ? Theme.dangerSoft : Color.primary)
                    .onSubmit(commit)
                    .onChange(of: text) { _, _ in commit() }
            }
        }
        .onAppear {
            switch value {
            case .daysAgo(let d): text = "\(d)d"
            case .date(let date):
                // In this Mac's time zone, as it is read back: in UTC the day can come out one
                // early, and reading that back would move the date a day every time this appears.
                text = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
            case nil: text = ""
            }
        }
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { value = nil; invalid = false; return }
        if let parsed = DateBound.parse(text) { value = parsed; invalid = false } else { invalid = true }
    }
}

// MARK: Sections

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsSection(footer: "Runs while the app is open, in the window or the menu bar. New photos are downloaded and your Sync settings are applied.") {
            SettingPicker(title: "Download automatically", selection: $model.schedule) {
                ForEach(ScheduleInterval.allCases) { Text($0.label).tag($0) }
            }
            if let next = model.nextRun {
                SettingRow(title: "Next run") {
                    Text(next.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Theme.secondary)
                }
            }
        }
        SettingsSection(footer: AppModel.canNotify ? nil
                        : "Notifications and Open at Login need the app bundle: build it with scripts/build-app.sh.") {
            SettingSwitch(title: "Show in menu bar", isOn: $model.showInMenuBar)
            SettingSwitch(title: "Open at login", isOn: $model.launchAtLogin)
            SettingSwitch(title: "Notify when a download finishes", isOn: $model.notifyWhenDone)
        }
        SettingsSection(footer: "More parallel downloads finish sooner on a fast connection. \"Stop after N already downloaded\" always downloads one at a time.") {
            SettingStepper(title: "Parallel downloads", value: $model.config.concurrentDownloads, range: 1...16)
        }
    }
}

struct FileSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsSection(title: "Sizes",
                        footer: "Medium and thumbnail files get -medium and -thumb in their names; edited and alternative files get a suffix only when the name would clash.") {
            ForEach(PhotoSize.allCases, id: \.self) { size in
                let isOnlyOne = model.config.sizes == [size]
                SettingSwitch(title: size.label, isOn: Binding(
                    get: { model.config.sizes.contains(size) },
                    set: { on in
                        if on { model.config.sizes.append(size) } else { model.config.sizes.removeAll { $0 == size } }
                    }))
                    // At least one size stays chosen: the last one can't be switched off.
                    .disabled(isOnlyOne)
            }
            SettingSwitch(title: "Only these sizes (don't fall back to the original)", isOn: $model.config.forceSize)
        }
        SettingsSection(title: "Live Photos") {
            SettingPicker(title: "Video size", selection: $model.config.livePhotoSize) {
                Text("Original").tag(LivePhotoSize.original)
                Text("Medium").tag(LivePhotoSize.medium)
                Text("Thumbnail").tag(LivePhotoSize.thumb)
            }
            SettingPicker(title: "Video file name", selection: $model.config.livePhotoMovFilenamePolicy) {
                Text("IMG_0001_HEVC.MOV").tag(LivePhotoMovFilenamePolicy.suffix)
                Text("IMG_0001.MOV").tag(LivePhotoMovFilenamePolicy.original)
            }
            SettingRow(title: "Video folder") {
                Text(model.config.livePhotoDirectoryPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Next to the photo")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.secondary)
                if model.config.livePhotoDirectoryPath != nil {
                    Button("Reset") { model.config.livePhotoDirectoryPath = nil }
                }
                Button("Choose…") { model.chooseLivePhotoDirectory() }
            }
            .buttonStyle(PillButtonStyle(kind: .secondary, height: 26))
        }
        SettingsSection(title: "Naming",
                        footer: "To continue a folder made by icloudpd, match its settings: icloudpd removes non-ASCII characters unless --keep-unicode-in-filenames was used.") {
            SettingPicker(title: "RAW + JPEG", selection: $model.config.alignRaw) {
                Text("As stored in iCloud").tag(RawPolicy.asIs)
                Text("RAW is the original").tag(RawPolicy.original)
                Text("RAW is the alternative").tag(RawPolicy.alternative)
            }
            SettingPicker(title: "Same name, different photo", selection: $model.config.fileMatchPolicy) {
                Text("Add the file size (IMG_0001-123456.JPG)").tag(FileMatchPolicy.nameSizeDedupWithSuffix)
                Text("Add the iCloud ID to every name").tag(FileMatchPolicy.nameID7)
            }
            SettingSwitch(title: "Keep accents and other non-ASCII characters in names", isOn: $model.config.keepUnicodeInFilenames)
        }
        SettingsSection(title: "Metadata") {
            SettingSwitch(title: "Write the photo date into JPEGs that have none", isOn: $model.config.setExifDatetime)
            SettingSwitch(title: "Write XMP sidecar files", isOn: $model.config.xmpSidecar)
            SettingSwitch(title: "Only write XMP sidecars (download nothing)", isOn: $model.config.xmpSidecarOnly)
        }
    }
}

struct FilterSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newPattern = ""

    var body: some View {
        SettingsSection(footer: "A date like 2025-01-02, or a number of days back from now like 30d.") {
            DateBoundRow(title: "Skip photos taken before", value: $model.config.skipCreatedBefore)
            DateBoundRow(title: "Skip photos taken after", value: $model.config.skipCreatedAfter)
        }
        SettingsSection(footer: "Both make regular runs faster: iCloud lists the newest photos first.") {
            OptionalNumberRow(title: "Only the most recent", prompt: "All", value: $model.config.recent)
            OptionalNumberRow(title: "Stop after this many already downloaded in a row", prompt: "Never", value: $model.config.untilFound)
        }
        SettingsSection(title: "Skip file names matching") {
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
                    TextField("Pattern", text: $newPattern, prompt: Text("IMG_12*.JPG"))
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(addPattern)
                }
                Button("Add", action: addPattern)
                    .buttonStyle(PillButtonStyle(kind: .secondary, height: 26))
                    .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func addPattern() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        if !model.config.excludeFilenames.contains(p) { model.config.excludeFilenames.append(p) }
        newPattern = ""
    }
}

struct SyncSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var allowUndated = false

    private var moveMode: Binding<Bool> {
        Binding(get: { model.config.keepICloudRecentDays != nil },
                set: { model.config.keepICloudRecentDays = $0 ? 30 : nil })
    }

    var body: some View {
        SettingsSection(title: "This Mac",
                        footer: "The first removes files whose photo is in Recently Deleted. The second moves files this app downloaded into .icloudpd-swift-pruned when their photo is no longer in the library at all; nothing is deleted.") {
            SettingSwitch(title: "Remove local copies of photos deleted in iCloud", isOn: $model.config.autoDelete)
            SettingSwitch(title: "Move files of photos that are gone from iCloud aside", isOn: $model.config.pruneOrphans)
        }
        SettingsSection(title: "iCloud",
                        footer: "Photos are only deleted once they are safely on this Mac, and go to Recently Deleted in iCloud. The app asks before each run that deletes, except scheduled runs.") {
            SettingSwitch(title: "Delete from iCloud after downloading", isOn: $model.config.deleteAfterDownload)
            SettingSwitch(title: "Keep only recent photos in iCloud", isOn: moveMode)
            if model.config.keepICloudRecentDays != nil {
                SettingStepper(title: "Days to keep",
                               value: Binding(get: { model.config.keepICloudRecentDays ?? 0 },
                                              set: { model.config.keepICloudRecentDays = $0 }),
                               range: 0...3650)
            }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .disabled(model.phase != .signedIn)
        }
        SettingsSection {
            SettingSwitch(title: "Always do a dry run (change nothing)", isOn: $model.config.dryRun)
        }
    }
}

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SettingsSection(footer: "With Advanced Data Protection on, Apple shows an approval request on your devices the first time. \"Access iCloud Data on the Web\" must be on.") {
            SettingSwitch(title: "Advanced Data Protection: ask for web access", isOn: $model.adpWebAccess)
        }
        SettingsSection(footer: "Some libraries keep reporting \"indexing\" even though they list normally. The listing may then be incomplete, so this can't be combined with deleting from iCloud.") {
            SettingSwitch(title: "Continue when iCloud says the library is still indexing", isOn: $model.config.ignoreIndexingState)
        }
        SettingsSection(title: "In-progress downloads") {
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
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            Button("Download Now") {
                // A run that deletes from iCloud asks first, and it asks in the window.
                if model.config.deletesFromICloud && !model.config.dryRun { showWindow() }
                model.startDownload()
            }
            .disabled(model.phase != .signedIn || model.directory == nil)
        }
        Button("Show Downloads Folder") { model.openDirectory() }
            .disabled(model.directory == nil)
        Button("Open iCloud Photos Downloader") { showWindow() }
        Button("Settings…") {
            showWindow()
            model.showingSettings = true
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
