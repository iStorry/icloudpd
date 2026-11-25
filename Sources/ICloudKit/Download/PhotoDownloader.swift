import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DownloadOptions: Equatable, Sendable {
    public var directory: URL
    public var folderStructure: FolderStructure
    public var includeVideos: Bool
    public var includeLivePhotoVideos: Bool
    /// Stop after this many photos (newest-first isn't available yet, so this counts from the oldest). nil = all.
    public var limit: Int?

    public init(directory: URL, folderStructure: FolderStructure = .yearMonthDay,
                includeVideos: Bool = true, includeLivePhotoVideos: Bool = true, limit: Int? = nil) {
        self.directory = directory
        self.folderStructure = folderStructure
        self.includeVideos = includeVideos
        self.includeLivePhotoVideos = includeLivePhotoVideos
        self.limit = limit
    }
}

public enum DownloadEvent: Sendable {
    case counted(total: Int)
    /// One asset was looked at (downloaded, already there, or skipped by the options).
    case processed(index: Int)
    case downloaded(path: String, bytes: Int)
    case alreadyExists(path: String)
    case failed(name: String, message: String)
}

public struct DownloadSummary: Equatable, Sendable {
    public var assetsSeen = 0
    public var filesDownloaded = 0
    public var filesSkipped = 0
    public var filesFailed = 0
    public var bytesDownloaded = 0
}

/// One file to write: which iCloud version, and where.
public struct PlannedFile: Equatable {
    public let version: AssetVersion
    public let size: VersionSize
    /// Path relative to the download folder, e.g. 2024/07/31/IMG_0001.HEIC
    public let relativePath: String
}

/// Downloads originals (and Live Photo videos) into dated folders, skipping files that
/// are already there. Port of the core of icloudpd's download loop.
public final class PhotoDownloader: @unchecked Sendable {
    let options: DownloadOptions
    let fileManager = FileManager.default

    public init(options: DownloadOptions) {
        self.options = options
    }

    /// The files to write for one asset, before checking what's on disk.
    public func plan(_ asset: PhotoAsset, timeZone: TimeZone = .current) -> [PlannedFile] {
        let versions = asset.versions
        let isImage = (asset.itemType ?? .image) == .image
        if !isImage && !options.includeVideos { return [] }

        let folder = options.folderStructure.components(for: asset.createdDate, timeZone: timeZone)
        func path(_ name: String) -> String { (folder + [name]).joined(separator: "/") }

        var files: [PlannedFile] = []
        if let original = versions[.original] {
            let name = FilenamePolicy.versionFilename(base: asset.filename, version: original, size: .original, isImage: isImage)
            files.append(PlannedFile(version: original, size: .original, relativePath: path(name)))
        }
        if isImage, options.includeLivePhotoVideos, let live = versions[.liveOriginal] {
            let name = FilenamePolicy.versionFilename(base: asset.filename, version: live, size: .liveOriginal, isImage: true)
            files.append(PlannedFile(version: live, size: .liveOriginal, relativePath: path(name)))
        }
        return files
    }

    /// Where a planned file goes on disk, or nil when an identical file is already there.
    /// A different file with the same name gets the "-<size>" suffix, like icloudpd.
    public func resolveDestination(_ file: PlannedFile) -> URL? {
        let url = options.directory.appendingPathComponent(file.relativePath)
        guard let existing = fileSize(url) else { return url }
        if existing == file.version.size { return nil }
        let dedup = url.deletingLastPathComponent()
            .appendingPathComponent(FilenamePolicy.dedupName(url.lastPathComponent, size: file.version.size))
        return fileManager.fileExists(atPath: dedup.path) ? nil : dedup
    }

    func fileSize(_ url: URL) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// Runs the download. Events arrive on whatever task this runs on.
    public func run(service: PhotosService, events: @escaping @Sendable (DownloadEvent) -> Void) async throws -> DownloadSummary {
        var summary = DownloadSummary()
        if let total = try? await service.count() {
            events(.counted(total: options.limit.map { min($0, total) } ?? total))
        }
        try fileManager.createDirectory(at: options.directory, withIntermediateDirectories: true)

        for try await asset in service.allPhotos() {
            try Task.checkCancellation()
            if let limit = options.limit, summary.assetsSeen >= limit { break }
            summary.assetsSeen += 1

            for file in plan(asset) {
                try Task.checkCancellation()
                guard let destination = resolveDestination(file) else {
                    summary.filesSkipped += 1
                    events(.alreadyExists(path: file.relativePath))
                    continue
                }
                do {
                    try await download(file, to: destination, http: service.http, created: asset.createdDate)
                    summary.filesDownloaded += 1
                    summary.bytesDownloaded += file.version.size
                    events(.downloaded(path: relative(destination), bytes: file.version.size))
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ICloudError {
                    if case .http(let status, _) = error, [401, 421, 450].contains(status) { throw error }
                    summary.filesFailed += 1
                    events(.failed(name: file.relativePath, message: error.localizedDescription))
                } catch {
                    summary.filesFailed += 1
                    events(.failed(name: file.relativePath, message: error.localizedDescription))
                }
            }
            events(.processed(index: summary.assetsSeen))
        }
        return summary
    }

    func relative(_ url: URL) -> String {
        let base = options.directory.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        return full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : full
    }

    /// Downloads to a temporary file, checks it, then moves it into place, so an
    /// interrupted run never leaves a half-written photo under its real name.
    func download(_ file: PlannedFile, to destination: URL, http: HTTPClient, created: Date, attempts: Int = 3) async throws {
        var lastError: Error = ICloudError.unexpectedResponse("download")
        for attempt in 1...attempts {
            do {
                let (temp, response) = try await http.download(file.version.url)
                defer { try? fileManager.removeItem(at: temp) }
                guard (200..<300).contains(response.statusCode) else {
                    throw ICloudError.http(status: response.statusCode, message: "Download failed.")
                }
                if let size = fileSize(temp), file.version.size > 0, size != file.version.size {
                    throw ICloudError.unexpectedResponse("got \(size) bytes, expected \(file.version.size)")
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: temp, to: destination)
                try? fileManager.setAttributes([.modificationDate: created, .creationDate: created], ofItemAtPath: destination.path)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if case ICloudError.http(let status, _) = error, [401, 403, 421, 450].contains(status) { throw error }
                if attempt < attempts { try await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) }
            }
        }
        throw lastError
    }
}
