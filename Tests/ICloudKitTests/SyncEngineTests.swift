import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ICloudKit

/// A fake iCloud Photos server: CloudKit queries, deletes and file downloads with Range support.
final class FakeICloud: URLProtocol {
    struct Photo {
        var id: String
        var name: String
        var date: Double // ms
        var data: Data
        var deleted = false
        var live: Data?
    }

    nonisolated(unsafe) static var photos: [Photo] = []
    nonisolated(unsafe) static var deleteRequests: [String] = []
    nonisolated(unsafe) static var rangeRequests = 0
    /// When set, the first download of each file is cut off after this many bytes.
    nonisolated(unsafe) static var truncateFirstDownload: Int?
    nonisolated(unsafe) static var truncated = Set<String>()
    /// When set, a delete request with several photos is refused as a whole, the way an atomic one is.
    nonisolated(unsafe) static var refuseBatchDeletes = false
    nonisolated(unsafe) static var modifyRequests = 0
    /// How many delete requests are answered 503 before iCloud accepts them again (-1: all of them).
    nonisolated(unsafe) static var throttledModifies = 0
    nonisolated(unsafe) static var listingRequests = 0
    nonisolated(unsafe) static var zoneListRequests = 0
    /// Extra library zones besides PrimarySync, with the indexing state each one reports.
    nonisolated(unsafe) static var zones: [String: String] = [:]
    /// User albums and folders by parent folder id ("" is the top level).
    nonisolated(unsafe) static var albumTree: [String: [(id: String, name: String, isFolder: Bool)]] = [:]
    static let lock = NSLock()

    static func reset(_ photos: [Photo]) {
        lock.lock(); defer { lock.unlock() }
        self.photos = photos
        deleteRequests = []
        rangeRequests = 0
        truncateFirstDownload = nil
        truncated = []
        refuseBatchDeletes = false
        listingRequests = 0
        zoneListRequests = 0
        zones = [:]
        albumTree = [:]
        modifyRequests = 0
        throttledModifies = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fake.icloud.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Collected under the lock, sent after it is released (corelibs runs protocol callbacks on its own queue).
    var pending: (Int, Data, [String: String])?

    func respond(_ status: Int, json: Any? = nil, data: Data? = nil, headers: [String: String] = [:]) {
        var headers = headers
        var body = data ?? Data()
        if let json {
            body = try! JSONSerialization.data(withJSONObject: json)
            headers["Content-Type"] = "application/json"
        }
        pending = (status, body, headers)
    }

    func send() {
        guard let (status, body, headers) = pending else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    static func records(for photo: Photo) -> [[String: Any]] {
        var master: [String: Any] = [
            "filenameEnc": ["type": "STRING", "value": photo.name],
            "itemType": ["value": photo.name.hasSuffix(".MOV") ? "com.apple.quicktime-movie" : "public.jpeg"],
            "resOriginalRes": ["value": ["size": photo.data.count, "downloadURL": "https://fake.icloud.test/file/\(photo.id)/${f}", "fileChecksum": "c"]],
            "resOriginalFileType": ["value": photo.name.hasSuffix(".MOV") ? "com.apple.quicktime-movie" : "public.jpeg"],
        ]
        if let live = photo.live {
            master["resOriginalVidComplRes"] = ["value": ["size": live.count, "downloadURL": "https://fake.icloud.test/file/\(photo.id)-live/${f}", "fileChecksum": "l"]]
            master["resOriginalVidComplFileType"] = ["value": "com.apple.quicktime-movie"]
        }
        return [
            ["recordName": "M-\(photo.id)", "recordType": "CPLMaster", "fields": master],
            ["recordName": "A-\(photo.id)", "recordType": "CPLAsset", "recordChangeTag": "t1",
             "fields": ["masterRef": ["value": ["recordName": "M-\(photo.id)"]], "assetDate": ["value": photo.date]]],
        ]
    }

    override func startLoading() {
        FakeICloud.lock.lock()
        handle()
        FakeICloud.lock.unlock()
        send()
    }

    func handle() {
        let url = request.url!
        let path = url.path

        if path.hasPrefix("/file/") {
            let id = path.split(separator: "/")[1]
            let isLive = id.hasSuffix("-live")
            let baseID = isLive ? String(id.dropLast(5)) : String(id)
            guard let photo = FakeICloud.photos.first(where: { $0.id == baseID }) else { return respond(404) }
            let data = isLive ? photo.live! : photo.data
            var start = 0
            if let range = request.value(forHTTPHeaderField: "Range"),
               let n = Int(range.dropFirst("bytes=".count).dropLast()) {
                FakeICloud.rangeRequests += 1
                start = n
                if start >= data.count { return respond(416) }
            }
            var chunk = data.subdata(in: start..<data.count)
            if let cut = FakeICloud.truncateFirstDownload, !FakeICloud.truncated.contains(String(id)) {
                FakeICloud.truncated.insert(String(id))
                chunk = chunk.prefix(cut)
            }
            return respond(start > 0 ? 206 : 200, data: chunk,
                           headers: start > 0 ? ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"] : [:])
        }

        let body = FakeICloud.body(of: request)
        if path.hasSuffix("/records/modify") {
            let ops = body["operations"] as? [[String: Any]] ?? []
            FakeICloud.modifyRequests += 1
            if FakeICloud.throttledModifies != 0 {
                FakeICloud.throttledModifies -= FakeICloud.throttledModifies > 0 ? 1 : 0
                return respond(503, data: Data("Service Unavailable".utf8), headers: ["Content-Type": "text/html"])
            }
            if FakeICloud.refuseBatchDeletes, ops.count > 1 {
                return respond(200, json: ["records": ops.map { op in
                    ["recordName": (op["record"] as? [String: Any])?["recordName"] ?? "", "serverErrorCode": "ATOMIC_ERROR"]
                }])
            }
            for op in ops {
                let record = op["record"] as? [String: Any] ?? [:]
                let name = record["recordName"] as? String ?? ""
                FakeICloud.deleteRequests.append(name)
                if let i = FakeICloud.photos.firstIndex(where: { "A-\($0.id)" == name }) { FakeICloud.photos[i].deleted = true }
            }
            return respond(200, json: ["records": []])
        }
        if path.hasSuffix("/zones/list") {
            FakeICloud.zoneListRequests += 1
            let names = path.contains("/private/") ? ["PrimarySync"] + FakeICloud.zones.keys.sorted().filter { $0 != "PrimarySync" } : []
            return respond(200, json: ["zones": names.map { ["zoneID": ["zoneName": $0]] }])
        }
        if path.hasSuffix("/internal/records/query/batch") {
            let live = FakeICloud.photos.filter { !$0.deleted }.count
            return respond(200, json: ["batch": [["records": [["fields": ["itemCount": ["value": live]]]]]]])
        }
        if path.hasSuffix("/records/query") {
            let query = body["query"] as? [String: Any] ?? [:]
            let type = query["recordType"] as? String
            if type == "CheckIndexingState" {
                let zone = (body["zoneID"] as? [String: Any])?["zoneName"] as? String ?? ""
                return respond(200, json: ["records": [["fields": ["state": ["value": FakeICloud.zones[zone] ?? "FINISHED"]]]]])
            }
            let filters = query["filterBy"] as? [[String: Any]] ?? []
            if type == "CPLAlbumByPositionLive" {
                let parent = filters.first { $0["fieldName"] as? String == "parentId" }
                    .flatMap { ($0["fieldValue"] as? [String: Any])?["value"] as? String } ?? ""
                return respond(200, json: ["records": (FakeICloud.albumTree[parent] ?? []).map { item in
                    ["recordName": item.id, "fields": [
                        "albumNameEnc": ["value": Data(item.name.utf8).base64EncodedString()],
                        "albumType": ["value": item.isFolder ? 3 : 0],
                    ]]
                }])
            }
            let start = filters.first { $0["fieldName"] as? String == "startRank" }
                .flatMap { ($0["fieldValue"] as? [String: Any])?["value"] as? Int } ?? 0
            let limit = (body["resultsLimit"] as? Int ?? 200) / 2
            FakeICloud.listingRequests += 1
            let deletedList = type == "CPLAssetAndMasterDeletedByExpungedDate"
            // newest first, like iCloud
            let list = FakeICloud.photos.filter { $0.deleted == deletedList }.sorted { $0.date > $1.date }
            let page = list.dropFirst(start).prefix(limit)
            return respond(200, json: ["records": page.flatMap(FakeICloud.records)])
        }
        respond(404)
    }
}

final class SyncEngineTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        HTTPClient.protocolClassesForTesting = [FakeICloud.self]
        PhotoLibrary.indexingRetryDelay = 1_000
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let day = 86_400_000.0
        FakeICloud.reset((0..<7).map { i in
            FakeICloud.Photo(id: "p\(i)", name: "IMG_000\(i).JPG", date: 1_722_427_200_000 - Double(i) * day,
                             data: Data(repeating: UInt8(i), count: 1000 + i), live: i == 0 ? Data(repeating: 9, count: 300) : nil)
        })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func service() -> PhotosService {
        let http = HTTPClient(homeEndpoint: "https://www.icloud.com", store: nil)
        let params = PhotosService.query(dsid: "1")
        let endpoint = PhotosService.endpoint(serviceRoot: "https://fake.icloud.test", libraryType: "private")
        let library = PhotoLibrary(http: http, endpoint: endpoint, params: params, zoneID: ["zoneName": "PrimarySync"], libraryType: .private)
        return PhotosService(http: http, serviceRoot: "https://fake.icloud.test", params: params, ignoreIndexingState: false, primary: library)
    }

    final class Events: @unchecked Sendable {
        let lock = NSLock()
        var all: [SyncEvent] = []
        func add(_ e: SyncEvent) { lock.lock(); all.append(e); lock.unlock() }
        var logs: [String] { all.compactMap { if case .log(_, let m) = $0 { return m } else { return nil } } }
    }

    func run(_ edit: (inout SyncConfiguration) -> Void = { _ in }) async throws -> (SyncSummary, Events) {
        var config = SyncConfiguration(directoryPath: dir.path)
        config.folderStructure = "none"
        edit(&config)
        let events = Events()
        let engine = try SyncEngine(configuration: config, timeZone: TimeZone(identifier: "UTC")!) { events.add($0) }
        return (try await engine.run(photos: service()), events)
    }

    func files() -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".icloudpd-swift") }.sorted()
    }

    func testDownloadsEverythingThenSkips() async throws {
        let (first, _) = try await run()
        XCTAssertEqual(first.filesDownloaded, 8) // 7 photos + 1 Live Photo video
        XCTAssertEqual(files().count, 8)
        XCTAssertTrue(files().contains("IMG_0000.MOV"))
        let data = try Data(contentsOf: dir.appendingPathComponent("IMG_0003.JPG"))
        XCTAssertEqual(data, Data(repeating: 3, count: 1003))
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("IMG_0003.JPG").path)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, 1_722_427_200 - 3 * 86_400, accuracy: 1)

        let (second, _) = try await run()
        XCTAssertEqual(second.filesDownloaded, 0)
        XCTAssertEqual(second.filesExisting, 7)
    }

    func testDryRunWritesNothing() async throws {
        let (summary, events) = try await run { $0.dryRun = true; $0.keepICloudRecentDays = 0 }
        XCTAssertEqual(summary.filesDownloaded, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(events.all.filter { if case .wouldDownload = $0 { return true } else { return false } }.count, 8)
        XCTAssertTrue(FakeICloud.deleteRequests.isEmpty)
    }

    func testRecentAndUntilFound() async throws {
        let (recent, _) = try await run { $0.recent = 2 }
        XCTAssertEqual(recent.assetsSeen, 2)
        XCTAssertEqual(files(), ["IMG_0000.JPG", "IMG_0000.MOV", "IMG_0001.JPG"])

        // A new photo appears at the top; until-found 2 stops after the two known ones.
        FakeICloud.photos.append(.init(id: "new", name: "IMG_9999.JPG", date: 1_722_427_200_000 + 1000, data: Data(count: 5)))
        let (until, _) = try await run { $0.untilFound = 2 }
        XCTAssertTrue(until.stoppedByUntilFound)
        XCTAssertEqual(until.filesDownloaded, 1)
        XCTAssertEqual(until.assetsSeen, 3)
    }

    func testResumesPartialDownload() async throws {
        FakeICloud.truncateFirstDownload = 400
        let (summary, _) = try await run { $0.recent = 1; $0.skipLivePhotos = true }
        XCTAssertEqual(summary.filesDownloaded, 1)
        XCTAssertGreaterThan(FakeICloud.rangeRequests, 0)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("IMG_0000.JPG")), Data(repeating: 0, count: 1000))
        XCTAssertFalse(files().contains { $0.hasSuffix(".part") })
    }

    func testMoveModeDeletesOldPhotosFromICloud() async throws {
        // Keep 0 days: every photo is old enough, so each is deleted once it's safely on disk.
        let (summary, _) = try await run { $0.keepICloudRecentDays = 0 }
        XCTAssertEqual(summary.deletedFromICloud, 7)
        XCTAssertEqual(FakeICloud.deleteRequests.count, 7)
        XCTAssertEqual(files().count, 8) // everything was downloaded before deleting
        XCTAssertEqual(FakeICloud.modifyRequests, 1) // the page's deletions go in one request
    }

    func testRefusedBatchDeleteFallsBackToOneAtATime() async throws {
        FakeICloud.refuseBatchDeletes = true
        let (summary, events) = try await run { $0.keepICloudRecentDays = 0 }
        XCTAssertEqual(summary.deletedFromICloud, 7)
        XCTAssertEqual(FakeICloud.deleteRequests.count, 7)
        XCTAssertEqual(FakeICloud.modifyRequests, 8) // the refused batch, then each photo
        XCTAssertEqual(events.all.filter { if case .deletedFromICloud = $0 { return true } else { return false } }.count, 7)
    }

    func testThrottledDeleteIsRetried() async throws {
        SyncEngine.throttleDelay = 1_000
        FakeICloud.throttledModifies = 2
        let (summary, _) = try await run { $0.keepICloudRecentDays = 0 }
        XCTAssertEqual(summary.deletedFromICloud, 7)
        XCTAssertFalse(summary.deletesPausedByThrottling)
        XCTAssertEqual(FakeICloud.modifyRequests, 3) // two 503s, then the batch goes through
    }

    func testKeptThrottlingStopsDeletingButNotDownloading() async throws {
        SyncEngine.throttleDelay = 1_000
        // Three pages, so there are later pages that could still try to delete.
        FakeICloud.reset((0..<250).map { i in
            FakeICloud.Photo(id: "p\(i)", name: String(format: "IMG_%04d.JPG", i), date: 1_722_427_200_000 - Double(i) * 1000,
                             data: Data(repeating: UInt8(i % 251), count: 20 + i))
        })
        FakeICloud.throttledModifies = -1
        let (summary, events) = try await run { $0.keepICloudRecentDays = 0 }
        XCTAssertEqual(summary.assetsSeen, 250)
        XCTAssertEqual(summary.filesDownloaded, 250)
        XCTAssertEqual(summary.filesFailed, 0)
        XCTAssertEqual(summary.deletedFromICloud, 0)
        XCTAssertTrue(summary.deletesPausedByThrottling)
        XCTAssertEqual(FakeICloud.modifyRequests, 1 + SyncEngine.throttleRetries) // given up after one request's retries
        XCTAssertTrue(FakeICloud.photos.allSatisfy { !$0.deleted })
        XCTAssertTrue(events.logs.contains { $0.contains("stops removing photos from iCloud") })
    }

    func testDeleteAfterDownloadOnlyDeletesNewDownloads() async throws {
        _ = try await run { $0.recent = 2 }
        let (summary, _) = try await run { $0.deleteAfterDownload = true }
        XCTAssertEqual(summary.deletedFromICloud, 5)
        XCTAssertFalse(FakeICloud.deleteRequests.contains("A-p0"))
    }

    func testAutoDeleteRemovesLocalCopiesOfDeletedPhotos() async throws {
        _ = try await run { $0.xmpSidecar = true }
        XCTAssertTrue(files().contains("IMG_0002.JPG.xmp"))
        FakeICloud.photos[2].deleted = true
        let (summary, _) = try await run { $0.autoDelete = true }
        XCTAssertEqual(summary.deletedLocally, 2) // the photo and its sidecar
        XCTAssertFalse(files().contains("IMG_0002.JPG"))
    }

    func testPruneMovesOrphansAside() async throws {
        _ = try await run { $0.pruneOrphans = true }
        FakeICloud.photos.removeAll { $0.id == "p4" }
        let (summary, _) = try await run { $0.pruneOrphans = true }
        XCTAssertEqual(summary.pruned, 1)
        XCTAssertFalse(files().contains("IMG_0004.JPG"))
        let pruned = try FileManager.default.subpathsOfDirectory(atPath: dir.appendingPathComponent(".icloudpd-swift-pruned").path)
        XCTAssertTrue(pruned.contains { $0.hasSuffix("IMG_0004.JPG") })
    }

    func testSameNameDifferentPhotosBothKept() async throws {
        FakeICloud.reset([
            .init(id: "a", name: "IMG_1.JPG", date: 2_000, data: Data(repeating: 1, count: 10)),
            .init(id: "b", name: "IMG_1.JPG", date: 1_000, data: Data(repeating: 2, count: 20)),
        ])
        let (summary, _) = try await run { $0.concurrentDownloads = 8 }
        XCTAssertEqual(summary.filesDownloaded, 2)
        // Whichever download claims the name first keeps it; the other gets its size added.
        XCTAssertEqual(files().count, 2)
        XCTAssertTrue(files().contains("IMG_1.JPG"))
        XCTAssertTrue(files().contains("IMG_1-20.JPG") || files().contains("IMG_1-10.JPG"))
    }

    /// 250 photos are three pages of the listing: downloads go on from one page into the next.
    func testDownloadsAcrossPages() async throws {
        FakeICloud.reset((0..<250).map { i in
            FakeICloud.Photo(id: "p\(i)", name: String(format: "IMG_%04d.JPG", i), date: 1_722_427_200_000 - Double(i) * 1000,
                             data: Data(repeating: UInt8(i % 251), count: 20 + i))
        })
        let (first, events) = try await run { $0.concurrentDownloads = 8 }
        XCTAssertEqual(first.assetsSeen, 250)
        XCTAssertEqual(first.filesDownloaded, 250)
        XCTAssertEqual(files().count, 250)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("IMG_0249.JPG")), Data(repeating: 249, count: 269))
        // Progress only ever moves forward, and ends on the last photo.
        let progress = events.all.compactMap { if case .progress(let n) = $0 { return n } else { return nil } }
        XCTAssertEqual(progress, progress.sorted())
        XCTAssertEqual(progress.last, 250)

        // One new photo on top of 250 known ones: until-found stops on the first page.
        FakeICloud.photos.append(.init(id: "new", name: "IMG_9999.JPG", date: 1_722_427_200_000 + 1000, data: Data(count: 5)))
        FakeICloud.listingRequests = 0
        let (until, _) = try await run { $0.untilFound = 3 }
        XCTAssertEqual(FakeICloud.listingRequests, 1) // it stops on the first page without asking for the next
        XCTAssertTrue(until.stoppedByUntilFound)
        XCTAssertEqual(until.filesDownloaded, 1)
        XCTAssertEqual(until.assetsSeen, 4)

        // Move mode deletes as it goes, which shifts the listing: no photo may be skipped.
        let (move, _) = try await run { $0.keepICloudRecentDays = 0 }
        XCTAssertEqual(move.assetsSeen, 251)
        XCTAssertEqual(move.deletedFromICloud, 251)
        XCTAssertEqual(Set(FakeICloud.deleteRequests).count, 251)
    }

    /// The session files are written when a response changes the session, not on every response.
    func testSessionIsSavedOnlyWhenItChanges() async throws {
        let store = SessionStore(directory: dir.appendingPathComponent("session"))
        let http = HTTPClient(homeEndpoint: "https://www.icloud.com", store: store)
        let sessionFile = store.directory.appendingPathComponent("session.json")
        let url = URL(string: "https://fake.icloud.test/file/p1/x")!

        _ = try await http.downloadFile(url, to: dir.appendingPathComponent("a.part"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))

        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["scnt": "abc", "Set-Cookie": "k=v; Path=/"])!
        http.absorb(response, url: url)
        XCTAssertEqual(store.load().0.scnt, "abc")
        XCTAssertEqual(store.load().1.map(\.name), ["k"])

        try FileManager.default.removeItem(at: sessionFile)
        http.absorb(response, url: url) // the same again changes nothing
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
    }

    /// Bigger than the amount a download may hold unwritten, so it is paused and resumed on the way.
    func testLargeFileIsWrittenWhole() async throws {
        var big = Data(count: 3 * DownloadRouter.pauseAbove + 12_345)
        for i in stride(from: 0, to: big.count, by: 4_099) { big[i] = UInt8(i % 251) }
        FakeICloud.reset([.init(id: "v", name: "IMG_0001.MOV", date: 1_722_427_200_000, data: big)])
        let (summary, _) = try await run()
        XCTAssertEqual(summary.filesDownloaded, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("IMG_0001.MOV")), big)
    }

    /// Folders are walked a level at a time, several at once; the albums come out in the same order.
    func testAlbumsInsideFolders() async throws {
        FakeICloud.albumTree = [
            "": [("f1", "Trips", true), ("a", "Family", false), ("f2", "Work", true)]
                + (0..<6).map { ("e\($0)", "Empty \($0)", true) },
            "f1": [("b", "Rome", false), ("f3", "2024", true)],
            "f2": [("c", "Offsite", false)],
            "f3": [("d", "Oslo", false)],
        ]
        let albums = try await service().primary.albums().filter { $0.kind == .user }.map(\.name)
        XCTAssertEqual(albums, ["Family", "Trips/Rome", "Work/Offsite", "Trips/2024/Oslo"])
    }

    /// A library list is reused, but not one that left out a library that was still indexing.
    func testLibraryListIsOnlyKeptWhenComplete() async throws {
        FakeICloud.zones = ["Other": "RUNNING"]
        let photos = service()
        let before = try await photos.libraries(.private).map(\.name)
        XCTAssertEqual(before, ["PrimarySync"])

        FakeICloud.zones = ["Other": "FINISHED"]
        let other = try await photos.library(named: "Other")
        XCTAssertEqual(other.name, "Other")

        // Now that every library opened, looking one up again doesn't ask iCloud.
        let requests = FakeICloud.zoneListRequests
        _ = try await photos.library(named: "Other")
        XCTAssertEqual(FakeICloud.zoneListRequests, requests)
    }

    /// A library that was let through while indexing is asked again by the next run.
    func testIgnoredIndexingStateIsRechecked() async throws {
        let photos = service()
        func warned() async throws -> Bool {
            let events = Events()
            var config = SyncConfiguration(directoryPath: dir.path)
            config.folderStructure = "none"
            config.recent = 1
            _ = try await SyncEngine(configuration: config) { events.add($0) }.run(photos: photos)
            return events.logs.contains { $0.contains("still reported as indexing") }
        }
        FakeICloud.zones = ["PrimarySync": "RUNNING"]
        try await photos.primary.waitForIndexing(ignore: true)
        XCTAssertTrue(photos.primary.indexingStateIgnored)
        let whileIndexing = try await warned()
        XCTAssertTrue(whileIndexing)

        FakeICloud.zones = [:]
        let afterwards = try await warned()
        XCTAssertFalse(afterwards)
        XCTAssertFalse(photos.primary.indexingStateIgnored)
    }

    /// An answer to a request sent before signing out doesn't bring the session files back.
    func testAnswerAfterSignOutIsDropped() async throws {
        let store = SessionStore(directory: dir.appendingPathComponent("session"))
        let http = HTTPClient(homeEndpoint: "https://www.icloud.com", store: store)
        let sessionFile = store.directory.appendingPathComponent("session.json")
        let url = URL(string: "https://fake.icloud.test/x")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["scnt": "abc", "Set-Cookie": "k=v; Path=/"])!
        let sentAt = http.generation
        http.absorb(response, url: url, generation: sentAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionFile.path))

        http.resetSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
        http.absorb(response, url: url, generation: sentAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionFile.path))
        XCTAssertNil(http.sessionData.scnt)

        // A request sent after the reset is a new session's and is saved as usual.
        http.absorb(response, url: url, generation: http.generation)
        XCTAssertEqual(store.load().0.scnt, "abc")
    }

    func testVideosCanHaveTheirOwnSize() throws {
        var config = SyncConfiguration(directoryPath: dir.path)
        config.sizes = [.original, .adjusted]
        XCTAssertEqual(config.requestedSizes(isImage: false), [.original, .adjusted]) // none set: as photos
        config.videoSize = .medium
        XCTAssertEqual(config.requestedSizes(isImage: true), [.original, .adjusted])
        XCTAssertEqual(config.requestedSizes(isImage: false), [.medium])
        XCTAssertNoThrow(try config.validate())
        config.videoSize = .adjusted // there is no edited version of a video
        XCTAssertThrowsError(try config.validate())

        // A configuration saved before videos had a size still loads.
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SyncConfiguration(directoryPath: "/x"))) as! [String: Any]
        saved["videoSize"] = nil
        let loaded = try JSONDecoder().decode(SyncConfiguration.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertNil(loaded.videoSize)
    }

    func testDeleteList() async throws {
        let list = try DeleteList(contents: "IMG_0001.JPG\t1001\t\(1_722_427_200 - 86_400)\nIMG_7777.JPG\t1\t1722427200\n")
        let summary = try await list.run(library: service().primary, dryRun: false) { _, _ in }
        XCTAssertEqual(summary.deleted, 1)
        XCTAssertEqual(summary.notFound, 1)
        XCTAssertEqual(FakeICloud.deleteRequests, ["A-p1"])
    }
}
