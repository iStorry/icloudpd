import Foundation

public enum AssetItemType: Sendable {
    case image
    case movie
}

/// `--align-raw`: where RAW goes for RAW+JPEG assets.
public enum RawPolicy: String, Codable, CaseIterable, Sendable {
    case asIs = "as-is"
    case original
    case alternative
}

public enum VersionSize: String, CaseIterable, Sendable {
    case original
    case alternative
    case medium
    case thumb
    case adjusted
    case liveOriginal
    case liveMedium
    case liveThumb
    /// The edited video of an edited Live Photo (resVidFull on the asset record), the video
    /// counterpart of `adjusted` (#42).
    case liveAdjusted
}

public struct AssetVersion: Equatable, Sendable {
    public let size: Int
    public let url: URL
    public let type: String
    public let checksum: String
}

/// One photo or video in iCloud: a CPLAsset (date, flags, edits) plus its CPLMaster (the original files).
/// Port of pyicloud_ipd's PhotoAsset.
public struct PhotoAsset: @unchecked Sendable {
    let master: [String: Any]
    let asset: [String: Any]
    // Read out of the records once: a run asks for these several times per asset.
    let masterFields: [String: Any]
    let assetFields: [String: Any]
    /// The master record's name: icloudpd's asset id (used by name-id7 and pruning).
    public let id: String
    /// File name with invalid characters replaced, or a name made from the record id when iCloud has none.
    public let filename: String
    public let itemType: AssetItemType?
    /// The files iCloud has for this asset, by size. Asset fields (edits) win over master fields.
    public let versions: [VersionSize: AssetVersion]

    init(master: [String: Any], asset: [String: Any]) {
        self.master = master
        self.asset = asset
        let masterFields = master["fields"] as? [String: Any] ?? [:]
        let assetFields = asset["fields"] as? [String: Any] ?? [:]
        let id = master["recordName"] as? String ?? ""
        let rawItemType = (masterFields["itemType"] as? [String: Any])?["value"] as? String
        let filename = PhotoAsset.filename(masterFields: masterFields, id: id, rawItemType: rawItemType)
        let itemType = PhotoAsset.itemType(rawItemType, filename: filename)
        self.masterFields = masterFields
        self.assetFields = assetFields
        self.id = id
        self.filename = filename
        self.itemType = itemType
        self.versions = PhotoAsset.versions(itemType: itemType, assetFields: assetFields, masterFields: masterFields)
    }

    /// The CPLAsset record's name and change tag, needed to delete it in iCloud.
    public var assetRecordName: String { asset["recordName"] as? String ?? "" }
    public var assetRecordChangeTag: String? { asset["recordChangeTag"] as? String }

    static let itemTypes: [String: AssetItemType] = [
        "public.heic": .image, "public.heif": .image, "public.jpeg": .image, "public.png": .image,
        "public.jpeg-xl": .image, "com.apple.quicktime-movie": .movie,
        "com.adobe.raw-image": .image, "com.canon.cr2-raw-image": .image, "com.canon.crw-raw-image": .image,
        "com.sony.arw-raw-image": .image, "com.fuji.raw-image": .image, "com.panasonic.rw2-raw-image": .image,
        "com.nikon.nrw-raw-image": .image, "com.pentax.raw-image": .image, "com.nikon.raw-image": .image,
        "com.olympus.raw-image": .image, "com.canon.cr3-raw-image": .image, "com.olympus.or-raw-image": .image,
    ]

    static let itemTypeExtensions: [String: String] = [
        "public.heic": "HEIC", "public.heif": "HEIF", "public.jpeg": "JPG", "public.png": "PNG",
        "public.jpeg-xl": "JXL", "com.apple.quicktime-movie": "MOV", "com.adobe.raw-image": "DNG",
        "com.canon.cr2-raw-image": "CR2", "com.canon.crw-raw-image": "CRW", "com.sony.arw-raw-image": "ARW",
        "com.fuji.raw-image": "RAF", "com.panasonic.rw2-raw-image": "RW2", "com.nikon.nrw-raw-image": "NRF",
        "com.pentax.raw-image": "PEF", "com.nikon.raw-image": "NEF", "com.olympus.raw-image": "ORF",
        "com.canon.cr3-raw-image": "CR3", "com.olympus.or-raw-image": "ORF",
    ]

    static let photoVersionPrefixes: [(VersionSize, String)] = [
        (.original, "resOriginal"), (.alternative, "resOriginalAlt"), (.medium, "resJPEGMed"),
        (.thumb, "resJPEGThumb"), (.adjusted, "resJPEGFull"), (.liveOriginal, "resOriginalVidCompl"),
        (.liveMedium, "resVidMed"), (.liveThumb, "resVidSmall"), (.liveAdjusted, "resVidFull"),
    ]

    /// Versions that only count when the asset record has them: that's where iCloud keeps edits.
    static let editOnlyVersions: Set<VersionSize> = [.liveAdjusted]

    static let videoVersionPrefixes: [(VersionSize, String)] = [
        (.original, "resOriginal"), (.medium, "resVidMed"), (.thumb, "resVidSmall"),
    ]

    private var rawItemType: String? {
        (masterFields["itemType"] as? [String: Any])?["value"] as? String
    }

    /// The file name stored in iCloud (filenameEnc), or nil when there is none.
    public var originalFilename: String? { PhotoAsset.originalFilename(masterFields) }

    static func originalFilename(_ masterFields: [String: Any]) -> String? {
        guard let enc = masterFields["filenameEnc"] as? [String: Any],
              let value = enc["value"] as? String else { return nil }
        switch enc["type"] as? String {
        case "STRING": return value
        case "ENCRYPTED_BYTES":
            guard let data = Data(base64Encoded: value) else { return nil }
            return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    public var itemTypeExtension: String {
        rawItemType.flatMap { PhotoAsset.itemTypeExtensions[$0] } ?? "unknown"
    }

    static func filename(masterFields: [String: Any], id: String, rawItemType: String?) -> String {
        let raw = originalFilename(masterFields) ?? {
            let fingerprint = String(id.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }.prefix(12))
            return "\(fingerprint).\(rawItemType.flatMap { itemTypeExtensions[$0] } ?? "unknown")"
        }()
        return FilenamePolicy.clean(raw)
    }

    static let imageExtensions = [".heic", ".heif", ".png", ".jpg", ".jpeg", ".jxl", ".webp", ".gif", ".tif",
                                  ".tiff", ".avif", ".bmp", ".dng"]

    static func itemType(_ raw: String?, filename: String) -> AssetItemType? {
        guard let raw else { return nil }
        if let known = itemTypes[raw] { return known }
        let lower = filename.lowercased()
        return imageExtensions.contains(where: { lower.hasSuffix($0) }) ? .image : .movie
    }

    /// When the photo was taken (assetDate), or 1970 when iCloud has no date.
    public var createdDate: Date {
        if let ms = PhotoAsset.number((assetFields["assetDate"] as? [String: Any])?["value"]) {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return Date(timeIntervalSince1970: 0)
    }

    /// False when iCloud gave no usable date and `createdDate` fell back to 1970.
    public var hasAssetDate: Bool {
        PhotoAsset.number((assetFields["assetDate"] as? [String: Any])?["value"]) != nil
    }

    /// Seconds east of UTC where the photo was taken, when iCloud knows it.
    public var timeZoneOffset: Int? {
        PhotoAsset.number((assetFields["timeZoneOffset"] as? [String: Any])?["value"]).map(Int.init)
    }

    /// Size in bytes of the original file.
    public var size: Int {
        let res = (masterFields["resOriginalRes"] as? [String: Any])?["value"] as? [String: Any]
        return PhotoAsset.number(res?["size"]).map(Int.init) ?? 0
    }

    public var isHidden: Bool { PhotoAsset.number((assetFields["isHidden"] as? [String: Any])?["value"]) == 1 }
    public var isDeleted: Bool { PhotoAsset.number((assetFields["isDeleted"] as? [String: Any])?["value"]) == 1 }

    public var addedDate: Date? {
        PhotoAsset.number((assetFields["addedDate"] as? [String: Any])?["value"]).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    public var isScreenshot: Bool {
        guard let v = PhotoAsset.number((assetFields["assetSubtypeV2"] as? [String: Any])?["value"]) else { return false }
        return Int(v) == 3
    }

    public var isFavorite: Bool {
        PhotoAsset.number((assetFields["isFavorite"] as? [String: Any])?["value"]) == 1
    }

    static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    static func versions(itemType: AssetItemType?, assetFields: [String: Any],
                         masterFields: [String: Any]) -> [VersionSize: AssetVersion] {
        let prefixes = itemType == .movie ? videoVersionPrefixes : photoVersionPrefixes
        var result: [VersionSize: AssetVersion] = [:]
        for (size, prefix) in prefixes {
            let fields: [String: Any]
            if assetFields[prefix + "Res"] != nil { fields = assetFields }
            else if masterFields[prefix + "Res"] != nil, !editOnlyVersions.contains(size) { fields = masterFields }
            else { continue }
            guard let res = (fields[prefix + "Res"] as? [String: Any])?["value"] as? [String: Any],
                  let byteCount = number(res["size"]),
                  let urlString = res["downloadURL"] as? String,
                  let url = downloadURL(urlString),
                  let type = (fields[prefix + "FileType"] as? [String: Any])?["value"] as? String
            else { continue }
            result[size] = AssetVersion(size: Int(byteCount), url: url, type: type,
                                        checksum: res["fileChecksum"] as? String ?? "")
        }
        return result
    }

    /// CloudKit download URLs carry a literal `${f}` file name placeholder; encode the
    /// characters a strict URL parser rejects, the way python-requests does.
    static func downloadURL(_ string: String) -> URL? {
        if let url = URL(string: string), !string.contains("{") { return url }
        return string.addingPercentEncoding(withAllowedCharacters: downloadURLAllowed).flatMap(URL.init(string:))
    }

    static let downloadURLAllowed = CharacterSet.urlQueryAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: "%#"))
        .subtracting(CharacterSet(charactersIn: "{} "))

    /// Versions after the RAW policy: swaps original and alternative so RAW is where asked (`--align-raw`).
    public func versions(rawPolicy: RawPolicy) -> [VersionSize: AssetVersion] {
        var result = versions
        guard let alternative = result[.alternative], let original = result[.original] else { return result }
        if (alternative.type.contains("raw") && rawPolicy == .original)
            || (original.type.contains("raw") && rawPolicy == .alternative) {
            result[.alternative] = original
            result[.original] = alternative
        }
        return result
    }

    /// True when this is a Live Photo: an image with a paired video.
    public var isLivePhoto: Bool {
        itemType == .image && versions[.liveOriginal] != nil
    }
}
