import XCTest
@testable import ICloudKit

private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func hexBytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var chars = Array(hex)
    if chars.count % 2 == 1 { chars.insert("0", at: 0) }
    var i = 0
    while i < chars.count { out.append(UInt8(String(chars[i...i + 1]), radix: 16)!); i += 2 }
    return out
}

final class BigUIntTests: XCTestCase {
    func testAgainstPythonVectors() throws {
        let root = try JSONSerialization.jsonObject(with: fixture("vectors.json")) as! [String: Any]
        let big = root["big"] as! [[String: String]]
        let N = SRPClient.N
        for v in big {
            let x = BigUInt(hex: v["x"]!)!
            let y = BigUInt(hex: v["y"]!)!
            if v["q"]!.isEmpty {
                XCTAssertEqual(x.power(y, modulus: N).hexString, v["p"]!)
            } else {
                let (q, r) = x.quotientAndRemainder(dividingBy: y)
                XCTAssertEqual(q.hexString, v["q"]!)
                XCTAssertEqual(r.hexString, v["r"]!)
                XCTAssertEqual((x * y).hexString, v["p"]!)
                XCTAssertEqual(q * y + r, x)
            }
        }
    }

    func testSerialization() {
        XCTAssertEqual(BigUInt(bytes: [0, 0, 1, 2]).serialize(), [1, 2])
        XCTAssertEqual(BigUInt.zero.serialize(), [])
        XCTAssertEqual(BigUInt(258).serialize(paddedTo: 4), [0, 0, 1, 2])
        XCTAssertEqual(BigUInt(10) - BigUInt(3), BigUInt(7))
    }
}

final class HashingTests: XCTestCase {
    func testSHA256() {
        let digest = Hashing.sha256(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Hashing.sha256(Array(String(repeating: "a", count: 1000).utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(long, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    func testPBKDF2() {
        // RFC 7914 section 11 test vector for PBKDF2-HMAC-SHA256
        let key = Hashing.pbkdf2SHA256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, keyLength: 64)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }
}

final class SRPTests: XCTestCase {
    /// Vectors made with python `srp` configured exactly as icloudpd configures it.
    func testMatchesIcloudpd() throws {
        let root = try JSONSerialization.jsonObject(with: fixture("vectors.json")) as! [String: Any]
        for v in root["srp"] as! [[String: Any]] {
            let salt = Array(Data(base64Encoded: v["salt"] as! String)!)
            let key = try SRPClient.derivePassword("correct horse battery staple", protocol: v["protocol"] as! String,
                                                   salt: salt, iterations: v["iterations"] as! Int)
            XCTAssertEqual(key, hexBytes(v["passwordKey"] as! String))

            let client = SRPClient(accountName: "user@example.com", privateKey: hexBytes(v["a"] as! String))
            XCTAssertEqual(Data(client.publicKey).base64EncodedString(), v["A"] as! String)

            let B = Array(Data(base64Encoded: v["B"] as! String)!)
            let (m1, m2) = try client.processChallenge(passwordKey: key, salt: salt, serverPublicKey: B)
            XCTAssertEqual(Data(m1).base64EncodedString(), v["m1"] as! String)
            XCTAssertEqual(Data(m2).base64EncodedString(), v["m2"] as! String)
        }
    }
}

final class PhotosParsingTests: XCTestCase {
    func page() throws -> AssetPager.Page {
        let json = try JSONSerialization.jsonObject(with: fixture("page.json")) as! [String: Any]
        return AssetPager.parsePage(json, previousMasters: [:])
    }

    func testPageKeepsEveryAssetOfASharedMaster() throws {
        let page = try page()
        XCTAssertEqual(page.assetCount, 4) // the offset advances by assets, including the skipped one
        XCTAssertEqual(page.assets.count, 3)
    }

    func testAssetFields() throws {
        let assets = try page().assets
        let photo = assets[0]
        XCTAssertEqual(photo.filename, "IMG_0001.HEIC")
        XCTAssertEqual(photo.itemType, .image)
        XCTAssertTrue(photo.isLivePhoto)
        XCTAssertEqual(photo.versions[.original]?.size, 1000)
        XCTAssertNotNil(photo.versions[.original]?.url)
        XCTAssertEqual(photo.createdDate, Date(timeIntervalSince1970: 1_722_427_200))

        let video = assets[2]
        XCTAssertEqual(video.filename, "clip_1.mov")
        XCTAssertEqual(video.itemType, .movie)
        XCTAssertTrue(video.isScreenshot)
    }

    func engine(_ dir: URL, _ edit: (inout SyncConfiguration) -> Void = { _ in }) throws -> SyncEngine {
        var config = SyncConfiguration(directoryPath: dir.path)
        edit(&config)
        return try SyncEngine(configuration: config, timeZone: TimeZone(identifier: "UTC")!) { _ in }
    }

    func testPlanAndDedup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = try engine(dir)
        let photo = try page().assets[0]
        let plan = engine.plan(photo).files
        XCTAssertEqual(plan.map { engine.relative($0.url) }, ["2024/07/31/IMG_0001.HEIC", "2024/07/31/IMG_0001_HEVC.MOV"])

        // Nothing on disk: goes to its own name
        XCTAssertEqual(engine.resolve(plan[0], asset: photo).url?.lastPathComponent, "IMG_0001.HEIC")
        engine.reservationsForTests.release(plan[0].url)

        // Same size on disk: already there
        let target = plan[0].url
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: target)
        XCTAssertNil(engine.resolve(plan[0], asset: photo).url)

        // Different size: gets the size suffix
        try Data(count: 10).write(to: target)
        let dedup = engine.resolve(plan[0], asset: photo).url
        XCTAssertEqual(dedup?.lastPathComponent, "IMG_0001-1000.HEIC")
        // ...and while that download runs, another photo with the same name doesn't take it
        XCTAssertNil(engine.resolve(plan[0], asset: photo).url)

        let noLive = try self.engine(dir) { $0.skipLivePhotos = true }
        XCTAssertEqual(noLive.plan(photo).files.count, 1)
        let noVideos = try self.engine(dir) { $0.skipVideos = true }
        XCTAssertFalse(noVideos.passes(try page().assets[2]))
        XCTAssertTrue(noVideos.passes(photo))
    }

    func testSizesAndPolicies() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let photo = try page().assets[0]
        // medium doesn't exist: falls back to original unless forced
        let medium = try engine(dir) { $0.sizes = [.medium]; $0.skipLivePhotos = true }
        XCTAssertEqual(medium.plan(photo).files.map(\.url.lastPathComponent), ["IMG_0001.HEIC"])
        let forced = try engine(dir) { $0.sizes = [.medium]; $0.forceSize = true; $0.skipLivePhotos = true }
        XCTAssertEqual(forced.plan(photo).files.count, 0)
        XCTAssertEqual(forced.plan(photo).missingSizes, ["medium"])

        let id7 = try engine(dir) { $0.fileMatchPolicy = .nameID7; $0.folderStructure = "none"; $0.livePhotoMovFilenamePolicy = .original }
        XCTAssertEqual(id7.plan(photo).files.map(\.url.lastPathComponent), ["IMG_0001_TTE=.HEIC", "IMG_0001_TTE=.MOV"])
        XCTAssertEqual(id7.relative(id7.plan(photo).files[1].url), "IMG_0001_TTE=.MOV")

        let liveDir = try engine(dir) { $0.livePhotoDirectoryPath = dir.appendingPathComponent("live").path; $0.livePhotoSize = .original }
        XCTAssertTrue(liveDir.plan(photo).files[1].url.path.contains("/live/2024/07/31/"))
    }

    func testFilters() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets = try page().assets
        let now = Date(timeIntervalSince1970: 1_722_427_200 + 10 * 86_400)
        XCTAssertFalse(try engine(dir) { $0.skipScreenshots = true }.passes(assets[2], now: now))
        XCTAssertFalse(try engine(dir) { $0.skipCreatedBefore = .daysAgo(5) }.passes(assets[0], now: now))
        XCTAssertTrue(try engine(dir) { $0.skipCreatedBefore = .daysAgo(20) }.passes(assets[0], now: now))
        XCTAssertFalse(try engine(dir) { $0.skipCreatedAfter = DateBound.parse("2024-01-01") }.passes(assets[0], now: now))
        XCTAssertFalse(try engine(dir) { $0.excludeFilenames = ["img_00*.heic"] }.passes(assets[0], now: now))
        XCTAssertTrue(try engine(dir) { $0.excludeFilenames = ["IMG_9*"] }.passes(assets[0], now: now))
        XCTAssertFalse(try engine(dir) { $0.skipPhotos = true }.passes(assets[0], now: now))
    }

    func testFolderFormat() throws {
        let date = Date(timeIntervalSince1970: 1_722_427_200) // 2024-07-31 12:00 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(try FolderFormat("{:%Y/%m/%d}").path(for: date, timeZone: utc), "2024/07/31")
        XCTAssertEqual(try FolderFormat("photos/{:%Y}/{:%m-%B}").path(for: date, timeZone: utc), "photos/2024/07-July")
        XCTAssertEqual(try FolderFormat("none").path(for: date, timeZone: utc), "")
        XCTAssertThrowsError(try FolderFormat("{%Y}"))
        XCTAssertEqual(DateBound.parse("20d"), .daysAgo(20))
        XCTAssertNotNil(DateBound.parse("2025-01-02T10:00:00+02:00"))
        XCTAssertNil(DateBound.parse("yesterday"))
    }

    func testDisambiguate() {
        let url = URL(string: "https://x")!
        let jpeg = AssetVersion(size: 1, url: url, type: "public.jpeg", checksum: "")
        let heic = AssetVersion(size: 2, url: url, type: "public.heic", checksum: "")
        let (versions, overrides) = FilenamePolicy.disambiguate(
            versions: [.original: jpeg, .adjusted: jpeg], sizes: [.original, .adjusted], base: "IMG.JPG", isImage: true, livePolicy: .suffix)
        XCTAssertEqual(versions.count, 2)
        XCTAssertEqual(overrides[.adjusted], "IMG-adjusted.JPG")
        let (alt, _) = FilenamePolicy.disambiguate(versions: [.original: heic], sizes: [.alternative], base: "IMG.HEIC", isImage: true, livePolicy: .suffix)
        XCTAssertEqual(alt[.alternative], heic)
    }

    func testXMP() throws {
        let photo = try page().assets[0]
        var m = XMPSidecar.metadata(for: photo)
        XCTAssertEqual(m.createDate, Date(timeIntervalSince1970: 1_722_427_200))
        m.title = "Beach & sun"
        m.keywords = ["a", "b"]
        m.rating = 5
        m.gpsLatitude = 37.0
        let xml = XMPSidecar.xml(m, toolkit: "icloudpd-swift test")
        XCTAssertTrue(xml.hasPrefix("<?xml version='1.0' encoding='utf-8'?>\n<x:xml_doc xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"icloudpd-swift test\">"))
        XCTAssertTrue(xml.contains("<dc:title>Beach &amp; sun</dc:title>"))
        XCTAssertTrue(xml.contains("<dc:subject><rdf:Seq><rdf:li>a</rdf:li><rdf:li>b</rdf:li></rdf:Seq></dc:subject>"))
        XCTAssertTrue(xml.contains("<exif:GPSLatitude>37.0</exif:GPSLatitude>"))
        XCTAssertTrue(xml.contains("<xmp:CreateDate>2024-07-31T12:00:00+0000</xmp:CreateDate>"))
        XCTAssertTrue(xml.contains("<xmp:Rating>5</xmp:Rating>"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let foreign = dir.appendingPathComponent("a.JPG.xmp")
        try Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"Adobe XMP\"/>".utf8).write(to: foreign)
        XCTAssertFalse(XMPSidecar.canWrite(at: foreign))
        try Data(xml.utf8).write(to: foreign)
        XCTAssertTrue(XMPSidecar.canWrite(at: foreign))
    }

    func testDeleteListParsing() throws {
        let list = try DeleteList(contents: "# comment\nIMG_0001.HEIC\t1000\t2024-07-31T12:00:30Z\n\nclip_1.mov\t7\t1722427200\n")
        XCTAssertEqual(list.entries.count, 2)
        XCTAssertEqual(list.entries[0].line, 2)
        XCTAssertThrowsError(try DeleteList(contents: "IMG.HEIC\t12\n"))
        XCTAssertNoThrow(try DeleteList(contents: "IMG.HEIC\t12\n", allowUndated: true))
        XCTAssertThrowsError(try DeleteList(contents: "IMG.HEIC\tabc\t1722427200\n"))
        let photo = try page().assets[0]
        XCTAssertTrue(DeleteList.matches(list.entries[0], photo))
    }

    func testPruneTracker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appendingPathComponent("gone.JPG"))
        try Data("y".utf8).write(to: dir.appendingPathComponent("kept.JPG"))
        var first = PruneTracker(directory: dir, library: "PrimarySync", fileManager: .default)
        first.record(assetID: "A", paths: ["gone.JPG"])
        first.record(assetID: "B", paths: ["kept.JPG"])
        first.save()
        var second = PruneTracker(directory: dir, library: "PrimarySync", fileManager: .default)
        second.record(assetID: "B", paths: ["kept.JPG"])
        var pruned: [String] = []
        XCTAssertEqual(second.pruneOrphans(dryRun: false) { pruned.append($0) }, 1)
        XCTAssertEqual(pruned, ["gone.JPG"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("gone.JPG").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("kept.JPG").path))
    }

    func testFilenames() {
        XCTAssertEqual(FilenamePolicy.livePhotoVideoName(for: "IMG_1.JPG"), "IMG_1.MOV")
        XCTAssertEqual(FilenamePolicy.livePhotoVideoName(for: "IMG_1.heic"), "IMG_1_HEVC.MOV")
        XCTAssertEqual(FilenamePolicy.dedupName("a.b.JPG", size: 5), "a.b-5.JPG")
        let v = AssetVersion(size: 1, url: URL(string: "https://x")!, type: "public.jpeg", checksum: "")
        XCTAssertEqual(FilenamePolicy.versionFilename(base: "IMG.HEIC", version: v, size: .original, isImage: true), "IMG.JPG")
        XCTAssertEqual(FilenamePolicy.versionFilename(base: "IMG.HEIC", version: v, size: .medium, isImage: true), "IMG-medium.JPG")
    }
}

final class AuthParsingTests: XCTestCase {
    func testTrustedPhones() throws {
        let html = String(decoding: try fixture("auth.html"), as: UTF8.self)
        let phones = TrustedPhoneParser.parse(html: html)
        XCTAssertEqual(phones.map(\.id), [1, 2])
        XCTAssertEqual(phones[0].obfuscatedNumber, "(***) ***-**12")
    }

    func testErrorBodies() {
        XCTAssertThrowsError(try HTTPClient.checkBody(["hasError": true, "service_errors": [["code": "-21669", "message": "Wrong"]]]))
        XCTAssertThrowsError(try HTTPClient.checkBody(["serverErrorCode": "ZONE_NOT_FOUND", "reason": "no zone"])) { error in
            guard case ICloudError.serviceNotActivated = error else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try HTTPClient.checkBody(["records": []]))
        XCTAssertNoThrow(try HTTPClient.checkBody(["success": true, "error": "ignored"]))
    }

    func testCookieJar() {
        let jar = CookieJar(cookies: [
            StoredCookie(name: "X-APPLE-WEBAUTH-TOKEN", value: "t", domain: ".icloud.com", path: "/", expires: nil, secure: true),
            StoredCookie(name: "aasp", value: "a", domain: "idmsa.apple.com", path: "/", expires: nil, secure: true),
            StoredCookie(name: "old", value: "o", domain: ".icloud.com", path: "/", expires: Date(timeIntervalSince1970: 0), secure: false),
        ])
        XCTAssertEqual(jar.header(for: URL(string: "https://p123-ckdatabasews.icloud.com/database")!), "X-APPLE-WEBAUTH-TOKEN=t")
        XCTAssertEqual(jar.header(for: URL(string: "https://idmsa.apple.com/appleauth/auth")!), "aasp=a")
        XCTAssertNil(jar.header(for: URL(string: "http://www.icloud.com/")!))
    }
}
