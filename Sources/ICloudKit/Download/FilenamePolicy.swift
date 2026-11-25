import Foundation

/// Folder layout presets for the app's picker. The engine itself takes any icloudpd-style format string.
public enum FolderStructure: String, Codable, CaseIterable, Sendable {
    case yearMonthDay = "{:%Y/%m/%d}"
    case yearMonth = "{:%Y/%m}"
    case year = "{:%Y}"
    case yearMonthName = "{:%Y/%B}"
    case flat = "none"

    public var label: String {
        switch self {
        case .yearMonthDay: return "Year / Month / Day"
        case .yearMonth: return "Year / Month"
        case .year: return "Year"
        case .yearMonthName: return "Year / Month name"
        case .flat: return "One folder"
        }
    }

    /// Folder path components for a photo taken at `date`.
    public func components(for date: Date, timeZone: TimeZone = .current) -> [String] {
        (try? FolderFormat(rawValue))?.components(for: date, timeZone: timeZone) ?? []
    }
}

/// icloudpd's `--folder-structure`: a Python format string applied to the creation date,
/// like "{:%Y/%m/%d}" or "photos/{:%Y}/{:%m-%B}", or "none" for no subfolders.
public struct FolderFormat: Equatable, Sendable {
    enum Piece: Equatable { case literal(String), strftime(String) }
    let pieces: [Piece]
    public let isNone: Bool

    public init(_ format: String) throws {
        if format.lowercased() == "none" || format.isEmpty {
            pieces = []
            isNone = true
            return
        }
        isNone = false
        var result: [Piece] = []
        var literal = ""
        var index = format.startIndex
        while index < format.endIndex {
            let char = format[index]
            if char == "{" {
                let next = format.index(after: index)
                if next < format.endIndex, format[next] == "{" {
                    literal.append("{"); index = format.index(after: next); continue
                }
                guard let close = format[index...].firstIndex(of: "}") else {
                    throw ICloudError.invalidOption("Folder structure \"\(format)\" has a \"{\" without \"}\".")
                }
                var field = String(format[format.index(after: index)..<close])
                guard field.hasPrefix(":") else {
                    throw ICloudError.invalidOption("Folder structure fields must look like {:%Y}, got {\(field)}.")
                }
                field.removeFirst()
                if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                result.append(.strftime(field))
                index = format.index(after: close)
            } else if char == "}" {
                let next = format.index(after: index)
                if next < format.endIndex, format[next] == "}" { literal.append("}"); index = format.index(after: next); continue }
                throw ICloudError.invalidOption("Folder structure \"\(format)\" has a \"}\" without \"{\".")
            } else {
                literal.append(char)
                index = format.index(after: index)
            }
        }
        if !literal.isEmpty { result.append(.literal(literal)) }
        pieces = result
    }

    /// The relative folder path for `date` ("" for none).
    public func path(for date: Date, timeZone: TimeZone = .current) -> String {
        isNone ? "" : path(for: date, calendar: Strftime.calendar(timeZone))
    }

    /// With a calendar from `Strftime.calendar`, so a run makes one instead of one per photo.
    func path(for date: Date, calendar: Calendar) -> String {
        if isNone { return "" }
        return pieces.map { piece in
            switch piece {
            case .literal(let s): return s
            case .strftime(let f): return Strftime.format(f, date: date, calendar: calendar)
            }
        }.joined()
    }

    public func components(for date: Date, timeZone: TimeZone = .current) -> [String] {
        isNone ? [] : components(for: date, calendar: Strftime.calendar(timeZone))
    }

    func components(for date: Date, calendar: Calendar) -> [String] {
        path(for: date, calendar: calendar).split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }
}

/// The strftime directives Python supports on every platform, in the C/POSIX locale.
enum Strftime {
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"]
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func format(_ format: String, date: Date, timeZone: TimeZone) -> String {
        self.format(format, date: date, calendar: calendar(timeZone))
    }

    static func format(_ format: String, date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let year = c.year ?? 1970, month = c.month ?? 1, day = c.day ?? 1
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0
        let weekday = (c.weekday ?? 1) - 1
        func pad(_ v: Int, _ width: Int = 2) -> String { String(format: "%0\(width)d", v) }

        var out = ""
        var i = format.startIndex
        while i < format.endIndex {
            let ch = format[i]
            guard ch == "%", format.index(after: i) < format.endIndex else {
                out.append(ch); i = format.index(after: i); continue
            }
            let d = format[format.index(after: i)]
            switch d {
            case "Y": out += pad(year, 4)
            case "y": out += pad(year % 100)
            case "m": out += pad(month)
            case "d": out += pad(day)
            case "H": out += pad(hour)
            case "I": out += pad(hour % 12 == 0 ? 12 : hour % 12)
            case "p": out += hour < 12 ? "AM" : "PM"
            case "M": out += pad(minute)
            case "S": out += pad(second)
            case "B": out += months[month - 1]
            case "b", "h": out += String(months[month - 1].prefix(3))
            case "A": out += weekdays[weekday]
            case "a": out += String(weekdays[weekday].prefix(3))
            case "w": out += String(weekday)
            case "j": out += pad(calendar.ordinality(of: .day, in: .year, for: date) ?? 1, 3)
            case "%": out += "%"
            default: out += "%" + String(d)
            }
            i = format.index(i, offsetBy: 2)
        }
        return out
    }
}

/// File naming rules ported from icloudpd (paths.py, asset_version.py, base.py, utils.py).
public enum FilenamePolicy {
    /// Replaces characters that aren't allowed in file names with "_".
    public static func clean(_ filename: String) -> String {
        var result = filename
        for char in ["<", ">", ":", "\"", "/", "\\", "|", "?", "*", "\0"] {
            result = result.replacingOccurrences(of: char, with: "_")
        }
        return result
    }

    /// icloudpd's default cleaner: drops every non-ASCII character.
    public static func removeUnicode(_ filename: String) -> String {
        String(String.UnicodeScalarView(filename.unicodeScalars.filter(\.isASCII)))
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

    /// "_" plus the first 7 characters of the base64 of the asset id (`name-id7`).
    public static func id7Suffix(assetID: String) -> String {
        "_" + String(Data(assetID.utf8).base64EncodedString().prefix(7))
    }

    /// The name an asset is written under, before size and type changes: iCloud's name (or a
    /// fallback from the id), cleaned, with the file match policy applied.
    public static func baseFilename(for asset: PhotoAsset, policy: FileMatchPolicy, keepUnicode: Bool) -> String {
        var name = asset.filename
        if !keepUnicode { name = removeUnicode(name) }
        if policy == .nameID7 { name = addSuffix(id7Suffix(assetID: asset.id), to: name) }
        return name
    }

    /// The video half of a Live Photo.
    public static func livePhotoVideoName(for filename: String, policy: LivePhotoMovFilenamePolicy = .suffix) -> String {
        let (name, ext) = split(filename)
        if policy == .original { return name + ".MOV" }
        if ext.isEmpty { return filename }
        return name + (ext.lowercased() == ".heic" ? "_HEVC.MOV" : ".MOV")
    }

    static let sizeSuffixes: [VersionSize: String] = [.medium: "medium", .thumb: "thumb"]

    /// File name for one version of an asset (calculate_asset_version_filename).
    public static func versionFilename(base: String, version: AssetVersion, size: VersionSize, isImage: Bool,
                                       livePolicy: LivePhotoMovFilenamePolicy = .suffix) -> String {
        var filename: String
        if isImage && version.type == "com.apple.quicktime-movie" {
            filename = livePhotoVideoName(for: base, policy: livePolicy)
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

    /// "name-size-dedup-with-suffix": a different file already using the name makes this one IMG_0001-123456.HEIC.
    public static func dedupName(_ filename: String, size: Int) -> String {
        let (name, ext) = split(filename)
        if ext.isEmpty { return "\(filename)-\(size)" }
        return "\(name)-\(size)\(ext)"
    }

    /// Port of pyicloud_ipd's disambiguate_filenames: which versions to fetch for the requested
    /// sizes, and name overrides when two of them would end up with the same file name.
    public static func disambiguate(versions: [VersionSize: AssetVersion], sizes: [VersionSize], base: String,
                                    isImage: Bool, livePolicy: LivePhotoMovFilenamePolicy)
        -> (versions: [VersionSize: AssetVersion], overrides: [VersionSize: String]) {
        var results: [VersionSize: AssetVersion] = [:]
        var overrides: [VersionSize: String] = [:]
        func name(_ v: AssetVersion, _ s: VersionSize) -> String {
            versionFilename(base: base, version: v, size: s, isImage: isImage, livePolicy: livePolicy)
        }
        for size in sizes { if let v = versions[size] { results[size] = v } }

        if sizes.contains(.adjusted) {
            if !sizes.contains(.original) {
                if results[.adjusted] == nil, let original = versions[.original] { results[.adjusted] = original }
            } else if let adjusted = results[.adjusted], let original = results[.original] {
                let adjustedName = name(adjusted, .adjusted)
                if name(original, .original) == adjustedName {
                    overrides[.adjusted] = addSuffix("-adjusted", to: adjustedName)
                }
            }
        }
        if sizes.contains(.alternative) {
            if results[.alternative] == nil {
                if !sizes.contains(.original), let original = versions[.original] { results[.alternative] = original }
            } else if let alternative = results[.alternative] {
                let altName = name(alternative, .alternative)
                let clashes = [results[.adjusted].map { name($0, .adjusted) }, results[.original].map { name($0, .original) }]
                    .contains { $0 == altName }
                if clashes { overrides[.alternative] = addSuffix("-alternative", to: altName) }
            }
        }
        for size in sizes where ![.original, .adjusted, .alternative].contains(size)
            && results[size] == nil && !sizes.contains(.original) {
            if let original = versions[.original] { results[.original] = original }
        }
        return (results, overrides)
    }

    /// Glob match ignoring case (`--exclude-filename`), with *, ? and [...] like fnmatch.
    public static func globMatches(_ pattern: String, _ name: String) -> Bool {
        name.range(of: globRegex(pattern), options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The glob compiled once, for matching many names. Nil when the pattern isn't a valid one,
    /// which then matches nothing.
    static func globExpression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: globRegex(pattern), options: [.caseInsensitive])
    }

    static func globRegex(_ pattern: String) -> String {
        var regex = "^"
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            switch c {
            case "*": regex += ".*"
            case "?": regex += "."
            case "[":
                if let close = pattern[pattern.index(after: i)...].firstIndex(of: "]") {
                    var set = String(pattern[pattern.index(after: i)..<close])
                    if set.hasPrefix("!") { set = "^" + set.dropFirst() }
                    regex += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = close
                } else {
                    regex += "\\["
                }
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = pattern.index(after: i)
        }
        regex += "$"
        return regex
    }
}
