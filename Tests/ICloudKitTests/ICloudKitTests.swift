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
    func page() throws -> PhotosService.Page {
        let json = try JSONSerialization.jsonObject(with: fixture("page.json")) as! [String: Any]
        return PhotosService.parsePage(json, previousMasters: [:])
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

    func testPlanAndDedup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let downloader = PhotoDownloader(options: DownloadOptions(directory: dir))
        let photo = try page().assets[0]
        let plan = downloader.plan(photo, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(plan.map(\.relativePath), ["2024/07/31/IMG_0001.HEIC", "2024/07/31/IMG_0001_HEVC.MOV"])

        // Nothing on disk: goes to its own name
        XCTAssertEqual(downloader.resolveDestination(plan[0])?.lastPathComponent, "IMG_0001.HEIC")

        // Same size on disk: skipped
        let target = dir.appendingPathComponent(plan[0].relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: target)
        XCTAssertNil(downloader.resolveDestination(plan[0]))

        // Different size: gets the size suffix
        try Data(count: 10).write(to: target)
        XCTAssertEqual(downloader.resolveDestination(plan[0])?.lastPathComponent, "IMG_0001-1000.HEIC")

        let noVideos = PhotoDownloader(options: DownloadOptions(directory: dir, includeVideos: false, includeLivePhotoVideos: false))
        XCTAssertEqual(noVideos.plan(photo).count, 1)
        XCTAssertEqual(noVideos.plan(try page().assets[2]).count, 0)
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
