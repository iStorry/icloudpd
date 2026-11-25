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
    case bytesReceived(Int)
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
    var reservationsForTests: PathReservations { reservations }

    public init(configuration: SyncConfiguration, timeZone: TimeZone = .current,
                events: @escaping @Sendable (SyncEvent) -> Void) throws {
        try configuration.validate()
        self.configuration = configuration
        self.timeZone = timeZone
        self.folderFormat = try FolderFormat(configuration.folderStructure)
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
        if !c.excludeFilenames.isEmpty {
            let name = baseFilename(asset)
            if c.excludeFilenames.contains(where: { FilenamePolicy.globMatches($0, name) }) { return false }
        }
        return true
    }

    // MARK: Paths

    func baseFilename(_ asset: PhotoAsset) -> String {
        FilenamePolicy.baseFilename(for: asset, policy: configuration.fileMatchPolicy,
                                    keepUnicode: configuration.keepUnicodeInFilenames)
    }

    func datePath(_ asset: PhotoAsset) -> [String] {
        folderFormat.components(for: asset.createdDate, timeZone: timeZone)
    }

    func url(in root: URL, _ components: [String], _ filename: String) -> URL {
        var url = root
        for c in components { url.appendPathComponent(c, isDirectory: true) }
        return url.appendingPathComponent(filename)
    }

    func relative(_ url: URL) -> String {
        for root in [configuration.directory, configuration.livePhotoDirectory].compactMap({ $0 }) {
            let base = root.standardizedFileURL.path
            let full = url.standardizedFileURL.path
            if full.hasPrefix(base + "/") { return String(full.dropFirst(base.count + 1)) }
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
        let sizes = c.sizes.map(\.versionSize)
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
        return reservations.withLock { reserved in
            func size(_ url: URL) -> Int? { reserved[url.path] ?? fileSize(url) }
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
               local != file.version.size,
               !(c.setExifDatetime && ExifDate.hasOwnDate(legacy ?? target, date: asset.createdDate,
                                                          localSize: local, iCloudSize: file.version.size)) {
                target = target.deletingLastPathComponent()
                    .appendingPathComponent(FilenamePolicy.dedupName(target.lastPathComponent, size: file.version.size))
                legacy = nil
                existing = size(target)
            }
            if existing != nil { return (nil, legacy ?? target) }
            reserved[target.path] = file.version.size
            return (target, nil)
        }
    }

    // MARK: Downloading one asset

    func process(_ asset: PhotoAsset, http: HTTPClient) async throws -> AssetResult {
        var result = AssetResult()
        let c = configuration
        let (files, missing) = plan(asset)
        let label = baseFilename(asset)
        for size in missing {
            log(.error, "\(size) size does not exist for \(label). Skipping...")
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
                let status = try await http.downloadFile(file.version.url, to: part) { [emit] bytes in
                    emit(.bytesReceived(bytes))
                }
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
        for album in albums {
            try Task.checkCancellation()
            let total = try? await album.count()
            let limit = c.recent.map { min($0, total ?? $0) }
            emit(.albumStarted(title: album.title, total: limit ?? total))
            log(.info, "Looking up \(c.skipVideos ? "photos" : c.skipPhotos ? "videos" : "photos and videos")\(album.name.isEmpty ? "" : " from album \(album.name)")...")

            let pager = album.pager()
            var listed = 0
            var consecutiveFound = 0
            var stop = false
            let parallel = c.untilFound == nil ? max(1, c.concurrentDownloads) : 1

            while !stop, let page = try await pager.nextPage() {
                try Task.checkCancellation()
                var batch = page
                if let limit, listed + batch.count > limit { batch = Array(batch.prefix(max(0, limit - listed))) }
                let passed = batch.map { passes($0, now: now) }

                // Download the page's assets in parallel, then handle the results in order.
                let results = try await withThrowingTaskGroup(of: (Int, AssetResult).self) { group -> [AssetResult?] in
                    var output = [AssetResult?](repeating: nil, count: batch.count)
                    var next = 0
                    func addNext() {
                        while next < batch.count && !passed[next] { next += 1 }
                        guard next < batch.count else { return }
                        let index = next
                        let asset = batch[index]
                        next += 1
                        group.addTask { (index, try await self.process(asset, http: photos.http)) }
                    }
                    for _ in 0..<parallel { addNext() }
                    while let (index, result) = try await group.next() {
                        output[index] = result
                        addNext()
                    }
                    return output
                }

                for (index, asset) in batch.enumerated() {
                    if let n = c.untilFound, consecutiveFound >= n {
                        log(.info, "Found \(n) consecutive previously downloaded photos. Exiting")
                        summary.stoppedByUntilFound = true
                        stop = true
                        break
                    }
                    listed += 1
                    summary.assetsSeen += 1
                    let result = results[index]
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
                    prune?.record(assetID: asset.id, paths: result?.expectedPaths ?? [])

                    if try await handleICloudDeletion(asset, passed: passed[index], result: result, library: library, now: now) {
                        summary.deletedFromICloud += 1
                        if !dryRun { pager.adjustOffset(by: -1) }
                    }
                }
                emit(.progress(processed: listed))
                if let limit, listed >= limit { stop = true }
            }
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
    func handleICloudDeletion(_ asset: PhotoAsset, passed: Bool, result: AssetResult?, library: PhotoLibrary, now: Date) async throws -> Bool {
        let c = configuration
        let label = baseFilename(asset)
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
        guard shouldDelete else { return false }
        if dryRun {
            log(.info, "[DRY RUN] Would delete \(label) in iCloud library \(library.name)")
            emit(.deletedFromICloud(name: label))
            return true
        }
        if try await library.delete(asset) {
            log(.info, "Deleted \(label) in iCloud")
            emit(.deletedFromICloud(name: label))
            return true
        }
        log(.error, "Could not delete \(label) in iCloud: iCloud asked to try again later")
        return false
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
        let (chosen, overrides) = FilenamePolicy.disambiguate(versions: versions, sizes: c.sizes.map(\.versionSize), base: base,
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
