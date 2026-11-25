import Foundation

/// How downloaded files are laid out in the target folder.
public enum FolderStructure: String, Codable, CaseIterable, Sendable {
    /// 2024/07/31/IMG_0001.HEIC (icloudpd's default "{:%Y/%m/%d}")
    case yearMonthDay = "yyyy/MM/dd"
    case yearMonth = "yyyy/MM"
    case year = "yyyy"
    /// Everything in one folder.
    case flat = "none"

    public var label: String {
        switch self {
        case .yearMonthDay: return "Year / Month / Day"
        case .yearMonth: return "Year / Month"
        case .year: return "Year"
        case .flat: return "One folder"
        }
    }

    /// Folder path components for a photo taken at `date`, in `timeZone` (local by default).
    public func components(for date: Date, timeZone: TimeZone = .current) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let y = String(format: "%04d", parts.year ?? 1970)
        let m = String(format: "%02d", parts.month ?? 1)
        let d = String(format: "%02d", parts.day ?? 1)
        switch self {
        case .yearMonthDay: return [y, m, d]
        case .yearMonth: return [y, m]
        case .year: return [y]
        case .flat: return []
        }
    }
}

/// File naming rules ported from icloudpd (paths.py, asset_version.py, base.py).
public enum FilenamePolicy {
    /// Replaces characters that aren't allowed in file names with "_".
    public static func clean(_ filename: String) -> String {
        var result = filename
        for char in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*", "\0"] {
            result = result.replacingOccurrences(of: char, with: "_")
        }
        return result
    }

    static func split(_ filename: String) -> (name: String, ext: String) {
        // Like os.path.splitext: a leading dot doesn't start an extension.
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else { return (filename, "") }
        return (String(filename[..<dot]), String(filename[dot...]))
    }

    public static func addSuffix(_ suffix: String, to filename: String) -> String {
        let (name, ext) = split(filename)
        return name + suffix + ext
    }

    /// The video half of a Live Photo: IMG_0001.HEIC -> IMG_0001_HEVC.MOV, IMG_0002.JPG -> IMG_0002.MOV
    /// (icloudpd's default "suffix" policy).
    public static func livePhotoVideoName(for filename: String) -> String {
        let (name, ext) = split(filename)
        if ext.isEmpty { return filename }
        return name + (ext.lowercased() == ".heic" ? "_HEVC.MOV" : ".MOV")
    }

    static let sizeSuffixes: [VersionSize: String] = [.medium: "medium", .thumb: "thumb"]

    /// File name for one version of an asset.
    public static func versionFilename(base: String, version: AssetVersion, size: VersionSize, isImage: Bool) -> String {
        var filename: String
        if isImage && version.type == "com.apple.quicktime-movie" {
            filename = livePhotoVideoName(for: base)
        } else {
            let (name, ext) = split(base)
            let newExt = PhotoAsset.itemTypeExtensions[version.type] ?? String(ext.dropFirst())
            filename = name + "." + newExt
        }
        if let suffix = sizeSuffixes[size] {
            filename = addSuffix("-\(suffix)", to: filename)
        }
        return filename
    }

    /// icloudpd's "name-size-dedup-with-suffix": a different file already using the name
    /// makes this one IMG_0001-123456.HEIC.
    public static func dedupName(_ filename: String, size: Int) -> String {
        let (name, ext) = split(filename)
        if ext.isEmpty { return "\(filename)-\(size)" }
        return "\(name)-\(size)\(ext)"
    }
}
