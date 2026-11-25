import Foundation

/// `--delete-list`: delete from iCloud the assets listed in a file, one
/// `FILENAME<TAB>SIZE[<TAB>DATE]` per line. Port of icloudpd's delete_from_list.
public struct DeleteList: Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let size: Int
        /// Unix seconds; the asset's date must be within two minutes of it.
        public let timestamp: Double?
        public let line: Int
        var key: String { name.uppercased() }
    }

    public struct Summary: Equatable, Sendable {
        public var deleted = 0
        public var notFound = 0
        public var failed = 0
        public var ambiguous = 0
        public var isClean: Bool { notFound == 0 && failed == 0 && ambiguous == 0 }
    }

    public static let dateTolerance: Double = 120
    static let minTimestamp: Double = 1_000_000_000
    static let maxTimestamp: Double = 4_102_444_800

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// Parses the file. Lines without a date are refused unless `allowUndated` (they would match by
    /// name and size alone, which can be another photo once the intended one is gone).
    public init(contents: String, allowUndated: Bool = false, source: String = "delete list") throws {
        var entries: [Entry] = []
        var text = contents
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let number = offset + 1
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty || line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            let parts = line.components(separatedBy: "\t")
            let name = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let sizeText = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard (2...3).contains(parts.count), !name.isEmpty, !sizeText.isEmpty,
                  sizeText.allSatisfy(\.isNumber), let size = Int(sizeText) else {
                throw ICloudError.invalidOption("\(source):\(number): expected FILENAME<TAB>SIZE<TAB>DATE, got \"\(line)\"")
            }
            var timestamp: Double?
            if parts.count == 3, !parts[2].trimmingCharacters(in: .whitespaces).isEmpty {
                timestamp = try DeleteList.parseDate(parts[2].trimmingCharacters(in: .whitespaces), source: "\(source):\(number)")
            } else if !allowUndated {
                throw ICloudError.invalidOption("\(source):\(number): no DATE. Add the date, or allow undated lines.")
            }
            entries.append(Entry(name: name, size: size, timestamp: timestamp, line: number))
        }
        self.entries = entries
    }

    static func parseDate(_ raw: String, source: String) throws -> Double {
        if let value = Double(raw) {
            guard value.isFinite, (minTimestamp...maxTimestamp).contains(value) else {
                throw ICloudError.invalidOption("\(source): DATE \(raw) is not a unix timestamp in seconds between 2001 and 2100")
            }
            return value
        }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: raw) {
                let t = date.timeIntervalSince1970
                guard (minTimestamp...maxTimestamp).contains(t) else {
                    throw ICloudError.invalidOption("\(source): DATE \(raw) is not between 2001 and 2100")
                }
                return t
            }
        }
        throw ICloudError.invalidOption("\(source): invalid DATE \(raw); write it like 2024-01-31T14:05:09+01:00 or ...Z")
    }

    /// The names an asset can have on disk: plain, or with the name-id7 suffix.
    static func names(of asset: PhotoAsset) -> Set<String> {
        let plain = asset.filename
        return [plain.uppercased(), FilenamePolicy.addSuffix(FilenamePolicy.id7Suffix(assetID: asset.id), to: plain).uppercased()]
    }

    static func matches(_ entry: Entry, _ asset: PhotoAsset) -> Bool {
        guard asset.size == entry.size, names(of: asset).contains(entry.key) else { return false }
        guard let t = entry.timestamp else { return true }
        return abs(asset.createdDate.timeIntervalSince1970 - t) <= dateTolerance
    }

    /// Finds and deletes the listed assets. Deleted photos are usually among the newest, so the first
    /// page answers most lists; anything not found there is looked for in the whole library.
    public func run(library: PhotoLibrary, maxEntries: Int = 100, dryRun: Bool,
                    log: @Sendable (SyncLogLevel, String) -> Void) async throws -> Summary {
        var summary = Summary()
        guard !entries.isEmpty else { log(.info, "The delete list is empty"); return summary }
        guard entries.count <= maxEntries else {
            throw ICloudError.invalidOption("The delete list has \(entries.count) entries, more than the limit of \(maxEntries). Refusing to run.")
        }
        let wanted = Set(entries.map { "\($0.key)\t\($0.size)" })
        var seen: [String: PhotoAsset] = [:]
        func consider(_ asset: PhotoAsset) {
            if DeleteList.names(of: asset).contains(where: { wanted.contains("\($0)\t\(asset.size)") }) { seen[asset.id] = asset }
        }
        let album = library.all
        if let head = try await album.pager(pageSize: 100).nextPage() { head.forEach(consider) }
        let unresolved = entries.filter { e in e.timestamp == nil || !seen.values.contains { DeleteList.matches(e, $0) } }
        if !unresolved.isEmpty {
            log(.info, "Reading the whole iCloud library to find \(unresolved.count) entries...")
            var scanned = 0
            for try await asset in album.photos() {
                consider(asset)
                scanned += 1
                if scanned % 2000 == 0 { log(.info, "Scanned \(scanned) assets...") }
            }
        }

        var requested: [String: Int] = [:]
        for entry in entries {
            let found = seen.values.filter { DeleteList.matches(entry, $0) }
            let described = "\(entry.name) \(entry.size)"
            if found.count == 1, let asset = found.first {
                if let line = requested[asset.id] {
                    log(.warning, "Line \(entry.line) is the same photo as line \(line), nothing more to do: \(described)")
                    continue
                }
                requested[asset.id] = entry.line
                if dryRun {
                    log(.info, "[DRY RUN] Would delete \(asset.filename) in iCloud library \(library.name)")
                    summary.deleted += 1
                    continue
                }
                do {
                    if try await library.delete(asset) {
                        log(.info, "Deleted \(asset.filename) in iCloud")
                        summary.deleted += 1
                    } else {
                        summary.failed += 1
                    }
                } catch {
                    log(.error, "Could not delete \(described) (line \(entry.line)): \(error.localizedDescription)")
                    summary.failed += 1
                }
            } else if found.isEmpty {
                log(.warning, "Not found in iCloud (line \(entry.line)): \(described)")
                summary.notFound += 1
            } else {
                log(.warning, "Ambiguous, \(found.count) assets in iCloud match (line \(entry.line)): \(described). Skipping")
                summary.ambiguous += 1
            }
        }
        log(.info, "Delete list summary: \(dryRun ? "would_delete" : "deleted")=\(summary.deleted) not_found=\(summary.notFound) failed=\(summary.failed) ambiguous=\(summary.ambiguous)")
        return summary
    }
}
