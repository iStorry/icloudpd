import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SyncLogLevel: Int, Sendable, Comparable {
    case debug, info, warning, error
    public static func < (a: SyncLogLevel, b: SyncLogLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum SyncEvent: Sendable {
    case log(SyncLogLevel, String)
    /// An album (or the whole library, title "All Photos") is being listed.
    case albumStarted(title: String, total: Int?)
    /// Assets looked at so far in the current album.
    case progress(processed: Int)
    case downloaded(path: String, bytes: Int)
    /// Dry run: this file would be downloaded.
    case wouldDownload(path: String)
    case alreadyExists(path: String)
    case failed(name: String, message: String)
    case deletedLocally(path: String)
    case deletedFromICloud(name: String)
    case pruned(path: String)
}

public struct SyncSummary: Equatable, Sendable {
    public var assetsSeen = 0
    public var assetsFiltered = 0
    public var filesDownloaded = 0
    public var filesExisting = 0
    public var filesFailed = 0
    public var bytesDownloaded = 0
    public var deletedLocally = 0
    public var deletedFromICloud = 0
    public var pruned = 0
    public var stoppedByUntilFound = false
    /// iCloud kept answering 503 to deletes, so the run stopped deleting and only downloaded.
    public var deletesPausedByThrottling = false
    public init() {}
}

/// What happened to one asset (icloudpd's DownloadResult).
struct AssetResult {
    var downloaded = false
    /// Every requested file is on disk now (needed before deleting from iCloud).
    var present = true
    /// All its files were already there (counts towards --until-found).
    var foundExisting = false
    var foundMissing = false
    var createdPaths: [String] = []
    var expectedPaths: [String] = []
    var bytes = 0
    var failures = 0
}

/// The download run: a port of icloudpd's core_single_run / download_builder / autodelete,
/// with parallel and resumable downloads.
public final class SyncEngine: @unchecked Sendable {
    public let configuration: SyncConfiguration
    let emit: @Sendable (SyncEvent) -> Void
    let timeZone: TimeZone
    let folderFormat: FolderFormat
    let fileManager = FileManager.default
    private let reservations = PathReservations()
    private let folders = FolderSizes()
    // Worked out once for the run rather than for every photo.
    private let calendar: Calendar
    private let excluded: [NSRegularExpression]
    private let rootPaths: [String]
    var reservationsForTests: PathReservations { reservations }

    public init(configuration: SyncConfiguration, timeZone: TimeZone = .current,
                events: @escaping @Sendable (SyncEvent) -> Void) throws {
        try configuration.validate()
        self.configuration = configuration
        self.timeZone = timeZone
        self.folderFormat = try FolderFormat(configuration.folderStructure)
        self.calendar = Strftime.calendar(timeZone)
        self.excluded = configuration.excludeFilenames.compactMap(FilenamePolicy.globExpression)
        self.rootPaths = [configuration.directory, configuration.livePhotoDirectory].compactMap { $0?.standardizedFileURL.path }
        self.emit = events
    }

    var dryRun: Bool { configuration.dryRun }

    func log(_ level: SyncLogLevel, _ message: String) { emit(.log(level, message)) }

    // MARK: Filters

    /// icloudpd's where_builder: true when the asset should be processed.
    public func passes(_ asset: PhotoAsset, now: Date = Date()) -> Bool {
        let c = configuration
        let isMovie = asset.itemType == .movie
        if c.skipVideos && isMovie { return false }
        if c.skipPhotos && asset.itemType == .image { return false }
        if c.skipScreenshots && asset.isScreenshot { return false }
        if let before = c.skipCreatedBefore, asset.createdDate < before.resolve(now: now) { return false }
        if let after = c.skipCreatedAfter, asset.createdDate > after.resolve(now: now) { return false }
        if !excluded.isEmpty {
            let name = baseFilename(asset)
            let whole = NSRange(name.startIndex..., in: name)
            if excluded.contains(where: { $0.firstMatch(in: name, range: whole) != nil }) { return false }
        }
        return true
    }

    // MARK: Paths

    func baseFilename(_ asset: PhotoAsset) -> String {
        FilenamePolicy.baseFilename(for: asset, policy: configuration.fileMatchPolicy,
                                    keepUnicode: configuration.keepUnicodeInFilenames)
    }

    func datePath(_ asset: PhotoAsset) -> [String] {
        folderFormat.components(for: asset.createdDate, calendar: calendar)
    }

    func url(in root: URL, _ components: [String], _ filename: String) -> URL {
        var url = root
        for c in components { url.appendPathComponent(c, isDirectory: true) }
        return url.appendingPathComponent(filename)
    }

    func relative(_ url: URL) -> String {
        let full = url.standardizedFileURL.path
        for base in rootPaths where full.hasPrefix(base + "/") {
            return String(full.dropFirst(base.count + 1))
        }
        return url.path
    }

    func fileSize(_ url: URL) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// One file to fetch for an asset.
    public struct PlannedFile: Equatable {
        public let version: AssetVersion
        public let size: VersionSize
        public let url: URL
        public let isLivePhotoVideo: Bool
    }

    /// The files icloudpd would write for this asset, before looking at the disk.
    /// Sizes that don't exist fall back to the original unless `forceSize` is on.
    public func plan(_ asset: PhotoAsset) -> (files: [PlannedFile], missingSizes: [String]) {
        let c = configuration
        let isImage = (asset.itemType ?? .image) == .image
        let base = baseFilename(asset)
        let folders = datePath(asset)
        let allVersions = asset.versions(rawPolicy: c.alignRaw)
        let sizes = c.requestedSizes(isImage: isImage)
        let (versions, overrides) = FilenamePolicy.disambiguate(versions: allVersions, sizes: sizes, base: base,
                                                                 isImage: isImage, livePolicy: c.livePhotoMovFilenamePolicy)
        var files: [PlannedFile] = []
        var missing: [String] = []
        var seen = Set<VersionSize>()
        for requested in sizes {
            var size = requested
            if versions[size] == nil && size != .original {
                if c.forceSize { missing.append(requested.rawValue); continue }
                if sizes.contains(.original) { continue }
                size = .original
            }
            guard let version = versions[size] else { missing.append(size.rawValue); continue }
            if seen.contains(size) { continue }
            seen.insert(size)
            let name = overrides[size] ?? FilenamePolicy.versionFilename(base: base, version: version, size: size,
                                                                         isImage: isImage, livePolicy: c.livePhotoMovFilenamePolicy)
            files.append(PlannedFile(version: version, size: size, url: url(in: c.directory, folders, name), isLivePhotoVideo: false))
        }
        if !c.skipLivePhotos && !c.xmpSidecarOnly, isImage, let live = allVersions[c.livePhotoSize.versionSize] {
            var name = FilenamePolicy.versionFilename(base: base, version: live, size: c.livePhotoSize.versionSize,
                                                      isImage: true, livePolicy: c.livePhotoMovFilenamePolicy)
            if c.livePhotoSize != .original { name = FilenamePolicy.addSuffix("-\(c.livePhotoSize.rawValue)", to: name) }
            let root = c.livePhotoDirectory ?? c.directory
            files.append(PlannedFile(version: live, size: c.livePhotoSize.versionSize,
                                     url: url(in: root, folders, name), isLivePhotoVideo: true))
        }
        return (files, missing)
    }

    /// Where a planned file goes, or nil when it's already on disk. A different file with the
    /// same name gets "-<size>" (name-size-dedup-with-suffix). Paths claimed by downloads running
    /// at the same time count as taken, so two photos with one name don't race for it.
    func resolve(_ file: PlannedFile, asset: PhotoAsset) -> (url: URL?, existing: URL?) {
        let c = configuration
        // Disk work stays outside the lock every download shares: the folder is read once for the
        // run, and a JPEG is only opened (to tell whether its date was written here) between tries.
        folders.load(file.url.deletingLastPathComponent(), fileManager: fileManager)
        var ownDate: [String: Bool] = [:]
        while true {
            var unknown: (url: URL, size: Int)?
            let outcome: (url: URL?, existing: URL?)? = reservations.withLock { reserved in
                func size(_ url: URL) -> Int? { reserved[url.path] ?? folders.size(of: url) ?? fileSize(url) }
                var target = file.url
                var existing = size(target)
                var legacy: URL?
                if existing == nil, file.size == .original {
                    // Older icloudpd versions wrote IMG_1234-original.jpg
                    let old = target.deletingLastPathComponent()
                        .appendingPathComponent(FilenamePolicy.addSuffix("-original", to: target.lastPathComponent))
                    if let s = size(old) { existing = s; legacy = old }
                }
                if let local = existing, c.fileMatchPolicy == .nameSizeDedupWithSuffix, !c.xmpSidecarOnly,
                   local != file.version.size {
                    var isOwn = false
                    if c.setExifDatetime {
                        let candidate = legacy ?? target
                        guard let known = ownDate[candidate.path] else {
                            unknown = (candidate, local)
                            return nil
                        }
                        isOwn = known
                    }
                    if !isOwn {
                        target = target.deletingLastPathComponent()
                            .appendingPathComponent(FilenamePolicy.dedupName(target.lastPathComponent, size: file.version.size))
                        legacy = nil
                        existing = size(target)
                    }
                }
                if existing != nil { return (nil, legacy ?? target) }
                reserved[target.path] = file.version.size
                return (target, nil)
            }
            if let outcome { return outcome }
            if let unknown {
                ownDate[unknown.url.path] = ExifDate.hasOwnDate(unknown.url, date: asset.createdDate,
                                                                localSize: unknown.size, iCloudSize: file.version.size)
            }
        }
    }

    // MARK: Downloading one asset

    func process(_ asset: PhotoAsset, http: HTTPClient) async throws -> AssetResult {
        var result = AssetResult()
        let c = configuration
        let (files, missing) = plan(asset)
        for size in missing {
            log(.error, "\(size) size does not exist for \(baseFilename(asset)). Skipping...")
            result.present = false
        }
        for file in files {
            try Task.checkCancellation()
            let (target, existing) = resolve(file, asset: asset)
            let finalURL: URL
            if let existing {
                if !file.isLivePhotoVideo { result.foundExisting = true }
                result.expectedPaths.append(relative(existing))
                emit(.alreadyExists(path: relative(existing)))
                finalURL = existing
            } else if let target {
                if !file.isLivePhotoVideo { result.foundMissing = true }
                if c.xmpSidecarOnly {
                    result.present = false
                    reservations.release(target)
                } else if dryRun {
                    emit(.wouldDownload(path: relative(target)))
                    reservations.release(target)
                    result.present = false
                } else {
                    do {
                        try await download(file, to: target, http: http, created: asset.createdDate)
                        reservations.release(target)
                        if c.setExifDatetime, !file.isLivePhotoVideo, ExifDate.isJPEG(target) {
                            if ExifDate.setIfMissing(target, date: asset.createdDate) {
                                setDates(target, asset.createdDate)
                            }
                        }
                        result.downloaded = true
                        result.bytes += file.version.size
                        result.createdPaths.append(relative(target))
                        result.expectedPaths.append(relative(target))
                        emit(.downloaded(path: relative(target), bytes: file.version.size))
                    } catch {
                        reservations.release(target)
                        if error is CancellationError { throw error }
                        if SyncEngine.isFatal(error) { throw error }
                        result.present = false
                        result.failures += 1
                        emit(.failed(name: relative(target), message: error.localizedDescription))
                    }
                }
                finalURL = target
            } else {
                continue
            }

            if c.xmpSidecar || c.xmpSidecarOnly, !file.isLivePhotoVideo {
                let sidecar = URL(fileURLWithPath: finalURL.path + ".xmp")
                result.expectedPaths.append(relative(sidecar))
                if !dryRun {
                    let existed = fileManager.fileExists(atPath: sidecar.path)
                    do {
                        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if try XMPSidecar.write(for: asset, mediaURL: finalURL, forAdjusted: file.size == .adjusted), !existed {
                            result.createdPaths.append(relative(sidecar))
                        }
                    } catch {
                        log(.warning, "Could not write XMP sidecar \(relative(sidecar)): \(error.localizedDescription)")
                    }
                }
            }
        }
        if !c.skipLivePhotos && !c.xmpSidecarOnly && asset.itemType == .image,
           !files.contains(where: \.isLivePhotoVideo),
           [VersionSize.liveOriginal, .liveMedium, .liveThumb].contains(where: { asset.versions[$0] != nil }) {
            result.present = false // a Live Photo without the requested video size
        }
        return result
    }

    static func isFatal(_ error: Error) -> Bool {
        if case ICloudError.http(let status, _) = error, [401, 403, 421, 450].contains(status) { return true }
        if case ICloudError.server(let code, _) = error, code == "ACCESS_DENIED" { return true }
        return false
    }

    func setDates(_ url: URL, _ date: Date) {
        try? fileManager.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
    }

    /// Downloads into "<name><temp suffix>" (continuing it when an earlier run left one), checks
    /// the size, then moves it into place, so an interrupted run never leaves a half photo under its real name.
    func download(_ file: PlannedFile, to destination: URL, http: HTTPClient, created: Date, attempts: Int = 4) async throws {
        let part = URL(fileURLWithPath: destination.path + configuration.temporarySuffix)
        var lastError: Error = ICloudError.unexpectedResponse("download")
        for attempt in 1...attempts {
            do {
                let status = try await http.downloadFile(file.version.url, to: part)
                if status == 416 {
                    // The partial file is complete or stale. Keep it if the size is right, otherwise start over.
                    if fileSize(part) != file.version.size {
                        try? fileManager.removeItem(at: part)
                        throw ICloudError.http(status: 416, message: "Restarting the download.")
                    }
                } else if !(200..<300).contains(status) {
                    throw ICloudError.http(status: status, message: "Download failed.")
                }
                let got = fileSize(part) ?? 0
                if file.version.size > 0 && got != file.version.size {
                    if got > file.version.size { try? fileManager.removeItem(at: part) }
                    throw ICloudError.unexpectedResponse("got \(got) of \(file.version.size) bytes")
                }
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: part, to: destination)
                setDates(destination, created)
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                lastError = error
                if SyncEngine.isFatal(error) { throw error }
                if attempt < attempts {
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                }
            }
        }
        throw lastError
    }

    // MARK: The run

    public func run(photos: PhotosService) async throws -> SyncSummary {
        let c = configuration
        var summary = SyncSummary()
        let library = try await photos.library(named: c.library)
        await library.recheckIndexing()
        if library.indexingStateIgnored {
            log(.warning, "Library \(library.name) is still reported as indexing; continuing, the listing may be incomplete.")
        }
        let albums: [PhotoAlbum]
        if c.albums.isEmpty {
            albums = [library.all]
        } else {
            let available = try await library.albums()
            albums = try c.albums.map { name in
                guard let album = available.first(where: { $0.name == name }) else { throw ICloudError.unknownAlbum(name) }
                return album
            }
        }
        if !dryRun { try fileManager.createDirectory(at: c.directory, withIntermediateDirectories: true) }

        var prune = c.pruneOrphans ? PruneTracker(directory: c.directory, library: library.name, fileManager: fileManager) : nil
        var pruneComplete = prune != nil && c.albums.isEmpty && c.recent == nil && c.untilFound == nil && !library.indexingStateIgnored

        let now = Date()
        /// Set once iCloud keeps answering 503 to deletes: the rest of the run only downloads.
        var deletesPaused = false
        for album in albums {
            try Task.checkCancellation()
            let total = try? await album.count()
            let limit = c.recent.map { min($0, total ?? $0) }
            emit(.albumStarted(title: album.title, total: limit ?? total))
            log(.info, "Looking up \(c.skipVideos ? "photos" : c.skipPhotos ? "videos" : "photos and videos")\(album.name.isEmpty ? "" : " from album \(album.name)")...")

            let pager = album.pager()
            /// Assets whose results have been handled; also the listing position of the next one to handle.
            var listed = 0
            var consecutiveFound = 0
            var stop = false
            let parallel = c.untilFound == nil ? max(1, c.concurrentDownloads) : 1
            // Deleting from iCloud moves every later asset up one place, so the next page can only
            // be asked for once this page's deletions are done. Until-found mostly stops within a
            // page, so it doesn't ask for one it won't use. Otherwise the next page is listed ahead.
            let listsAhead = c.untilFound == nil && (dryRun || !c.deletesFromICloud)

            // Downloads run in a window that slides over the listing: a slot freed by one asset
            // goes to the next one, also across pages, and the next page is listed meanwhile.
            // Results are still handled in listing order.
            try await withThrowingTaskGroup(of: SyncStep.self) { group in
                var slots: [Int: AssetSlot] = [:]
                var enqueued = 0
                var nextToStart = 0
                var downloading = 0
                var listing = false
                var listingDone = false
                /// Downloaded and due to leave iCloud; sent together once their page is handled.
                var toDelete: [PhotoAsset] = []

                while true {
                    try Task.checkCancellation()

                    let handledBefore = listed
                    while listed < enqueued {
                        if let n = c.untilFound, consecutiveFound >= n {
                            log(.info, "Found \(n) consecutive previously downloaded photos. Exiting")
                            summary.stoppedByUntilFound = true
                            stop = true
                            break
                        }
                        guard let slot = slots[listed], !slot.passed || slot.result != nil else { break }
                        slots[listed] = nil
                        listed += 1
                        summary.assetsSeen += 1
                        let result = slot.result
                        if let result {
                            summary.filesDownloaded += result.createdPaths.filter { !$0.hasSuffix(".xmp") }.count
                            summary.bytesDownloaded += result.bytes
                            summary.filesFailed += result.failures
                            summary.filesExisting += result.foundExisting ? 1 : 0
                            if result.foundMissing { consecutiveFound = 0 }
                            else if result.foundExisting { consecutiveFound += 1 }
                            if prune != nil, !result.present { pruneComplete = false }
                        } else {
                            summary.assetsFiltered += 1
                        }
                        prune?.record(assetID: slot.asset.id, paths: result?.expectedPaths ?? [])

                        if shouldDeleteFromICloud(slot.asset, passed: slot.passed, result: result, now: now) {
                            if dryRun {
                                let label = baseFilename(slot.asset)
                                log(.info, "[DRY RUN] Would delete \(label) in iCloud library \(library.name)")
                                emit(.deletedFromICloud(name: label))
                                summary.deletedFromICloud += 1
                            } else if !deletesPaused {
                                toDelete.append(slot.asset)
                            }
                        }
                    }
                    if listed != handledBefore { emit(.progress(processed: listed)) }
                    // The next page is only listed when nothing is waiting, so the deletions are
                    // done, and the listing position moved back, before it is asked for.
                    if !toDelete.isEmpty, stop || listed == enqueued {
                        let (deleted, throttled) = try await deleteFromICloud(toDelete, library: library)
                        summary.deletedFromICloud += deleted
                        pager.adjustOffset(by: -deleted)
                        toDelete = []
                        if throttled && !deletesPaused {
                            deletesPaused = true
                            summary.deletesPausedByThrottling = true
                            log(.warning, "iCloud keeps refusing to delete (HTTP 503), so this run stops removing photos from iCloud and only downloads. "
                                + "The photos it didn't remove stay in iCloud; the next run removes them.")
                        }
                    }
                    if stop {
                        group.cancelAll()
                        break
                    }

                    while downloading < parallel, nextToStart < enqueued {
                        let index = nextToStart
                        nextToStart += 1
                        guard let slot = slots[index], slot.passed else { continue }
                        let asset = slot.asset
                        downloading += 1
                        group.addTask { .asset(index, try await self.process(asset, http: photos.http)) }
                    }

                    if let limit, enqueued >= limit { listingDone = true }
                    // Ahead, but only just: a page is asked for when the downloads are about to run
                    // out of assets, so its download links are as fresh as when pages came one by one.
                    let roomForPage = listsAhead
                        ? enqueued - nextToStart < parallel && enqueued - listed < SyncEngine.listingWindow
                        : enqueued == listed
                    if !listing, !listingDone, roomForPage {
                        listing = true
                        group.addTask { .page(try await pager.nextPage()) }
                    }

                    guard let step = try await group.next() else { break }
                    switch step {
                    case .asset(let index, let result):
                        downloading -= 1
                        slots[index]?.result = result
                    case .page(let page):
                        listing = false
                        guard var batch = page else { listingDone = true; break }
                        if let limit { batch = Array(batch.prefix(max(0, limit - enqueued))) }
                        for asset in batch {
                            slots[enqueued] = AssetSlot(asset: asset, passed: passes(asset, now: now))
                            enqueued += 1
                        }
                    }
                }
            }
            if let limit, listed >= limit { stop = true }
            if !stop, let total, listed < total, prune != nil { pruneComplete = false }
        }

        if c.autoDelete {
            summary.deletedLocally += try await autoDelete(library: library)
        }
        if var tracker = prune {
            if pruneComplete && summary.filesFailed == 0 {
                summary.pruned += tracker.pruneOrphans(dryRun: dryRun) { [emit] path in emit(.pruned(path: path)) }
            } else {
                log(.warning, "Skipping orphan pruning: the listing wasn't complete (albums, recent, until-found, or failed downloads).")
            }
            if !dryRun { tracker.save() }
            prune = tracker
        }
        return summary
    }

    /// The delete-after-download and keep-recent-days decisions (icloudpd's should_delete).
    func shouldDeleteFromICloud(_ asset: PhotoAsset, passed: Bool, result: AssetResult?, now: Date) -> Bool {
        let c = configuration
        var label: String { baseFilename(asset) }
        var shouldDelete = (result?.downloaded ?? false) && c.deleteAfterDownload
        if passed, let keep = c.keepICloudRecentDays {
            if !asset.hasAssetDate {
                log(.warning, "Not deleting \(label) from iCloud: it has no creation date")
            } else {
                let age = Int(now.timeIntervalSince(asset.createdDate) / 86_400)
                if age < keep {
                    // still recent: keep in iCloud
                } else if c.skipLivePhotos && asset.isLivePhoto {
                    log(.debug, "Not deleting \(label) from iCloud: its Live Photo video was skipped")
                } else if result?.present == true {
                    shouldDelete = true
                } else if !dryRun {
                    log(.warning, "Not deleting \(label) from iCloud: it is not present locally")
                }
            }
        }
        return shouldDelete
    }

    /// Moves photos to Recently Deleted in iCloud, in one request when there are several.
    /// Returns how many iCloud deleted, and `throttled` when iCloud kept answering 503: the rest
    /// stay in iCloud and the run stops deleting, so it can go on downloading (#50).
    func deleteFromICloud(_ assets: [PhotoAsset], library: PhotoLibrary) async throws -> (deleted: Int, throttled: Bool) {
        var deleted = 0
        func report(_ asset: PhotoAsset) {
            let label = baseFilename(asset)
            log(.info, "Deleted \(label) in iCloud")
            emit(.deletedFromICloud(name: label))
            deleted += 1
        }
        if assets.count > 1 {
            guard let accepted = try await withThrottleBackoff({ try await library.delete(assets) }) else {
                return (deleted, true)
            }
            if accepted {
                assets.forEach(report)
                return (deleted, false)
            }
        }
        // A single photo, or iCloud turned the request down as a whole (it is all or nothing):
        // one at a time deletes the ones it does accept.
        for asset in assets {
            guard let accepted = try await withThrottleBackoff({ try await library.delete(asset) }) else {
                return (deleted, true)
            }
            if accepted {
                report(asset)
            } else {
                log(.error, "Could not delete \(baseFilename(asset)) in iCloud: iCloud asked to try again later")
            }
        }
        return (deleted, false)
    }

    /// Runs a request again, waiting longer each time, while iCloud answers 503 ("temporarily
    /// refusing to serve"). Returns nil when it still does after the last try.
    func withThrottleBackoff<T>(_ request: () async throws -> T) async throws -> T? {
        for attempt in 0...SyncEngine.throttleRetries {
            do {
                return try await request()
            } catch ICloudError.http(let status, _) where status == 503 {
                guard attempt < SyncEngine.throttleRetries else { return nil }
                log(.warning, "iCloud is limiting requests (HTTP 503); trying again in \(SyncEngine.throttleDelay * UInt64(attempt + 1) / 1_000_000_000) seconds")
                try await Task.sleep(nanoseconds: SyncEngine.throttleDelay * UInt64(attempt + 1))
            }
        }
        return nil
    }

    // MARK: Auto-delete

    /// The local paths an asset in Recently Deleted may have been saved under (autodelete.py).
    func autoDeletePaths(_ media: PhotoAsset) -> [URL] {
        let c = configuration
        let isImage = (media.itemType ?? .image) == .image
        let base = baseFilename(media)
        let folders = datePath(media)
        let versions = media.versions(rawPolicy: c.alignRaw)
        var paths: [URL] = []
        let (chosen, overrides) = FilenamePolicy.disambiguate(versions: versions, sizes: c.requestedSizes(isImage: isImage), base: base,
                                                               isImage: isImage, livePolicy: c.livePhotoMovFilenamePolicy)
        for (size, version) in chosen where size == .alternative || size == .adjusted {
            let name = overrides[size] ?? FilenamePolicy.versionFilename(base: base, version: version, size: size, isImage: isImage,
                                                                         livePolicy: c.livePhotoMovFilenamePolicy)
            paths.append(url(in: c.directory, folders, name))
        }
        for (size, version) in versions where size != .alternative && size != .adjusted {
            var name = FilenamePolicy.versionFilename(base: base, version: version, size: size, isImage: isImage,
                                                      livePolicy: c.livePhotoMovFilenamePolicy)
            if size == .liveMedium { name = FilenamePolicy.addSuffix("-medium", to: name) }
            if size == .liveThumb { name = FilenamePolicy.addSuffix("-thumb", to: name) }
            let isLive = [.liveOriginal, .liveMedium, .liveThumb].contains(size)
            paths.append(url(in: isLive ? (c.livePhotoDirectory ?? c.directory) : c.directory, folders, name))
        }
        return paths.flatMap { [$0, URL(fileURLWithPath: $0.path + ".xmp")] }
    }

    /// Deletes local files of photos that are in iCloud's Recently Deleted (`--auto-delete`).
    func autoDelete(library: PhotoLibrary) async throws -> Int {
        log(.info, "Deleting any files found in 'Recently Deleted'...")
        var deleted = 0
        for try await media in library.recentlyDeleted.photos() {
            try Task.checkCancellation()
            for path in Set(autoDeletePaths(media).map(\.path)) where fileManager.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                if dryRun {
                    log(.info, "[DRY RUN] Would delete \(relative(url))")
                } else {
                    try fileManager.removeItem(at: url)
                    log(.info, "Deleted \(relative(url))")
                }
                emit(.deletedLocally(path: relative(url)))
                deleted += 1
            }
        }
        return deleted
    }
}

/// One listed asset waiting for its turn: `result` is set once its files are done.
private struct AssetSlot {
    let asset: PhotoAsset
    /// False when a filter leaves the asset out; it is then counted without downloading.
    let passed: Bool
    var result: AssetResult?
}

/// What a task of the run's group finished: one asset's files, or the listing of the next page.
private enum SyncStep: Sendable {
    case asset(Int, AssetResult)
    case page([PhotoAsset]?)
}

extension SyncEngine {
    /// How many assets may be finished but not yet handled, behind a slow one, before listing pauses.
    static let listingWindow = 300
    /// Tries after the first when iCloud answers 503 to a delete, waiting 30, 60 then 90 seconds.
    static let throttleRetries = 3
    nonisolated(unsafe) static var throttleDelay: UInt64 = 30_000_000_000
}

/// The sizes of the files that were in each download folder when the run first looked there, read
/// with one listing per folder instead of one lookup per photo. A file that isn't in here may
/// still exist (it was downloaded since, or its name differs only in case), so a miss is checked on disk.
final class FolderSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [String: [String: Int]] = [:]

    func load(_ folder: URL, fileManager: FileManager) {
        let key = folder.path
        lock.lock()
        let known = folders[key] != nil
        lock.unlock()
        if known { return }
        var sizes: [String: Int] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        for url in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? [] {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            sizes[url.lastPathComponent] = size
        }
        lock.lock()
        if folders[key] == nil { folders[key] = sizes }
        lock.unlock()
    }

    func size(of url: URL) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return folders[url.deletingLastPathComponent().path]?[url.lastPathComponent]
    }
}

/// Paths claimed by downloads in flight, with their expected sizes.
final class PathReservations: @unchecked Sendable {
    private let lock = NSLock()
    private var reserved: [String: Int] = [:]

    func withLock<T>(_ body: (inout [String: Int]) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&reserved)
    }

    func release(_ url: URL) {
        lock.lock(); reserved.removeValue(forKey: url.path); lock.unlock()
    }
}

/// `--prune-orphans`, made reversible: remembers which files belong to which iCloud asset, and after
/// a complete listing moves the files of assets that are gone into ".icloudpd-swift-pruned/<date>/".
struct PruneTracker {
    let directory: URL
    let manifestURL: URL
    let fileManager: FileManager
    var manifest: [String: [String]]
    var seen = Set<String>()

    init(directory: URL, library: String, fileManager: FileManager) {
        self.directory = directory
        self.fileManager = fileManager
        let safe = library.replacingOccurrences(of: "/", with: "_")
        manifestURL = directory.appendingPathComponent(".icloudpd-swift", isDirectory: true)
            .appendingPathComponent("manifest-\(safe).json")
        manifest = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    mutating func record(assetID: String, paths: [String]) {
        seen.insert(assetID)
        guard !paths.isEmpty else { return }
        let existing = Set(manifest[assetID] ?? [])
        manifest[assetID] = Array(existing.union(paths)).sorted()
    }

    /// Moves the files of assets no longer in iCloud. Returns how many files were (or would be) moved.
    mutating func pruneOrphans(dryRun: Bool, onPrune: (String) -> Void) -> Int {
        guard !seen.isEmpty else { return 0 } // an empty listing is never trusted
        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            return f.string(from: Date())
        }()
        let quarantine = directory.appendingPathComponent(".icloudpd-swift-pruned", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        var moved = 0
        for (id, paths) in manifest where !seen.contains(id) {
            for path in paths {
                let source = directory.appendingPathComponent(path)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                onPrune(path)
                moved += 1
                if dryRun { continue }
                let target = quarantine.appendingPathComponent(path)
                try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.moveItem(at: source, to: target)
            }
            if !dryRun { manifest.removeValue(forKey: id) }
        }
        return moved
    }

    func save() {
        try? fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: manifestURL, options: .atomic) }
    }
}
