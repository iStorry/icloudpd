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
        let volume = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return LibraryGlance(bytes: bytes,
                             volumeCapacity: volume?.volumeTotalCapacity.map(Int64.init),
                             volumeAvailable: volume?.volumeAvailableCapacityForImportantUsage,
                             photos: photos)
    }

    private static func thumbnail(of url: URL) -> NSImage? {
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

/// The main window's sidebar: the app, its pages, the folder's size and the account.
struct AppSidebar: View {
    @EnvironmentObject var model: AppModel

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
                item("Home", "house", .library)
                item("Activity", "waveform.path.ecg", .activity, busy: model.isDownloading)
                item("Setup", "checklist", .setup)
                item("Settings", "slider.horizontal.3", .settings)
            }

            if model.directory != nil { storage }

            Spacer(minLength: 0)
            account
        }
        .padding(14)
        // Clear the traffic lights, which sit over the top of the sidebar.
        .padding(.top, 26)
        .frame(width: 264)
        .frame(maxHeight: .infinity, alignment: .top)
        .panel(cornerRadius: 20, fill: Color.white.opacity(0.035), stroke: Color.white.opacity(0.07))
    }

    private func item(_ title: String, _ symbol: String, _ page: AppModel.Page, busy: Bool = false) -> some View {
        let isOn = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 13, weight: isOn ? .medium : .regular))
            .foregroundStyle(isOn ? Color.primary : Color(white: 0.66))
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(isOn ? Color.white.opacity(0.08) : Color.clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "On this Mac").padding(.horizontal, -4)
            if let glance = model.glance {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.size(glance.bytes))
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.5)
                    Spacer(minLength: 4)
                    if let capacity = glance.volumeCapacity {
                        Text("of \(Self.size(capacity))").foregroundStyle(Theme.secondary)
                    }
                }
                if let capacity = glance.volumeCapacity, let free = glance.volumeAvailable, capacity > 0 {
                    let library = Double(glance.bytes) / Double(capacity)
                    let other = Double(max(0, capacity - free - glance.bytes)) / Double(capacity)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Rectangle().fill(Theme.accent).frame(width: max(3, geo.size.width * library))
                            Rectangle().fill(Color.white.opacity(0.26)).frame(width: geo.size.width * other)
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(height: 6)
                    .background(Color.white.opacity(0.08))
                    .clipShape(.capsule)
                    .accessibilityHidden(true)
                    HStack(spacing: 12) {
                        legend("Photos", Theme.accent)
                        legend("Other", Color.white.opacity(0.26))
                        Spacer(minLength: 4)
                        Text("\(Self.size(free)) free").fixedSize()
                    }
                    .lineLimit(1)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Measuring the folder…")
                }
                .foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 10)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }

    /// "412 GB", "1.2 TB", "8.5 GB": short enough for the narrow sidebar.
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
    @Binding var showingAlbums: Bool
    /// Room for the three cards side by side; narrower windows put Include on a row of its own.
    @State private var isWide = true

    var body: some View {
        VStack(spacing: 12) {
            hero.frame(minHeight: 280, maxHeight: .infinity)
            if let notice = model.notice {
                ErrorBanner(message: notice)
            }
            if !model.config.dryRun && model.config.deletesFromICloud {
                Label("This setup deletes photos from iCloud after downloading them. Change it in Settings > Sync.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(cornerRadius: 14, fill: Theme.warning.opacity(0.08), stroke: Theme.warning.opacity(0.35))
            }
            cards
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { isWide = $0 }
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
                Button { model.startDownload(dryRun: true) } label: {
                    Label("Dry Run", systemImage: "eye")
                }
                .buttonStyle(HeroButtonStyle(isPrimary: false))
                .help("See what would be downloaded, moved or deleted, without changing anything")
                Button { model.startDownload() } label: {
                    Label(model.config.albums.isEmpty ? "Sync Now" : "Sync Albums", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(HeroButtonStyle())
                .keyboardShortcut(.defaultAction)
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

    private var cards: some View {
        Group {
            if isWide {
                HStack(alignment: .top, spacing: 12) {
                    saveCard
                    fromCard
                    includeCard
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        saveCard
                        fromCard
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    includeChips
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .disabled(model.isDownloading)
        .opacity(model.isDownloading ? 0.5 : 1)
    }

    private var saveCard: some View {
        HomeCard(title: "Save to") {
            if model.directory != nil {
                CardLink(title: "Show") { model.openDirectory() }
            }
            CardLink(title: "Change") { model.chooseDirectory() }
        } content: {
            HStack(spacing: 12) {
                IconTile(systemName: "folder.fill", foreground: Theme.accentSoft, background: Theme.accent.opacity(0.18))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.directory?.lastPathComponent ?? "No folder chosen")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.directory.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose where photos go")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .truncationMode(.middle)
                }
                .lineLimit(1)
            }
            CardDivider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Folders").foregroundStyle(Color(white: 0.66))
                    Spacer(minLength: 8)
                    folderPicker
                }
                folderPicker
            }
        }
    }

    private var folderPicker: some View {
        Picker("Folders", selection: $model.config.folderStructure) {
            ForEach(FolderStructure.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            if FolderStructure(rawValue: model.config.folderStructure) == nil {
                Text("Custom").tag(model.config.folderStructure)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .tint(.white)
        .fixedSize()
    }

    private var fromCard: some View {
        HomeCard(title: "From") {
            CardLink(title: "Choose") { showingAlbums = true }
                .disabled(model.phase != .signedIn)
        } content: {
            HStack(spacing: 12) {
                IconTile(systemName: "icloud", foreground: Color(white: 0.9), background: Color.white.opacity(0.07))
                VStack(alignment: .leading, spacing: 2) {
                    Text(albumSummary)
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.libraryLabel(currentLibrary))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
            }
            CardDivider()
            if model.libraries.count > 1 {
                HStack {
                    Text("Library").foregroundStyle(Color(white: 0.66))
                    Spacer(minLength: 8)
                    Picker("Library", selection: libraryBinding) {
                        ForEach(model.libraries, id: \.self) { Text(model.libraryLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(.white)
                    .fixedSize()
                }
            }
            HStack {
                Text("After download").foregroundStyle(Color(white: 0.66))
                Spacer(minLength: 8)
                Text(model.config.deletesFromICloud ? "Delete in iCloud" : "Keep in iCloud")
            }
            .lineLimit(1)
        }
    }

    private var includeCard: some View {
        HomeCard(title: "Include") {
            EmptyView()
        } content: {
            VStack(spacing: 6) {
                IncludeRow(title: "Photos", isOn: inverted(\.skipPhotos))
                IncludeRow(title: "Videos", isOn: inverted(\.skipVideos))
                IncludeRow(title: "Live Photo videos", isOn: inverted(\.skipLivePhotos))
                IncludeRow(title: "Screenshots", isOn: inverted(\.skipScreenshots))
            }
        }
    }

    private var includeChips: some View {
        HomeCard(title: "Include") {
            EmptyView()
        } content: {
            HStack(spacing: 8) {
                IncludeChip(title: "Photos", isOn: inverted(\.skipPhotos))
                IncludeChip(title: "Videos", isOn: inverted(\.skipVideos))
                IncludeChip(title: "Live Photo videos", isOn: inverted(\.skipLivePhotos))
                IncludeChip(title: "Screenshots", isOn: inverted(\.skipScreenshots))
            }
        }
    }

    private var currentLibrary: String { model.config.library ?? model.libraries.first ?? "PrimarySync" }

    private var albumSummary: String {
        switch model.config.albums.count {
        case 0: return "All Photos"
        case 1: return model.config.albums[0]
        default: return "\(model.config.albums.count) albums"
        }
    }

    private var libraryBinding: Binding<String> {
        Binding(get: { currentLibrary },
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

/// A label and a small switch, for the Include card.
struct IncludeRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 24)
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
#endif
