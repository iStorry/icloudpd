#if canImport(SwiftUI) && os(macOS)
import AppKit
import ICloudKit
import ImageIO
import SwiftUI

// MARK: Library glance

/// What the home page shows about the download folder: its size, the disk it is on and its newest photos.
struct LibraryGlance: @unchecked Sendable {
    /// Disk space the folder's files take.
    var bytes: Int64
    var volumeCapacity: Int64?
    var volumeAvailable: Int64?
    /// The disk's name, and whether it is the Mac's own disk rather than an external drive.
    var volumeName: String?
    var isStartupDisk = true
    /// The newest photos in the folder, newest first, as small images for the photo wall.
    var photos: [NSImage]

    static let wallSize = PhotoWall.mostTiles
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png"]

    /// Walks the folder once. Slow on a big library, so it runs off the main thread.
    static func measure(_ root: URL) -> LibraryGlance? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var bytes: Int64 = 0
        var newest: [(date: Date, url: URL)] = []
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize ?? 0)
            // Downloads carry the date the photo was taken, so the newest files are the newest photos.
            guard imageExtensions.contains(url.pathExtension.lowercased()), let date = values.contentModificationDate else { continue }
            newest.append((date, url))
            // A short list, trimmed now and then: sorting every photo of a big library would cost more than the walk.
            if newest.count >= wallSize * 4 {
                newest.sort { $0.date > $1.date }
                newest.removeLast(newest.count - wallSize)
            }
        }
        newest.sort { $0.date > $1.date }
        let photos = newest.prefix(wallSize).compactMap { thumbnail(of: $0.url) }
        let volume = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                                        .volumeLocalizedNameKey, .volumeIsRootFileSystemKey])
        return LibraryGlance(bytes: bytes,
                             volumeCapacity: volume?.volumeTotalCapacity.map(Int64.init),
                             volumeAvailable: volume?.volumeAvailableCapacityForImportantUsage,
                             volumeName: volume?.volumeLocalizedName,
                             isStartupDisk: volume?.volumeIsRootFileSystem ?? true,
                             photos: photos)
    }

    static func thumbnail(of url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

// MARK: Sidebar

/// The main window's sidebar: the app, its pages with Settings' sections under it, the disk space
/// and the account.
struct AppSidebar: View {
    @EnvironmentObject var model: AppModel
    /// One highlight that slides from item to item instead of each item drawing its own.
    @Namespace private var highlight

    private var inSettings: Bool { model.page == .settings }
    private static let motion = Animation.snappy(duration: 0.3, extraBounce: 0)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent, in: .rect(cornerRadius: 9, style: .continuous))
                Text("iCloud Photos")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
            }
            .padding(.leading, 4)

            VStack(spacing: 2) {
                item("Home", "house", isOn: model.page == .library || model.page == .syncChoice) { go(.library) }
                item("Activity", "waveform.path.ecg", isOn: model.page == .activity, busy: model.isDownloading) { go(.activity) }
                item("Settings", "slider.horizontal.3", isOn: false, isOpen: inSettings) { go(.settings) }

                // Settings' sections: always there, folded to no height when Settings isn't open,
                // so opening and closing is one smooth change of height.
                VStack(spacing: 1) {
                    ForEach(SettingsPane.allCases) { subItem($0) }
                }
                .padding(.top, inSettings ? 2 : 0)
                .frame(height: inSettings ? nil : 0, alignment: .top)
                .clipped()
                .opacity(inSettings ? 1 : 0)
                .allowsHitTesting(inSettings)
                .accessibilityHidden(!inSettings)
            }

            Spacer(minLength: 0)

            VStack(spacing: 8) {
                if model.directory != nil { storage }
                account
            }
        }
        .sidebarColumn(width: 264)
        .animation(Self.motion, value: model.page)
        .animation(Self.motion, value: model.settingsPane)
    }

    /// A plain change, not an animated one: only the sidebar animates it (see `body`), so the
    /// page beside it swaps at once instead of fading into the old one.
    private func go(_ page: AppModel.Page) {
        model.page = page
    }

    private func item(_ title: String, _ symbol: String, isOn: Bool, isOpen: Bool = false, busy: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer(minLength: 0)
                if busy { RunBadge(fraction: model.runFraction) }
                if title == "Settings" {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
            }
            .font(.system(size: 13, weight: isOn || isOpen ? .medium : .regular))
            .foregroundStyle(isOn || isOpen ? Color.primary : Color(white: 0.66))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// One section of Settings, indented under it.
    private func subItem(_ pane: SettingsPane) -> some View {
        let isOn = inSettings && model.settingsPane == pane
        return Button {
            model.settingsPane = pane
            model.page = .settings
        } label: {
            HStack(spacing: 9) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isOn ? Theme.accentSoft : Color(white: 0.55))
                    .frame(width: 18)
                Text(pane.title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: isOn ? .medium : .regular))
            .foregroundStyle(isOn ? Color.primary : Color(white: 0.66))
            .padding(.leading, 30)
            .padding(.trailing, 10)
            .frame(height: 32)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .matchedGeometryEffect(id: "selection", in: highlight)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// How much room the folder's disk has, in plain words: free space first, then what the photos take.
    private var storage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: model.glance?.isStartupDisk == false ? "externaldrive" : "internaldrive")
                    .font(.system(size: 12))
                Text(model.glance.map { $0.isStartupDisk ? "Space on this Mac" : "Space on \($0.volumeName ?? "the drive")" }
                     ?? "Space on this Mac")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)

            if let glance = model.glance, let capacity = glance.volumeCapacity, let free = glance.volumeAvailable, capacity > 0 {
                let low = free < 10_000_000_000 || Double(free) / Double(capacity) < 0.05
                Text("\(Text("\(Self.size(free)) free").font(.system(size: 15, weight: .semibold)).foregroundStyle(low ? Theme.warning : Color.primary)) of \(Self.size(capacity))")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                GeometryReader { geo in
                    let photos = Double(glance.bytes) / Double(capacity)
                    let other = Double(max(0, capacity - free - glance.bytes)) / Double(capacity)
                    HStack(spacing: 1) {
                        Rectangle().fill(Theme.accent).frame(width: max(2, geo.size.width * photos))
                        Rectangle().fill(Color.white.opacity(0.26)).frame(width: geo.size.width * other)
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 6)
                .background(Color.white.opacity(0.08))
                .clipShape(.capsule)
                .accessibilityHidden(true)
                Text(low ? "Running low on space" : "Your photos use \(Self.size(glance.bytes))")
                    .font(.system(size: 12))
                    .foregroundStyle(low ? Theme.warning : Theme.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    static func size(_ bytes: Int64) -> String {
        let gigabytes = Double(bytes) / 1e9
        if gigabytes >= 1_000 { return (gigabytes / 1_000).formatted(.number.precision(.fractionLength(0...1))) + " TB" }
        if gigabytes >= 100 { return gigabytes.formatted(.number.precision(.fractionLength(0))) + " GB" }
        if gigabytes >= 1 { return gigabytes.formatted(.number.precision(.fractionLength(0...1))) + " GB" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var account: some View {
        Menu {
            Section(model.appleID) {
                Button("Reload Libraries and Albums", systemImage: "arrow.clockwise") {
                    Task { await model.loadLibraries() }
                }
                .disabled(model.phase != .signedIn)
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") { model.signOut() }
                    .disabled(model.isDownloading)
            }
        } label: {
            HStack(spacing: 10) {
                Text(Initials.of(model.accountName ?? model.appleID))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(LinearGradient(colors: [Theme.accent, Color(red: 0.36, green: 0.61, blue: 1)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.accountName ?? model.appleID)
                        .font(.system(size: 13, weight: .semibold))
                    if model.accountName != nil {
                        Text(model.appleID)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .truncationMode(.middle)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(10)
            .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 14, style: .continuous))
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Account")
        .accessibilityLabel("Account")
    }
}

// MARK: Home

/// The home page: the newest photos behind where the library stands, and the setup that matters most below.
struct HomeStage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            hero.frame(minHeight: 280, maxHeight: .infinity)
            if let notice = model.notice {
                ErrorBanner(message: notice)
            }
            HStack(alignment: .top, spacing: 12) {
                planCard
                folderCard
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            PhotoWall(photos: model.glance?.photos ?? [])
            LinearGradient(stops: [.init(color: Theme.background.opacity(0.1), location: 0),
                                   .init(color: Theme.background.opacity(0.2), location: 0.25),
                                   .init(color: Theme.background.opacity(0.62), location: 0.58),
                                   .init(color: Theme.background.opacity(0.96), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 24) {
                    words(size: 38)
                    Spacer(minLength: 0)
                    buttons
                }
                VStack(alignment: .leading, spacing: 16) {
                    words(size: 30)
                    buttons
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 28)
        }
        .overlay(alignment: .topTrailing) {
            if let next = model.nextRun, model.directory != nil, !model.isDownloading {
                Label("Next sync \(Self.dayAndTime(next))", systemImage: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 0.9))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.ultraThinMaterial, in: .capsule)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                    .padding(16)
            }
        }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }

    private func words(size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            status
            Text(headline)
                .font(.system(size: size, weight: .bold))
                .tracking(-size / 30)
                .fixedSize(horizontal: false, vertical: true)
            Text(subline)
                .font(.system(size: 14))
                .foregroundStyle(Color(white: 0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        if model.phase == .restoring {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Connecting to iCloud…")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.secondary)
        } else if model.isDownloading {
            StatusDot(text: model.currentDryRun ? "Dry run in progress" : "Syncing", color: Theme.accentSoft)
        } else if model.directory == nil {
            EmptyView()
        } else if model.lastRun == nil {
            StatusDot(text: "Not synced yet", color: Color(white: 0.6))
        } else if model.lastRunFailed > 0 {
            StatusDot(text: "\(model.lastRunFailed.formatted()) couldn't download last time", color: Theme.warning)
        } else {
            StatusDot(text: "Up to date", color: Color(red: 0.2, green: 0.78, blue: 0.44))
        }
    }

    private var headline: String {
        if model.directory == nil { return "Choose a folder\nto begin." }
        if let items = model.lastRunItems, items > 0 { return "\(items.formatted()) photos and videos,\nsafe on your Mac." }
        if model.lastRun != nil { return "Your library,\nsafe on your Mac." }
        return "Ready when you are."
    }

    private var subline: String {
        if model.isDownloading { return model.statusLine }
        if let lastRun = model.lastRun, model.directory != nil {
            var text = "Last synced \(Self.dayAndTime(lastRun))"
            if let summary = model.lastRunSummary { text += " · " + summary.replacingOccurrences(of: ", ", with: " · ") }
            return text
        }
        return "Photos already in the folder are skipped, so you can stop and pick up again any time."
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            if model.directory == nil {
                Button { model.chooseDirectory() } label: {
                    Label("Choose Folder…", systemImage: "folder")
                }
                .buttonStyle(HeroButtonStyle())
                .keyboardShortcut(.defaultAction)
            } else if model.isDownloading {
                Button { model.page = .activity } label: {
                    Label("View Progress", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(HeroButtonStyle(isPrimary: false))
                Button { model.stopDownload() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(HeroButtonStyle())
            } else {
                // Sync Now asks first: the same as last time, or something different.
                Button { model.page = .syncChoice } label: {
                    Label("Sync Now", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(HeroButtonStyle())
                .keyboardShortcut(.defaultAction)
                Button { model.startDownload(dryRun: true) } label: {
                    Label("Preview", systemImage: "eye")
                }
                .buttonStyle(HeroButtonStyle(isPrimary: false))
                .help("See what Sync Now would do, without changing anything")
            }
        }
        .fixedSize()
        .disabled(model.directory != nil && !model.isDownloading && model.phase != .signedIn)
    }

    /// "today at 9:41", "tomorrow at 02:00", "12 Nov at 18:30".
    static func dayAndTime(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        if calendar.isDateInTomorrow(date) { return "tomorrow at \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " at \(time)"
    }

    // MARK: Cards

    /// What happens on Sync Now, in a sentence anyone can read.
    private var planCard: some View {
        let removing = model.config.deletesFromICloud
        return HomeCard(title: "Your plan") {
            CardLink(title: "Change") { model.page = .setup }
        } content: {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: removing ? "icloud.slash" : "icloud",
                         foreground: removing ? Theme.warning : Theme.accentSoft,
                         background: (removing ? Theme.warning : Theme.accent).opacity(0.16))
                VStack(alignment: .leading, spacing: 6) {
                    Text(PlanWords.what(model.config))
                        .font(.system(size: 14, weight: .medium))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PlanWords.when(model.schedule, hour: model.scheduleHour))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    /// Where the photos are, and a way to open the folder.
    private var folderCard: some View {
        HomeCard(title: "Your photos") {
            if model.directory != nil {
                CardLink(title: "Open Folder") { model.openDirectory() }
            }
        } content: {
            HStack(alignment: .top, spacing: 14) {
                IconTile(systemName: "folder.fill", foreground: Theme.accentSoft, background: Theme.accent.opacity(0.18))
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.directory?.lastPathComponent ?? "No folder yet")
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    Text(folderLine)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.directory == nil {
                        Button("Choose a Folder…") { model.chooseDirectory() }
                            .buttonStyle(PillButtonStyle(height: 30))
                            .padding(.top, 2)
                    }
                }
            }
        }
    }

    private var folderLine: String {
        guard model.directory != nil else { return "Pick where your photos should go." }
        var parts: [String] = []
        if let items = model.lastRunItems, items > 0 { parts.append("\(items.formatted()) photos and videos") }
        if let glance = model.glance { parts.append(AppSidebar.size(glance.bytes)) }
        return parts.isEmpty ? "On this Mac" : parts.joined(separator: " · ")
    }
}

// MARK: Pieces

/// The newest photos in a wall of tiles, one large one first. Colour placeholders until there are photos.
struct PhotoWall: View {
    typealias Slot = (x: Int, y: Int, w: Int, h: Int)

    /// How the tiles are laid out: wide for the home page, tall for the sign-in screens.
    enum Layout {
        case wide, tall

        var columns: Int { self == .wide ? 6 : 4 }
        var rows: Int { self == .wide ? 3 : 5 }

        /// Column, row and span of each tile.
        var slots: [Slot] {
            switch self {
            case .wide:
                return [(0, 0, 2, 2), (2, 0, 1, 1), (3, 0, 1, 1), (4, 0, 2, 1),
                        (2, 1, 1, 1), (3, 1, 1, 1), (4, 1, 1, 1), (5, 1, 1, 1),
                        (0, 2, 1, 1), (1, 2, 1, 1), (2, 2, 1, 1), (3, 2, 1, 1), (4, 2, 1, 1), (5, 2, 1, 1)]
            case .tall:
                return [(0, 0, 2, 2), (2, 0, 1, 1), (3, 0, 1, 1), (2, 1, 2, 1),
                        (0, 2, 1, 2), (1, 2, 1, 1), (2, 2, 2, 1), (1, 3, 1, 1), (2, 3, 1, 1), (3, 3, 1, 1),
                        (0, 4, 2, 1), (2, 4, 1, 1), (3, 4, 1, 1)]
            }
        }
    }

    /// The most tiles any layout has: how many photos the folder scan keeps.
    static let mostTiles = max(Layout.wide.slots.count, Layout.tall.slots.count)

    let photos: [NSImage]
    var layout: Layout = .wide

    private static let tones: [(Color, Color)] = [
        (Color(red: 0.17, green: 0.29, blue: 0.42), Color(red: 0.91, green: 0.72, blue: 0.52)),
        (Color(red: 0.78, green: 0.81, blue: 0.85), Color(red: 0.43, green: 0.49, blue: 0.57)),
        (Color(red: 0.62, green: 0.82, blue: 0.76), Color(red: 0.14, green: 0.21, blue: 0.19)),
        (Color(red: 0.23, green: 0.16, blue: 0.25), Color(red: 0.95, green: 0.63, blue: 0.47)),
        (Color(red: 0.5, green: 0.65, blue: 0.79), Color(red: 0.08, green: 0.13, blue: 0.18)),
        (Color(red: 0.12, green: 0.23, blue: 0.18), Color(red: 0.73, green: 0.76, blue: 0.54)),
        (Color(red: 0.35, green: 0.27, blue: 0.2), Color(red: 0.89, green: 0.8, blue: 0.64)),
        (Color(red: 0.78, green: 0.75, blue: 0.82), Color(red: 0.16, green: 0.16, blue: 0.2)),
    ]

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 4
            let slots = layout.slots
            let column = (geo.size.width - gap * CGFloat(layout.columns + 1)) / CGFloat(layout.columns)
            let row = (geo.size.height - gap * CGFloat(layout.rows + 1)) / CGFloat(layout.rows)
            ZStack(alignment: .topLeading) {
                ForEach(slots.indices, id: \.self) { index in
                    let slot = slots[index]
                    tile(index)
                        .frame(width: column * CGFloat(slot.w) + gap * CGFloat(slot.w - 1),
                               height: row * CGFloat(slot.h) + gap * CGFloat(slot.h - 1))
                        .clipShape(.rect(cornerRadius: 10, style: .continuous))
                        .offset(x: gap + CGFloat(slot.x) * (column + gap), y: gap + CGFloat(slot.y) * (row + gap))
                }
            }
        }
        .background(Color(white: 0.07))
        .accessibilityHidden(true)
    }

    @ViewBuilder private func tile(_ index: Int) -> some View {
        if photos.isEmpty {
            let tone = Self.tones[index % Self.tones.count]
            LinearGradient(colors: [tone.0, tone.1], startPoint: .top, endPoint: .bottom)
        } else {
            Image(nsImage: photos[index % photos.count])
                .resizable()
                .scaledToFill()
        }
    }
}

/// A coloured dot and a few words: how the library stands.
struct StatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .background(Circle().fill(color.opacity(0.22)).padding(-4))
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(color)
        .padding(.leading, 4)
    }
}

/// The big capsule buttons on the photo wall: a bright primary one and a smoky secondary one.
struct HeroButtonStyle: ButtonStyle {
    var isPrimary = true
    var height: CGFloat = 46

    func makeBody(configuration: Configuration) -> some View {
        HeroCapsule(isPrimary: isPrimary, height: height, configuration: configuration)
    }

    private struct HeroCapsule: View {
        let isPrimary: Bool
        let height: CGFloat
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: isPrimary ? .semibold : .medium))
                .foregroundStyle(isPrimary ? (isEnabled ? Color(white: 0.05) : Color.white.opacity(0.4)) : Color.white)
                .padding(.horizontal, isPrimary ? 22 : 20)
                .frame(height: height)
                .background(isPrimary ? AnyShapeStyle(isEnabled ? Color(white: 0.96) : Color.white.opacity(0.1)) : AnyShapeStyle(.ultraThinMaterial), in: .capsule)
                .overlay(Capsule().strokeBorder(Color.white.opacity(isPrimary ? 0 : 0.16)))
                .shadow(color: .black.opacity(isPrimary && isEnabled ? 0.35 : 0), radius: 15, y: 10)
                // A disabled primary button is drawn as a dim outline of itself; a secondary one fades.
                .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : (isPrimary ? 1 : 0.45))
                .contentShape(.capsule)
        }
    }
}

/// One of the three setup cards under the photo wall.
struct HomeCard<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SectionHeader(title: title).padding(.horizontal, -4)
                Spacer(minLength: 4)
                accessory
            }
            .frame(height: 18)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
    }
}

/// A small accent-coloured text button in a card's header.
struct CardLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accentSoft)
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
    }
}

/// A symbol on a rounded square, at the start of a card.
struct IconTile: View {
    let systemName: String
    let foreground: Color
    let background: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17))
            .foregroundStyle(foreground)
            .frame(width: 40, height: 40)
            .background(background, in: .rect(cornerRadius: 11, style: .continuous))
    }
}

/// A capsule that is on or off, for the Include card when it runs along the bottom.
struct IncludeChip: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: 10, weight: .bold))
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isOn ? Color.white : Theme.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(isOn ? Theme.accent.opacity(0.24) : Color.white.opacity(0.04), in: .capsule)
            .overlay(Capsule().strokeBorder(isOn ? Theme.accent.opacity(0.7) : Color.white.opacity(0.12)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
// MARK: First launch

/// Home before the easy setup has been answered: what the app is for, and Get Started.
struct WelcomeStage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                PhotoWall(photos: model.glance?.photos ?? [])
                LinearGradient(stops: [.init(color: Theme.background.opacity(0.25), location: 0),
                                       .init(color: Theme.background.opacity(0.45), location: 0.4),
                                       .init(color: Theme.background.opacity(0.9), location: 0.75),
                                       .init(color: Theme.background.opacity(0.98), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 14) {
                    Label("iCloud storage almost full?", systemImage: "icloud")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.66, green: 0.8, blue: 1))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Theme.accent.opacity(0.2), in: .capsule)
                        .overlay(Capsule().strokeBorder(Theme.accentSoft.opacity(0.35)))
                    Text("Free up iCloud,\nkeep every photo.")
                        .font(.system(size: 44, weight: .bold))
                        .tracking(-1.5)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Move your photos to this Mac in full quality, then clear them from iCloud. Three quick questions and the download starts.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(white: 0.78))
                        .lineSpacing(3)
                        .frame(maxWidth: 540, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 18) {
                        Button { model.page = .setup } label: {
                            HStack(spacing: 8) {
                                Text("Get Started")
                                Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .buttonStyle(HeroButtonStyle(height: 50))
                        .keyboardShortcut(.defaultAction)
                        Button("Set it up myself in Settings") {
                            // Choosing Settings over the questions: Home goes back to normal.
                            model.hasOnboarded = true
                            model.page = .settings
                        }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accentSoft)
                    }
                    .padding(.top, 6)
                }
                .padding(36)
            }
            .frame(minHeight: 320, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.06)))

            HStack(alignment: .top, spacing: 10) {
                HowItWorks(number: 1, title: "Download", text: "Originals, from the dates you pick, into a folder on this Mac.")
                HowItWorks(number: 2, title: "Check", text: "Each photo is removed from iCloud only once its file is safely here.")
                HowItWorks(number: 3, title: "Free up space", text: "They go to Recently Deleted, which Apple keeps for 30 days.")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One of the three steps under the first-launch photo wall.
struct HowItWorks: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.accentSoft)
                .frame(width: 28, height: 28)
                .background(Theme.accent.opacity(0.2), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(text)
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .panel(cornerRadius: 18, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
        .accessibilityElement(children: .combine)
    }
}
#endif
