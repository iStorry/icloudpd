import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(Compression)
import Compression
#endif

/// XMP sidecars (`--xmp-sidecar`), a port of icloudpd's xmp_sidecar.py.
public enum XMPSidecar {
    public static let toolkit = "icloudpd-swift 0.2"

    public struct Metadata: Equatable {
        public var title: String?
        public var description: String?
        public var orientation: Int?
        public var make: String?
        public var digitalSourceType: String?
        public var keywords: [String]?
        public var gpsAltitude: Double?
        public var gpsLatitude: Double?
        public var gpsLongitude: Double?
        public var gpsSpeed: Double?
        public var gpsTimestamp: Date?
        public var createDate: Date?
        public var createDateOffset: Int = 0
        public var rating: Int?
    }

    static func decodeBase64String(_ field: Any?) -> String? {
        guard let value = (field as? [String: Any])?["value"] as? String,
              let data = Data(base64Encoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodePlist(_ field: Any?) -> Any? {
        guard let value = (field as? [String: Any])?["value"] as? String,
              let data = Data(base64Encoded: value) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    /// Inflates raw DEFLATE data (Python's zlib.decompress(data, -zlib.MAX_WBITS)).
    static func inflateRaw(_ data: Data) -> Data? {
        #if canImport(Compression)
        let capacity = max(data.count * 8, 4096)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? output.prefix(written) : nil
        #else
        return nil
        #endif
    }

    public static func metadata(for asset: PhotoAsset) -> Metadata {
        let fields = asset.assetFields
        var m = Metadata()
        m.title = decodeBase64String(fields["captionEnc"])
        m.description = decodeBase64String(fields["extendedDescEnc"])

        // adjustmentSimpleDataEnc is a binary plist ("YnBsaXN0MD"), a CRDT drawing ("Y3JkdA"),
        // or raw-deflated JSON with the orientation; only the JSON is used.
        if let value = (fields["adjustmentSimpleDataEnc"] as? [String: Any])?["value"] as? String,
           !value.hasPrefix("Y3JkdA"), !value.hasPrefix("YnBsaXN0MD"),
           let raw = Data(base64Encoded: value), let json = inflateRaw(raw),
           let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let meta = object["metadata"] as? [String: Any],
           let orientation = PhotoAsset.number(meta["orientation"]) {
            m.orientation = Int(orientation)
        }

        if asset.isScreenshot {
            m.make = "Screenshot"
            m.digitalSourceType = "screenCapture"
        }
        m.keywords = decodePlist(fields["keywordsEnc"]) as? [String]
        if let location = decodePlist(fields["locationEnc"]) as? [String: Any] {
            m.gpsAltitude = PhotoAsset.number(location["alt"])
            m.gpsLatitude = PhotoAsset.number(location["lat"])
            m.gpsLongitude = PhotoAsset.number(location["lon"])
            m.gpsSpeed = PhotoAsset.number(location["speed"])
            m.gpsTimestamp = location["timestamp"] as? Date
        }
        if asset.hasAssetDate {
            m.createDate = asset.createdDate
            m.createDateOffset = asset.timeZoneOffset ?? 0
        }
        if asset.isHidden || asset.isDeleted {
            m.rating = -1 // rejected
        } else if asset.isFavorite {
            m.rating = 5
        }
        return m
    }

    static func escape(_ s: String, attribute: Bool = false) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            out = out.replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "\n", with: "&#10;")
        }
        return out
    }

    static func pyFloat(_ d: Double) -> String {
        if d == d.rounded(), abs(d) < 1e16 { return String(format: "%.1f", d) }
        return "\(d)"
    }

    /// "%Y-%m-%dT%H:%M:%S%z"
    static func timestamp(_ date: Date, offsetSeconds: Int) -> String {
        let tz = TimeZone(secondsFromGMT: offsetSeconds) ?? TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = tz
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let sign = offsetSeconds < 0 ? "-" : "+"
        let a = abs(offsetSeconds)
        return formatter.string(from: date) + String(format: "%@%02d%02d", sign, a / 3600, (a % 3600) / 60)
    }

    /// The sidecar XML, laid out the way Python's ElementTree writes it.
    public static func xml(_ m: Metadata, toolkit: String = XMPSidecar.toolkit) -> String {
        func el(_ name: String, _ text: String) -> String { "<\(name)>\(escape(text))</\(name)>" }
        func desc(_ ns: String, _ uri: String, _ children: [String]) -> String? {
            children.isEmpty ? nil : "<rdf:Description rdf:about=\"\" xmlns:\(ns)=\"\(uri)\">\(children.joined())</rdf:Description>"
        }
        var dc: [String] = [], exif: [String] = [], iptc: [String] = [], ps: [String] = [], tiff: [String] = [], xmp: [String] = []
        if let t = m.title, !t.isEmpty { dc.append(el("dc:title", t)) }
        if let d = m.description, !d.isEmpty { dc.append(el("dc:description", d)) }
        if let o = m.orientation, o != 0 { tiff.append(el("tiff:Orientation", String(o))) }
        if let make = m.make, !make.isEmpty { tiff.append(el("tiff:Make", make)) }
        if let s = m.digitalSourceType, !s.isEmpty { iptc.append(el("Iptc4xmpExt:DigitalSourceType", s)) }
        if let k = m.keywords, !k.isEmpty {
            dc.append("<dc:subject><rdf:Seq>" + k.map { el("rdf:li", $0) }.joined() + "</rdf:Seq></dc:subject>")
        }
        if let v = m.gpsAltitude, v != 0 { exif.append(el("exif:GPSAltitude", pyFloat(v))) }
        if let v = m.gpsLatitude, v != 0 { exif.append(el("exif:GPSLatitude", pyFloat(v))) }
        if let v = m.gpsLongitude, v != 0 { exif.append(el("exif:GPSLongitude", pyFloat(v))) }
        if let v = m.gpsSpeed, v != 0 { exif.append(el("exif:GPSSpeed", pyFloat(v))) }
        if let t = m.gpsTimestamp { exif.append(el("exif:GPSTimeStamp", timestamp(t, offsetSeconds: 0))) }
        if let c = m.createDate {
            let s = timestamp(c, offsetSeconds: m.createDateOffset)
            xmp.append(el("xmp:CreateDate", s))
            ps.append(el("photoshop:DateCreated", s)) // Apple Photos reads this one
        }
        if let r = m.rating, r != 0 { xmp.append(el("xmp:Rating", String(r))) }

        let parts = [
            desc("dc", "http://purl.org/dc/elements/1.1/", dc),
            desc("exif", "http://ns.adobe.com/exif/1.0/", exif),
            desc("Iptc4xmpExt", "http://iptc.org/std/Iptc4xmpExt/2008-02-29/", iptc),
            desc("photoshop", "http://ns.adobe.com/photoshop/1.0/", ps),
            desc("tiff", "http://ns.adobe.com/tiff/1.0/", tiff),
            desc("xmp", "http://ns.adobe.com/xap/1.0/", xmp),
        ].compactMap { $0 }
        let rdf = "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\(parts.joined())</rdf:RDF>"
        return "<?xml version='1.0' encoding='utf-8'?>\n<x:xml_doc xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"\(escape(toolkit, attribute: true))\">\(rdf)</x:xml_doc>"
    }

    /// True when a sidecar at `url` may be (over)written: it's missing, empty, or one icloudpd wrote.
    public static func canWrite(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return true }
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: #"x:xmptk="([^"]*)""#, options: .regularExpression) else { return false }
        let value = text[range].dropFirst("x:xmptk=\"".count).dropLast()
        return value.hasPrefix("icloudpd")
    }

    /// Writes `<file>.xmp`. `forAdjusted` leaves the orientation out, since edited files are already upright.
    /// Returns true when a sidecar was written.
    @discardableResult
    public static func write(for asset: PhotoAsset, mediaURL: URL, forAdjusted: Bool) throws -> Bool {
        let url = URL(fileURLWithPath: mediaURL.path + ".xmp")
        guard canWrite(at: url) else { return false }
        var m = metadata(for: asset)
        if forAdjusted { m.orientation = nil }
        try Data(xml(m).utf8).write(to: url, options: .atomic)
        return true
    }
}

/// `--set-exif-datetime`: writes DateTimeOriginal into JPEGs that have none.
public enum ExifDate {
    /// "%Y:%m:%d %H:%M:%S" in the local time zone.
    public static func string(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    static func isJPEG(_ url: URL) -> Bool {
        ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }

    /// DateTimeOriginal of an image, if it has one.
    public static func dateTimeOriginal(of url: URL) -> String? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        return exif[kCGImagePropertyExifDateTimeOriginal] as? String
        #else
        return nil
        #endif
    }

    /// Writes the three date tags without re-encoding the image. Does nothing on failure.
    @discardableResult
    public static func setIfMissing(_ url: URL, date: Date) -> Bool {
        #if canImport(ImageIO)
        guard isJPEG(url), dateTimeOriginal(of: url) == nil,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) else { return false }
        let value = string(for: date)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).exif")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else { return false }
        // CopyImageSource rewrites only the metadata: the JPEG data isn't decoded or re-compressed.
        let metadata = CGImageMetadataCreateMutable()
        let tags: [(CFString, CFString)] = [
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal),
            (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized),
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime),
        ]
        for (dictionary, key) in tags {
            CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, value as CFString)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
        #else
        return false
        #endif
    }

    /// True when the local JPEG is the iCloud file after this app (or icloudpd) wrote the date into it,
    /// so the size check doesn't take it for a different photo (#380).
    public static func hasOwnDate(_ url: URL, date: Date, localSize: Int, iCloudSize: Int) -> Bool {
        guard isJPEG(url), localSize != iCloudSize, abs(localSize - iCloudSize) <= 65_536 else { return false }
        return dateTimeOriginal(of: url) == string(for: date)
    }
}
