import Foundation

/// Image sizes icloudpd's `--size` accepts.
public enum PhotoSize: String, Codable, CaseIterable, Sendable {
    case original
    case adjusted
    case alternative
    case medium
    case thumb

    var versionSize: VersionSize {
        switch self {
        case .original: return .original
        case .adjusted: return .adjusted
        case .alternative: return .alternative
        case .medium: return .medium
        case .thumb: return .thumb
        }
    }

    public var label: String {
        switch self {
        case .original: return "Original"
        case .adjusted: return "Edited (adjusted)"
        case .alternative: return "Alternative (RAW+JPEG pair)"
        case .medium: return "Medium"
        case .thumb: return "Thumbnail"
        }
    }
}

/// `--live-photo-size`
public enum LivePhotoSize: String, Codable, CaseIterable, Sendable {
    case original
    case medium
    case thumb

    var versionSize: VersionSize {
        switch self {
        case .original: return .liveOriginal
        case .medium: return .liveMedium
        case .thumb: return .liveThumb
        }
    }
}

/// `--live-photo-mov-filename-policy`
public enum LivePhotoMovFilenamePolicy: String, Codable, CaseIterable, Sendable {
    /// IMG_0001.HEIC -> IMG_0001_HEVC.MOV
    case suffix
    /// IMG_0001.HEIC -> IMG_0001.MOV
    case original
}

/// `--file-match-policy`
public enum FileMatchPolicy: String, Codable, CaseIterable, Sendable {
    /// A different file with the same name gets "-<size>" added.
    case nameSizeDedupWithSuffix = "name-size-dedup-with-suffix"
    /// Every file name gets "_<7 chars of the asset id>"; no de-duplication.
    case nameID7 = "name-id7"
}

/// `--skip-created-before` / `--skip-created-after`: an ISO date or "N days ago".
public enum DateBound: Codable, Equatable, Sendable {
    case date(Date)
    case daysAgo(Int)

    public func resolve(now: Date = Date()) -> Date {
        switch self {
        case .date(let date): return date
        case .daysAgo(let days): return now.addingTimeInterval(-Double(days) * 86_400)
        }
    }

    /// Parses "2025-01-02", "2025-01-02T10:00:00", an ISO date with an offset, or "20d".
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> DateBound? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasSuffix("d"), let days = Int(trimmed.dropLast()), days >= 0 {
            return .daysAgo(days)
        }
        if let days = Int(trimmed), days >= 0, trimmed.count < 5 { return .daysAgo(days) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return .date(date) }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return .date(date) }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return .date(date) }
        }
        return nil
    }
}

/// Everything one download run needs: the native equivalent of icloudpd's per-user options.
public struct SyncConfiguration: Codable, Equatable, Sendable {
    // Where
    public var directoryPath: String
    /// Python-style folder format, e.g. "{:%Y/%m/%d}" (the default), or "none".
    public var folderStructure: String = "{:%Y/%m/%d}"
    /// Put Live Photo videos here (same folder structure) instead of next to the photo.
    public var livePhotoDirectoryPath: String?

    // What
    /// Library zone name; nil is the primary library.
    public var library: String?
    /// Albums to download; empty means the whole library.
    public var albums: [String] = []
    public var sizes: [PhotoSize] = [.original]
    public var forceSize = false
    public var livePhotoSize: LivePhotoSize = .original
    public var skipLivePhotos = false
    public var skipVideos = false
    public var skipPhotos = false
    public var skipScreenshots = false
    public var skipCreatedBefore: DateBound?
    public var skipCreatedAfter: DateBound?
    /// Glob patterns (`IMG_12*.JPG`), matched ignoring case.
    public var excludeFilenames: [String] = []
    /// Only the N most recent photos.
    public var recent: Int?
    /// Stop after N consecutive photos that are already downloaded.
    public var untilFound: Int?

    // Naming
    public var livePhotoMovFilenamePolicy: LivePhotoMovFilenamePolicy = .suffix
    public var alignRaw: RawPolicy = .asIs
    public var fileMatchPolicy: FileMatchPolicy = .nameSizeDedupWithSuffix
    /// icloudpd removes non-ASCII characters from file names unless asked to keep them.
    public var keepUnicodeInFilenames = false

    // Metadata
    public var setExifDatetime = false
    public var xmpSidecar = false
    public var xmpSidecarOnly = false

    // Sync and delete
    /// Delete local files whose photo is in iCloud's Recently Deleted (`--auto-delete`).
    public var autoDelete = false
    /// Move files this app wrote whose photo disappeared from iCloud into a quarantine folder.
    public var pruneOrphans = false
    /// Delete each photo from iCloud after downloading it.
    public var deleteAfterDownload = false
    /// Delete photos older than this many days from iCloud once they are downloaded ("move" mode).
    public var keepICloudRecentDays: Int?

    // Run
    /// Don't write, move or delete anything locally or in iCloud; just report.
    public var dryRun = false
    public var concurrentDownloads = 4
    public var ignoreIndexingState = false
    public var temporarySuffix = ".part"

    public init(directoryPath: String) {
        self.directoryPath = directoryPath
    }

    public var directory: URL { URL(fileURLWithPath: (directoryPath as NSString).expandingTildeInPath, isDirectory: true) }
    public var livePhotoDirectory: URL? {
        livePhotoDirectoryPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    /// True when the run may delete photos from iCloud.
    public var deletesFromICloud: Bool { deleteAfterDownload || keepICloudRecentDays != nil }

    /// Checks option combinations icloudpd refuses.
    public func validate() throws {
        if directoryPath.isEmpty { throw ICloudError.invalidOption("Choose a download folder.") }
        if sizes.isEmpty { throw ICloudError.invalidOption("Choose at least one size.") }
        if skipPhotos && skipVideos { throw ICloudError.invalidOption("Skipping both photos and videos leaves nothing to download.") }
        if let days = keepICloudRecentDays, days < 0 { throw ICloudError.invalidOption("Keep-in-iCloud days can't be negative.") }
        if deletesFromICloud && ignoreIndexingState {
            throw ICloudError.invalidOption("Deleting from iCloud can't be combined with ignoring the indexing state.")
        }
        if deletesFromICloud && xmpSidecarOnly {
            throw ICloudError.invalidOption("Deleting from iCloud needs the photos downloaded, not only XMP sidecars.")
        }
        if !temporarySuffix.hasPrefix(".") || temporarySuffix.count < 2 {
            throw ICloudError.invalidOption("The temporary suffix must start with a dot.")
        }
        _ = try FolderFormat(folderStructure)
    }
}
