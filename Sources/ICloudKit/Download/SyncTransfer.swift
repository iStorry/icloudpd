import Foundation

/// Sends a run's files on to somewhere else (an Immich server) once they are downloaded.
public struct SyncTransfer: Sendable {
    /// What has been sent already, so it is neither sent nor downloaded again.
    public let ledger: TransferLedger
    /// False when the files only pass through this Mac: each is deleted once it has arrived.
    public let keepLocal: Bool
    /// Sends one file, with its XMP sidecar when it has one. Throws when it didn't arrive.
    public let send: @Sendable (_ file: URL, _ sidecar: URL?, _ created: Date) async throws -> Void

    public init(ledger: TransferLedger, keepLocal: Bool,
                send: @escaping @Sendable (_ file: URL, _ sidecar: URL?, _ created: Date) async throws -> Void) {
        self.ledger = ledger
        self.keepLocal = keepLocal
        self.send = send
    }

    /// A transfer to an Immich server. Requests are put together inside the download folder, so
    /// they are on the disk that was chosen for having room.
    public static func immich(_ client: ImmichClient, directory: URL, ledger: TransferLedger, keepLocal: Bool) -> SyncTransfer {
        let work = directory.appendingPathComponent(".icloudpd-swift", isDirectory: true)
            .appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.removeItem(at: work) // what a run that was cut short left behind
        return SyncTransfer(ledger: ledger, keepLocal: keepLocal) { file, sidecar, created in
            try await client.upload(file: file, sidecar: sidecar, created: created, workFolder: work)
        }
    }

    /// True for an error that would fail every other file the same way.
    static func stopsRun(_ error: Error) -> Bool {
        (error as? ImmichError)?.stopsRun ?? false
    }
}

/// Which files of a download folder have been sent on, by their path inside the folder, with the
/// size they have in iCloud. Kept in the folder, so it moves with it.
///
/// A sent file counts as downloaded even when it is no longer on this Mac. `pending` are files
/// downloaded only to be sent on: they are deleted once they have arrived, also in a later run.
public final class TransferLedger: @unchecked Sendable {
    private struct Stored: Codable {
        var sent: [String: Int] = [:]
        var pending: Set<String> = []
    }

    private let lock = NSLock()
    private let url: URL
    private var stored: Stored
    private var unsaved = 0

    /// `name` tells destinations apart: another server or account starts a ledger of its own.
    public init(directory: URL, name: String) {
        let safe = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_" })
        url = directory.appendingPathComponent(".icloudpd-swift", isDirectory: true)
            .appendingPathComponent("sent-\(safe).json")
        stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return stored.sent.count
    }

    public func size(of path: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return stored.sent[path]
    }

    public func contains(_ path: String) -> Bool { size(of: path) != nil }

    public func isPending(_ path: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stored.pending.contains(path)
    }

    public func markPending(_ path: String) {
        change { $0.pending.insert(path) }
    }

    /// The file arrived.
    public func record(_ path: String, size: Int) {
        change {
            $0.sent[path] = size
            $0.pending.remove(path)
        }
    }

    private func change(_ body: (inout Stored) -> Void) {
        lock.lock()
        body(&stored)
        unsaved += 1
        let due = unsaved >= 25
        lock.unlock()
        // Saved as it goes: a run that is cut short must not forget what it sent.
        if due { save() }
    }

    public func save() {
        lock.lock()
        let snapshot = stored
        unsaved = 0
        lock.unlock()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}

/// Sends the photos and videos already in a folder, whatever put them there. Nothing is deleted.
public enum FolderUpload {
    public struct Summary: Equatable, Sendable {
        public var sent = 0
        public var alreadySent = 0
        public var failed = 0
    }

    static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "gif", "tif", "tiff", "webp", "avif", "bmp", "jxl",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "srw", "pef", "3fr",
        "mov", "mp4", "m4v", "avi", "3gp", "mpg", "mpeg", "mkv", "webm", "mts",
    ]

    /// The media files in the folder with their paths inside it, sorted, hidden files and folders left out.
    static func mediaFiles(in directory: URL) -> [(url: URL, path: String)] {
        let root = directory.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(URL, String)] = []
        for case let url as URL in walker {
            guard mediaExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(root + "/") else { continue }
            found.append((url, String(full.dropFirst(root.count + 1))))
        }
        return found.sorted { $0.1 < $1.1 }
    }

    public static func run(directory: URL, transfer: SyncTransfer, parallel: Int = 3,
                           events emit: @escaping @Sendable (SyncEvent) -> Void) async throws -> Summary {
        let files = mediaFiles(in: directory)
        emit(.albumStarted(title: "Photos on this Mac", total: files.count))
        var summary = Summary()
        defer { transfer.ledger.save() }
        var done = 0
        try await withThrowingTaskGroup(of: Bool?.self) { group in
            var next = 0
            var running = 0
            while true {
                while running < max(1, parallel), next < files.count {
                    let file = files[next]
                    next += 1
                    if transfer.ledger.contains(file.path) {
                        summary.alreadySent += 1
                        done += 1
                        emit(.alreadyExists(path: file.path))
                        continue
                    }
                    running += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
                        let sidecar = URL(fileURLWithPath: file.url.path + ".xmp")
                        do {
                            try await transfer.send(file.url, FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil,
                                                    (attributes?[.modificationDate] as? Date) ?? Date())
                            transfer.ledger.record(file.path, size: (attributes?[.size] as? NSNumber)?.intValue ?? 0)
                            emit(.sent(path: file.path))
                            return true
                        } catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            if SyncTransfer.stopsRun(error) { throw error }
                            emit(.failed(name: file.path, message: error.localizedDescription))
                            return false
                        }
                    }
                }
                emit(.progress(processed: done))
                guard let result = try await group.next() else { break }
                running -= 1
                done += 1
                if result == true { summary.sent += 1 } else { summary.failed += 1 }
            }
        }
        emit(.progress(processed: done))
        return summary
    }
}
