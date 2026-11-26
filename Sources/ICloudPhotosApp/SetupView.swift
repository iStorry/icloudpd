#if canImport(SwiftUI) && os(macOS)
import ICloudKit
import SwiftUI

/// The questions the guided setup asks, in order: the few choices that matter for a download.
enum SetupStep: Int, CaseIterable, Identifiable {
    case folder, photoSize, livePhotoSize, videoSize, folders, keep, log

    var id: Int { rawValue }

    /// The short name in the sidebar.
    var name: String {
        switch self {
        case .folder: return "Folder"
        case .photoSize: return "Photo size"
        case .livePhotoSize: return "Live Photo size"
        case .videoSize: return "Video size"
        case .folders: return "Folder layout"
        case .keep: return "Keep in iCloud"
        case .log: return "Activity detail"
        }
    }

    var question: String {
        switch self {
        case .folder: return "Where should your photos go?"
        case .photoSize: return "What size should photos be?"
        case .livePhotoSize: return "What about Live Photos?"
        case .videoSize: return "What size should videos be?"
        case .folders: return "How should the folders be laid out?"
        case .keep: return "Should photos stay in iCloud?"
        case .log: return "How much should the activity list show?"
        }
    }

    var explanation: String {
        switch self {
        case .folder:
            return "Pick a folder on this Mac or an external drive. Photos that are already in it are skipped, so you can use a folder from an earlier download."
        case .photoSize:
            return "iCloud keeps each photo in a few sizes. Smaller ones save disk space but lose detail."
        case .livePhotoSize:
            return "A Live Photo is a photo with a few seconds of video attached. This is about that video; the photo itself follows the photo size."
        case .videoSize:
            return "Videos are by far the biggest files in most libraries."
        case .folders:
            return "Photos are sorted into folders by the date they were taken."
        case .keep:
            return "This decides whether the download is a backup, or a way to free up iCloud storage."
        case .log:
            return "The activity list is the running log you see while a download is going."
        }
    }
}

/// The guided setup: its steps and answers in the sidebar, one question beside it.
struct SetupFlow: View {
    @EnvironmentObject var model: AppModel
    @State private var step: SetupStep = .folder

    var body: some View {
        HStack(spacing: WindowButtons.margin) {
            sidebar
            stage.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Button { model.page = .library } label: { CircleIcon(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Back")
                    .accessibilityLabel("Back")
                Text("Setup")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
            }
            .padding(.leading, 4)

            VStack(spacing: 2) {
                ForEach(SetupStep.allCases) { item in
                    let isOn = step == item
                    Button { step = item } label: {
                        HStack(spacing: 10) {
                            Text("\(item.rawValue + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .frame(width: 22, height: 22)
                                .background(isOn ? Theme.accent : Color.white.opacity(0.1), in: .circle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .font(.system(size: 14, weight: isOn ? .semibold : .regular))
                                Text(answer(item))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 48)
                        .background(isOn ? Theme.accent.opacity(0.22) : Color.clear, in: .rect(cornerRadius: 11, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
            }

            Spacer(minLength: 0)

            Button { model.page = .settings } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("All settings")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Every option, for when the questions here aren't enough")
        }
        .sidebarColumn(width: 300)
        .disabled(model.isDownloading)
    }

    /// The current answer to a step, for the sidebar.
    private func answer(_ step: SetupStep) -> String {
        let c = model.config
        switch step {
        case .folder:
            return model.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Not chosen yet"
        case .photoSize:
            return c.sizes.count == 1 ? c.sizes[0].shortLabel : "\(c.sizes.count) sizes"
        case .livePhotoSize:
            return c.skipLivePhotos ? "Photo only" : c.livePhotoSize.shortLabel
        case .videoSize:
            if c.skipVideos { return "Not downloaded" }
            return c.videoSize?.shortLabel ?? "Same as photos"
        case .folders:
            return FolderStructure(rawValue: c.folderStructure)?.label ?? "Custom"
        case .keep:
            if let days = c.keepICloudRecentDays { return "Last \(days) days only" }
            return "Everything stays"
        case .log:
            return model.logLevel.label
        }
    }

    // MARK: The question

    private var stage: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STEP \(step.rawValue + 1) OF \(SetupStep.allCases.count)")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.accentSoft)
                        Text(step.question)
                            .font(.system(size: 30, weight: .semibold))
                            .tracking(-0.7)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(step.explanation)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) { options }
                }
                .frame(maxWidth: 580, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .disabled(model.isDownloading)

            HStack(spacing: 12) {
                if let previous = SetupStep(rawValue: step.rawValue - 1) {
                    Button { step = previous } label: { Text("Back").frame(width: 70) }
                        .buttonStyle(PillButtonStyle(kind: .secondary, height: 44))
                }
                Spacer(minLength: 0)
                if let next = SetupStep(rawValue: step.rawValue + 1) {
                    Button { step = next } label: { Text("Continue").frame(width: 90) }
                        .buttonStyle(PillButtonStyle(height: 44))
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .folder && model.directory == nil)
                } else {
                    Button { model.page = .library } label: { Text("Done").frame(width: 90) }
                        .buttonStyle(PillButtonStyle(height: 44))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: 580)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.smooth(duration: 0.2), value: step)
    }

    @ViewBuilder private var options: some View {
        switch step {
        case .folder: folderOptions
        case .photoSize: photoSizeOptions
        case .livePhotoSize: livePhotoOptions
        case .videoSize: videoOptions
        case .folders: folderLayoutOptions
        case .keep: keepOptions
        case .log: logOptions
        }
    }

    private var folderOptions: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.accentSoft)
            Text(model.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen yet")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(model.directory == nil ? Theme.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(model.directory == nil ? "Choose Folder…" : "Change…") { model.chooseDirectory() }
                .buttonStyle(PillButtonStyle(kind: model.directory == nil ? .primary : .secondary, height: 32))
                .fixedSize()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(cornerRadius: 14)
    }

    @ViewBuilder private var photoSizeOptions: some View {
        let sizes = model.config.sizes
        SetupOption(title: "Original", detail: "The full-quality file, exactly as it was taken. The biggest files, and the right choice for a backup.",
                    isOn: sizes == [.original]) { model.config.sizes = [.original] }
        SetupOption(title: "Edited", detail: "With the edits you made in Photos applied, such as crops and filters. Photos you never edited come as the original.",
                    isOn: sizes == [.adjusted]) { model.config.sizes = [.adjusted] }
        SetupOption(title: "Medium", detail: "A smaller copy that iCloud makes. Fine for looking at on a screen, and takes much less space.",
                    isOn: sizes == [.medium]) { model.config.sizes = [.medium] }
        SetupOption(title: "Thumbnail", detail: "A tiny preview. Only useful as an index of what is in your library.",
                    isOn: sizes == [.thumb]) { model.config.sizes = [.thumb] }
        if sizes.count > 1 || sizes == [.alternative] {
            SetupNote(text: "All settings has a different choice here: \(sizes.map(\.shortLabel).joined(separator: ", ")). Picking one above replaces it.")
        }
    }

    @ViewBuilder private var livePhotoOptions: some View {
        let c = model.config
        SetupOption(title: "Original", detail: "The video as it was recorded, saved next to the photo.",
                    isOn: !c.skipLivePhotos && c.livePhotoSize == .original) { chooseLive(.original) }
        SetupOption(title: "Medium", detail: "A smaller copy of the video.",
                    isOn: !c.skipLivePhotos && c.livePhotoSize == .medium) { chooseLive(.medium) }
        SetupOption(title: "Thumbnail", detail: "A very small copy of the video.",
                    isOn: !c.skipLivePhotos && c.livePhotoSize == .thumb) { chooseLive(.thumb) }
        SetupOption(title: "Photo only", detail: "Skip the video and keep just the still photo.",
                    isOn: c.skipLivePhotos) { model.config.skipLivePhotos = true }
    }

    private func chooseLive(_ size: LivePhotoSize) {
        model.config.skipLivePhotos = false
        model.config.livePhotoSize = size
    }

    private func chooseVideo(_ size: PhotoSize) {
        model.config.skipVideos = false
        model.config.videoSize = size
    }

    @ViewBuilder private var videoOptions: some View {
        let c = model.config
        SetupOption(title: "Original", detail: "Full quality, as recorded. A minute of 4K video can be several hundred megabytes.",
                    isOn: !c.skipVideos && (c.videoSize == .original || (c.videoSize == nil && c.sizes == [.original]))) { chooseVideo(.original) }
        SetupOption(title: "Medium", detail: "A smaller copy that iCloud makes. Good enough to watch, and much lighter.",
                    isOn: !c.skipVideos && c.videoSize == .medium) { chooseVideo(.medium) }
        SetupOption(title: "Thumbnail", detail: "A very small, low-quality copy.",
                    isOn: !c.skipVideos && c.videoSize == .thumb) { chooseVideo(.thumb) }
        SetupOption(title: "Don't download videos", detail: "Photos only. Videos stay in iCloud and are left alone.",
                    isOn: c.skipVideos) { model.config.skipVideos = true }
        if !c.skipVideos, c.videoSize == nil, c.sizes != [.original] {
            SetupNote(text: "Videos currently follow the photo size (\(c.sizes.map(\.shortLabel).joined(separator: ", "))). Pick one above to give them their own.")
        }
    }

    @ViewBuilder private var folderLayoutOptions: some View {
        let current = model.config.folderStructure
        ForEach(FolderStructure.allCases, id: \.self) { layout in
            SetupOption(title: layout.label, detail: example(layout.rawValue), isOn: current == layout.rawValue, monospacedDetail: true) {
                model.config.folderStructure = layout.rawValue
            }
        }
        if FolderStructure(rawValue: current) == nil {
            SetupOption(title: "Custom", detail: example(current), isOn: true, monospacedDetail: true) {}
            SetupNote(text: "A custom layout is set in All settings. Picking one above replaces it.")
        }
    }

    /// Where a photo taken today would land with this layout.
    private func example(_ format: String) -> String {
        let folder = (try? FolderFormat(format))?.path(for: Date()) ?? ""
        return (folder.isEmpty ? "" : folder + "/") + "IMG_0001.HEIC"
    }

    @ViewBuilder private var keepOptions: some View {
        let days = model.config.keepICloudRecentDays
        SetupOption(title: "Keep everything in iCloud",
                    detail: "Nothing is ever removed from iCloud. The folder on this Mac is a second copy.",
                    isOn: days == nil) { model.config.keepICloudRecentDays = nil }
        SetupOption(title: "Only keep recent photos in iCloud",
                    detail: "Once a photo is safely on this Mac and older than the number of days you set, it is moved to Recently Deleted in iCloud, which holds it for 30 more days. This frees iCloud storage, and the copy on this Mac becomes the only one.",
                    isOn: days != nil, isRisky: true) {
            if days == nil { model.config.keepICloudRecentDays = 30 }
        }
        if days != nil {
            HStack(spacing: 10) {
                Text("Keep the last")
                FieldWell(width: 80) {
                    TextField("Days", text: Binding(
                        get: { String(model.config.keepICloudRecentDays ?? 0) },
                        set: { text in
                            model.config.keepICloudRecentDays = min(Int(text.filter(\.isNumber)) ?? 0, 3650)
                        }))
                }
                Text((model.config.keepICloudRecentDays ?? 0) == 1 ? "day in iCloud" : "days in iCloud")
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(cornerRadius: 14)
            SetupNote(text: "The app asks before every download you start that will delete from iCloud. Downloads that run on a schedule don't ask.", isWarning: true)
        }
    }

    @ViewBuilder private var logOptions: some View {
        SetupOption(title: "Normal", detail: "Each file as it is downloaded, and any problem.",
                    isOn: model.logLevel == .info || model.logLevel == .warning) { model.logLevel = .info }
        SetupOption(title: "Detailed", detail: "Also every file that was already saved, and what the app is doing behind the scenes. Useful when something goes wrong.",
                    isOn: model.logLevel == .debug) { model.logLevel = .debug }
        SetupOption(title: "Problems only", detail: "Nothing unless a file fails or something needs your attention.",
                    isOn: model.logLevel == .error) { model.logLevel = .error }
    }
}

/// One answer to a setup question: a name, what it means in plain words, and whether it is chosen.
struct SetupOption: View {
    let title: String
    let detail: String
    let isOn: Bool
    var isRisky = false
    var monospacedDetail = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? highlight : Color.white.opacity(0.3))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .medium))
                    Text(detail)
                        .font(monospacedDetail ? .system(size: 12, design: .monospaced) : .system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(cornerRadius: 14,
                   fill: isOn ? highlight.opacity(0.14) : Theme.panelFill,
                   stroke: isOn ? highlight.opacity(0.6) : Theme.panelStroke)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var highlight: Color { isRisky ? Theme.warning : Theme.accentSoft }
}

/// A line of small print under the options.
struct SetupNote: View {
    let text: String
    var isWarning = false

    var body: some View {
        Label(text, systemImage: isWarning ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.system(size: 12))
            .foregroundStyle(isWarning ? Theme.warning : Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.top, 2)
    }
}

extension PhotoSize {
    var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .adjusted: return "Edited"
        case .alternative: return "Alternative"
        case .medium: return "Medium"
        case .thumb: return "Thumbnail"
        }
    }
}

extension LivePhotoSize {
    var shortLabel: String {
        switch self {
        case .original: return "Original"
        case .medium: return "Medium"
        case .thumb: return "Thumbnail"
        }
    }
}

extension SyncLogLevel {
    var label: String {
        switch self {
        case .debug: return "Detailed"
        case .info, .warning: return "Normal"
        case .error: return "Problems only"
        }
    }
}
#endif
