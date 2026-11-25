#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

/// The app's Settings window (⌘,): every icloudpd option, grouped by what it's for.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Files", systemImage: "doc.on.doc") { FileSettings() }
            Tab("Filters", systemImage: "line.3.horizontal.decrease.circle") { FilterSettings() }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") { SyncSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .environmentObject(model)
        .frame(width: 560)
        .disabled(model.isDownloading)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

/// An optional whole number edited as text: empty means "not set".
struct OptionalNumberField: View {
    let title: String
    let prompt: String
    @Binding var value: Int?

    var body: some View {
        TextField(title, text: Binding(
            get: { value.map(String.init) ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                value = digits.isEmpty ? nil : Int(digits)
            }), prompt: Text(prompt))
            .multilineTextAlignment(.trailing)
    }
}

/// A date bound edited as "2025-01-02" or "20d".
struct DateBoundField: View {
    let title: String
    @Binding var value: DateBound?
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: Text("2025-01-02 or 30d"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(invalid ? Color.red : Color.primary)
                .onSubmit(commit)
                .onChange(of: text) { _, _ in commit() }
        }
        .onAppear {
            switch value {
            case .daysAgo(let d): text = "\(d)d"
            case .date(let date):
                text = date.formatted(.iso8601.year().month().day())
            case nil: text = ""
            }
        }
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { value = nil; invalid = false; return }
        if let parsed = DateBound.parse(text) { value = parsed; invalid = false } else { invalid = true }
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Download automatically", selection: $model.schedule) {
                    ForEach(ScheduleInterval.allCases) { Text($0.label).tag($0) }
                }
                if let next = model.nextRun {
                    LabeledContent("Next run", value: next.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("Runs while the app is open, in the window or the menu bar. New photos are downloaded and your Sync settings are applied.")
            }
            Section {
                Toggle("Show in menu bar", isOn: $model.showInMenuBar)
                Toggle("Open at login", isOn: $model.launchAtLogin)
                Toggle("Notify when a download finishes", isOn: $model.notifyWhenDone)
            } footer: {
                if !AppModel.canNotify {
                    Text("Notifications and Open at Login need the app bundle: build it with scripts/build-app.sh.")
                }
            }
            Section {
                Stepper("Parallel downloads: \(model.config.concurrentDownloads)", value: $model.config.concurrentDownloads, in: 1...16)
            } footer: {
                Text("More parallel downloads finish sooner on a fast connection. \"Stop after N already downloaded\" always downloads one at a time.")
            }
        }
        .formStyle(.grouped)
    }
}

struct FileSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(PhotoSize.allCases, id: \.self) { size in
                    Toggle(size.label, isOn: Binding(
                        get: { model.config.sizes.contains(size) },
                        set: { on in
                            if on { model.config.sizes.append(size) } else if model.config.sizes.count > 1 { model.config.sizes.removeAll { $0 == size } }
                        }))
                }
                Toggle("Only these sizes (don't fall back to the original)", isOn: $model.config.forceSize)
            } header: {
                Text("Sizes")
            } footer: {
                Text("Medium and thumbnail files get -medium and -thumb in their names; edited and alternative files get a suffix only when the name would clash.")
            }
            Section("Live Photos") {
                Picker("Video size", selection: $model.config.livePhotoSize) {
                    Text("Original").tag(LivePhotoSize.original)
                    Text("Medium").tag(LivePhotoSize.medium)
                    Text("Thumbnail").tag(LivePhotoSize.thumb)
                }
                Picker("Video file name", selection: $model.config.livePhotoMovFilenamePolicy) {
                    Text("IMG_0001_HEVC.MOV").tag(LivePhotoMovFilenamePolicy.suffix)
                    Text("IMG_0001.MOV").tag(LivePhotoMovFilenamePolicy.original)
                }
                LabeledContent("Video folder") {
                    HStack {
                        Text(model.config.livePhotoDirectoryPath ?? "Next to the photo")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        if model.config.livePhotoDirectoryPath != nil {
                            Button("Reset") { model.config.livePhotoDirectoryPath = nil }
                        }
                        Button("Choose…") { model.chooseLivePhotoDirectory() }
                    }
                }
            }
            Section {
                Picker("RAW + JPEG", selection: $model.config.alignRaw) {
                    Text("As stored in iCloud").tag(RawPolicy.asIs)
                    Text("RAW is the original").tag(RawPolicy.original)
                    Text("RAW is the alternative").tag(RawPolicy.alternative)
                }
                Picker("Same name, different photo", selection: $model.config.fileMatchPolicy) {
                    Text("Add the file size (IMG_0001-123456.JPG)").tag(FileMatchPolicy.nameSizeDedupWithSuffix)
                    Text("Add the iCloud ID to every name").tag(FileMatchPolicy.nameID7)
                }
                Toggle("Keep accents and other non-ASCII characters in names", isOn: $model.config.keepUnicodeInFilenames)
            } header: {
                Text("Naming")
            } footer: {
                Text("To continue a folder made by icloudpd, match its settings: icloudpd removes non-ASCII characters unless --keep-unicode-in-filenames was used.")
            }
            Section("Metadata") {
                Toggle("Write the photo date into JPEGs that have none", isOn: $model.config.setExifDatetime)
                Toggle("Write XMP sidecar files", isOn: $model.config.xmpSidecar)
                Toggle("Only write XMP sidecars (download nothing)", isOn: $model.config.xmpSidecarOnly)
            }
        }
        .formStyle(.grouped)
    }
}

struct FilterSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var newPattern = ""

    var body: some View {
        Form {
            Section {
                DateBoundField(title: "Skip photos taken before", value: $model.config.skipCreatedBefore)
                DateBoundField(title: "Skip photos taken after", value: $model.config.skipCreatedAfter)
            } footer: {
                Text("A date like 2025-01-02, or a number of days back from now like 30d.")
            }
            Section {
                OptionalNumberField(title: "Only the most recent", prompt: "All", value: $model.config.recent)
                OptionalNumberField(title: "Stop after this many already downloaded in a row", prompt: "Never", value: $model.config.untilFound)
            } footer: {
                Text("Both make regular runs faster: iCloud lists the newest photos first.")
            }
            Section("Skip file names matching") {
                ForEach(model.config.excludeFilenames, id: \.self) { pattern in
                    HStack {
                        Text(pattern).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { model.config.excludeFilenames.removeAll { $0 == pattern } }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Pattern", text: $newPattern, prompt: Text("IMG_12*.JPG"))
                        .onSubmit(addPattern)
                    Button("Add", action: addPattern).disabled(newPattern.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addPattern() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !model.config.excludeFilenames.contains(p) else { return }
        model.config.excludeFilenames.append(p)
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
        Form {
            Section {
                Toggle("Remove local copies of photos deleted in iCloud", isOn: $model.config.autoDelete)
                Toggle("Move files of photos that are gone from iCloud aside", isOn: $model.config.pruneOrphans)
            } header: {
                Text("This Mac")
            } footer: {
                Text("The first removes files whose photo is in Recently Deleted. The second moves files this app downloaded into .icloudpd-swift-pruned when their photo is no longer in the library at all; nothing is deleted.")
            }
            Section {
                Toggle("Delete from iCloud after downloading", isOn: $model.config.deleteAfterDownload)
                Toggle("Keep only recent photos in iCloud", isOn: moveMode)
                if model.config.keepICloudRecentDays != nil {
                    Stepper("Keep the last \(model.config.keepICloudRecentDays ?? 0) days",
                            value: Binding(get: { model.config.keepICloudRecentDays ?? 0 },
                                           set: { model.config.keepICloudRecentDays = $0 }),
                            in: 0...3650)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("Photos are only deleted once they are safely on this Mac, and go to Recently Deleted in iCloud. The app asks before each run that deletes, except scheduled runs.")
            }
            Section {
                Toggle("Accept lines without a date", isOn: $allowUndated)
                HStack {
                    Button("Check a Delete List…") { model.runDeleteList(dryRun: true, allowUndated: allowUndated) }
                    Button("Delete Photos in a List…", role: .destructive) { model.runDeleteList(dryRun: false, allowUndated: allowUndated) }
                }
            } header: {
                Text("Delete list")
            } footer: {
                Text("A text file with one FILENAME<TAB>SIZE<TAB>DATE per line. Matching photos go to Recently Deleted in iCloud; nothing is downloaded. Check the list first.")
            }
            Section {
                Toggle("Always do a dry run (change nothing)", isOn: $model.config.dryRun)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Advanced Data Protection: ask for web access", isOn: $model.adpWebAccess)
            } footer: {
                Text("With Advanced Data Protection on, Apple shows an approval request on your devices the first time. \"Access iCloud Data on the Web\" must be on.")
            }
            Section {
                Toggle("Continue when iCloud says the library is still indexing", isOn: $model.config.ignoreIndexingState)
            } footer: {
                Text("Some libraries keep reporting \"indexing\" even though they list normally. The listing may then be incomplete, so this can't be combined with deleting from iCloud.")
            }
            Section("In-progress downloads") {
                TextField("Temporary suffix", text: $model.config.temporarySuffix)
            }
            Section("Command line") {
                Text("The same engine runs from Terminal with icloudpd's options: swift run icloudpd-swift --help")
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
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
            Button("Download Now") { model.startDownload() }
                .disabled(model.phase != .signedIn || model.directory == nil)
        }
        Button("Show Downloads Folder") { model.openDirectory() }
            .disabled(model.directory == nil)
        Button("Open iCloud Photos Downloader") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif
