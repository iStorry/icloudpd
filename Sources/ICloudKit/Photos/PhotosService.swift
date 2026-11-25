import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The iCloud Photos service: the entry point to the account's libraries.
/// Port of pyicloud_ipd's PhotosService.
public final class PhotosService: @unchecked Sendable {
    let http: HTTPClient
    let serviceRoot: String
    let params: String
    let ignoreIndexingState: Bool
    /// The primary ("PrimarySync") library, or the zone it moved to.
    public let primary: PhotoLibrary

    init(http: HTTPClient, serviceRoot: String, params: String, ignoreIndexingState: Bool, primary: PhotoLibrary) {
        self.http = http
        self.serviceRoot = serviceRoot
        self.params = params
        self.ignoreIndexingState = ignoreIndexingState
        self.primary = primary
    }

    static func endpoint(serviceRoot: String, libraryType: String) -> String {
        "\(serviceRoot)/database/1/com.apple.photos.cloud/production/\(libraryType)"
    }

    static func query(dsid: String) -> String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "dsid", value: dsid),
            URLQueryItem(name: "remapEnums", value: "True"),
            URLQueryItem(name: "getCurrentSyncToken", value: "True"),
        ]
        return components.percentEncodedQuery ?? ""
    }

    /// Opens the primary library, waiting for iCloud to finish indexing it. Falls back to a
    /// moved primary zone (PrimarySync1 and so on) like icloudpd does (#1361).
    static func open(serviceRoot: String, dsid: String, http: HTTPClient, ignoreIndexingState: Bool = false) async throws -> PhotosService {
        let params = query(dsid: dsid)
        let endpoint = endpoint(serviceRoot: serviceRoot, libraryType: "private")
        let primary = PhotoLibrary(http: http, endpoint: endpoint, params: params,
                                   zoneID: ["zoneName": "PrimarySync"], libraryType: .private)
        do {
            try await primary.waitForIndexing(ignore: ignoreIndexingState)
            return PhotosService(http: http, serviceRoot: serviceRoot, params: params,
                                 ignoreIndexingState: ignoreIndexingState, primary: primary)
        } catch ICloudError.serviceNotActivated(let reason) {
            let zones = (try? await PhotosService.zoneIDs(http: http, endpoint: endpoint)) ?? []
            guard let moved = zones.first(where: {
                let name = $0["zoneName"] as? String ?? ""
                return name.hasPrefix("PrimarySync") && name != "PrimarySync"
            }) else { throw ICloudError.serviceNotActivated(reason) }
            let library = PhotoLibrary(http: http, endpoint: endpoint, params: params, zoneID: moved, libraryType: .private)
            try await library.waitForIndexing(ignore: ignoreIndexingState)
            return PhotosService(http: http, serviceRoot: serviceRoot, params: params,
                                 ignoreIndexingState: ignoreIndexingState, primary: library)
        }
    }

    static func zoneIDs(http: HTTPClient, endpoint: String) async throws -> [[String: Any]] {
        let response = try await http.send("POST", URL(string: "\(endpoint)/zones/list")!,
                                           headers: ["Content-Type": "text/plain"], body: Data("{}".utf8))
        let zones = try response.json()["zones"] as? [[String: Any]] ?? []
        return zones.compactMap { zone in
            if zone["deleted"] as? Bool == true || zone["serverErrorCode"] != nil { return nil }
            guard let id = zone["zoneID"] as? [String: Any], id["zoneName"] as? String != nil else { return nil }
            return id
        }
    }

    /// The libraries found so far, by type: looking one up by name doesn't ask iCloud again.
    private var known: [PhotoLibrary.LibraryType: [PhotoLibrary]] = [:]
    private let knownLock = NSLock()

    private func knownLibraries(_ type: PhotoLibrary.LibraryType) -> [PhotoLibrary]? {
        knownLock.lock(); defer { knownLock.unlock() }
        return known[type]
    }

    private func remember(_ libraries: [PhotoLibrary], as type: PhotoLibrary.LibraryType) {
        knownLock.lock(); defer { knownLock.unlock() }
        known[type] = libraries
    }

    /// The libraries of one type. The primary library is returned as `primary` (it isn't checked again).
    /// The answer is kept; `refresh` asks iCloud again.
    public func libraries(_ type: PhotoLibrary.LibraryType, refresh: Bool = false) async throws -> [PhotoLibrary] {
        if !refresh, let libraries = knownLibraries(type) { return libraries }
        let endpoint = PhotosService.endpoint(serviceRoot: serviceRoot, libraryType: type.rawValue)
        var result: [PhotoLibrary] = []
        for zone in try await PhotosService.zoneIDs(http: http, endpoint: endpoint) {
            let name = zone["zoneName"] as? String
            if type == .private, name == primary.name {
                result.append(primary)
                continue
            }
            let library = PhotoLibrary(http: http, endpoint: endpoint, params: params, zoneID: zone, libraryType: type)
            do {
                try await library.waitForIndexing(ignore: ignoreIndexingState)
                result.append(library)
            } catch {
                continue // like icloudpd, a library that can't be opened is left out
            }
        }
        remember(result, as: type)
        return result
    }

    /// Private and shared libraries (the names icloudpd's --list-libraries prints), fresh from iCloud.
    public func allLibraries() async throws -> [PhotoLibrary] {
        let privates = try await libraries(.private, refresh: true)
        let shared = (try? await libraries(.shared, refresh: true)) ?? []
        return privates + shared
    }

    /// The library with this zone name. "PrimarySync" (or nil) is always the primary library.
    public func library(named name: String?) async throws -> PhotoLibrary {
        guard let name, !name.isEmpty, name != "PrimarySync", name != primary.name else { return primary }
        if let found = try await libraries(.private).first(where: { $0.name == name }) { return found }
        if let found = try await libraries(.shared).first(where: { $0.name == name }) { return found }
        throw ICloudError.unknownLibrary(name)
    }
}

/// One photo library (a CloudKit zone): the personal library, or an iCloud Shared Photo Library.
public final class PhotoLibrary: @unchecked Sendable {
    public enum LibraryType: String, Sendable {
        case `private`
        case shared
    }

    let http: HTTPClient
    let endpoint: String
    let params: String
    public let zoneID: [String: Any]
    public let libraryType: LibraryType
    public var name: String { zoneID["zoneName"] as? String ?? "PrimarySync" }
    /// Set when iCloud kept reporting "indexing" and `ignoreIndexingState` let the run go on.
    public private(set) var indexingStateIgnored = false

    static let indexingAttempts = 15
    static var indexingRetryDelay: UInt64 = 4_000_000_000

    init(http: HTTPClient, endpoint: String, params: String, zoneID: [String: Any], libraryType: LibraryType) {
        self.http = http
        self.endpoint = endpoint
        self.params = params
        self.zoneID = zoneID
        self.libraryType = libraryType
    }

    func url(_ path: String) -> URL {
        URL(string: "\(endpoint)/\(path)?\(params)")!
    }

    func post(_ path: String, _ body: [String: Any], contentType: String = "text/plain") async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.send("POST", url(path), headers: ["Content-Type": contentType], body: data)
        return try response.json()
    }

    /// iCloud can answer FAILED because its indexing job asks for a CPLContainerRelation* index the
    /// library doesn't have; the listing doesn't use that index (#1361).
    static func isMissingContainerIndex(_ error: Any?) -> Bool {
        guard let error = error as? String else { return false }
        let pattern = #"^CKCloudDBException:No index with requested name: CPLContainerRelation\w+$"#
        return error.components(separatedBy: ", ").allSatisfy { $0.range(of: pattern, options: .regularExpression) != nil }
    }

    func waitForIndexing(ignore: Bool) async throws {
        let body: [String: Any] = ["query": ["recordType": "CheckIndexingState"], "zoneID": zoneID]
        var allIgnorable = true
        for attempt in 1...PhotoLibrary.indexingAttempts {
            let response = try await post("records/query", body)
            let record = (response["records"] as? [[String: Any]])?.first
            let fields = record?["fields"] as? [String: Any]
            let state = (fields?["state"] as? [String: Any])?["value"] as? String
            if state == "FINISHED" { return }
            let error = (fields?["error"] as? [String: Any])?["value"]
            let ignorable = state == "RUNNING" || (state == "FAILED" && PhotoLibrary.isMissingContainerIndex(error))
            if !ignorable { allIgnorable = false }
            if attempt < PhotoLibrary.indexingAttempts {
                try await Task.sleep(nanoseconds: PhotoLibrary.indexingRetryDelay)
            }
        }
        if ignore && allIgnorable {
            indexingStateIgnored = true
            return
        }
        throw ICloudError.libraryIndexing
    }

    // MARK: Albums

    /// Smart albums every library has (pyicloud_ipd's SMART_FOLDERS).
    static let smartFolders: [(name: String, objType: String, listType: String, smartAlbum: String?)] = [
        ("Time-lapse", "CPLAssetInSmartAlbumByAssetDate:Timelapse", "CPLAssetAndMasterInSmartAlbumByAssetDate", "TIMELAPSE"),
        ("Videos", "CPLAssetInSmartAlbumByAssetDate:Video", "CPLAssetAndMasterInSmartAlbumByAssetDate", "VIDEO"),
        ("Slo-mo", "CPLAssetInSmartAlbumByAssetDate:Slomo", "CPLAssetAndMasterInSmartAlbumByAssetDate", "SLOMO"),
        ("Bursts", "CPLAssetBurstStackAssetByAssetDate", "CPLBurstStackAssetAndMasterByAssetDate", nil),
        ("Favorites", "CPLAssetInSmartAlbumByAssetDate:Favorite", "CPLAssetAndMasterInSmartAlbumByAssetDate", "FAVORITE"),
        ("Panoramas", "CPLAssetInSmartAlbumByAssetDate:Panorama", "CPLAssetAndMasterInSmartAlbumByAssetDate", "PANORAMA"),
        ("Screenshots", "CPLAssetInSmartAlbumByAssetDate:Screenshot", "CPLAssetAndMasterInSmartAlbumByAssetDate", "SCREENSHOT"),
        ("Live", "CPLAssetInSmartAlbumByAssetDate:Live", "CPLAssetAndMasterInSmartAlbumByAssetDate", "LIVE"),
        ("Recently Deleted", "CPLAssetDeletedByExpungedDate", "CPLAssetAndMasterDeletedByExpungedDate", nil),
        ("Hidden", "CPLAssetHiddenByAssetDate", "CPLAssetAndMasterHiddenByAssetDate", nil),
    ]

    static func smartFilter(_ value: String) -> [[String: Any]] {
        [["fieldName": "smartAlbum", "comparator": "EQUALS", "fieldValue": ["type": "STRING", "value": value]]]
    }

    /// The whole library ("All Photos"), newest first.
    public var all: PhotoAlbum {
        PhotoAlbum(library: self, name: "", listType: "CPLAssetAndMasterByAssetDateWithoutHiddenOrDeleted",
                   objType: "CPLAssetByAssetDateWithoutHiddenOrDeleted", filter: [], kind: .all)
    }

    public var recentlyDeleted: PhotoAlbum {
        PhotoAlbum(library: self, name: "Recently Deleted", listType: "CPLAssetAndMasterDeletedByExpungedDate",
                   objType: "CPLAssetDeletedByExpungedDate", filter: [], kind: .smart)
    }

    public var hidden: PhotoAlbum {
        PhotoAlbum(library: self, name: "Hidden", listType: "CPLAssetAndMasterHiddenByAssetDate",
                   objType: "CPLAssetHiddenByAssetDate", filter: [], kind: .smart)
    }

    /// Smart albums, then the user's albums (albums inside folders are named "Folder/Album").
    public func albums() async throws -> [PhotoAlbum] {
        var albums = PhotoLibrary.smartFolders.map { folder in
            PhotoAlbum(library: self, name: folder.name, listType: folder.listType, objType: folder.objType,
                       filter: folder.smartAlbum.map(PhotoLibrary.smartFilter) ?? [], kind: .smart)
        }
        for (path, record) in try await fetchUserAlbums() {
            guard let id = record["recordName"] as? String else { continue }
            albums.append(PhotoAlbum(
                library: self, name: path, listType: "CPLContainerRelationLiveByAssetDate",
                objType: "CPLContainerRelationNotDeletedByAssetDate:\(id)",
                filter: [["fieldName": "parentId", "comparator": "EQUALS", "fieldValue": ["type": "STRING", "value": id]]],
                kind: .user))
        }
        return albums
    }

    public func album(named name: String) async throws -> PhotoAlbum {
        if let album = try await albums().first(where: { $0.name == name }) { return album }
        throw ICloudError.unknownAlbum(name)
    }

    static let folderAlbumType = 3

    func queryFolders(parentID: String?) async throws -> [[String: Any]] {
        var query: [String: Any] = ["recordType": "CPLAlbumByPositionLive"]
        if let parentID {
            query["filterBy"] = [["fieldName": "parentId", "comparator": "EQUALS",
                                  "fieldValue": ["type": "STRING", "value": parentID]]]
        }
        var body: [String: Any] = ["query": query, "zoneID": zoneID]
        var records: [[String: Any]] = []
        var markers = Set<String>()
        while true {
            let response = try await post("records/query", body)
            records += response["records"] as? [[String: Any]] ?? []
            // iCloud returns albums in pages; a marker seen before would repeat the same page.
            guard let marker = response["continuationMarker"] as? String, !markers.contains(marker) else { break }
            markers.insert(marker)
            body["continuationMarker"] = marker
        }
        return records
    }

    /// Album records with their path, walking folders one level at a time (#482, #1071).
    func fetchUserAlbums() async throws -> [(String, [String: Any])] {
        if libraryType == .shared { return [] }
        var albums: [(String, [String: Any])] = []
        var visited = Set<String>()
        // One level of folders at a time, a few folders at once; the albums keep their order.
        var level: [(parentID: String?, prefix: String)] = [(nil, "")]
        while !level.isEmpty {
            var next: [(parentID: String?, prefix: String)] = []
            for start in stride(from: 0, to: level.count, by: PhotoLibrary.folderRequests) {
                let folders = Array(level[start..<min(start + PhotoLibrary.folderRequests, level.count)])
                let listings = try await withThrowingTaskGroup(of: (Int, FolderListing).self) { group in
                    for (index, folder) in folders.enumerated() {
                        group.addTask { (index, FolderListing(records: try await self.queryFolders(parentID: folder.parentID))) }
                    }
                    var listings = [FolderListing](repeating: FolderListing(records: []), count: folders.count)
                    for try await (index, listing) in group { listings[index] = listing }
                    return listings
                }
                for (folder, listing) in zip(folders, listings) {
                    let prefix = folder.prefix
                    for record in listing.records {
                        guard let id = record["recordName"] as? String,
                              let fields = record["fields"] as? [String: Any] else { continue }
                        if id == "----Root-Folder----" || id == "----Project-Root-Folder----" { continue }
                        if let deleted = (fields["isDeleted"] as? [String: Any])?["value"], PhotoAsset.number(deleted) == 1 { continue }
                        if (fields["isDeleted"] as? [String: Any])?["value"] as? Bool == true { continue }
                        guard let encoded = (fields["albumNameEnc"] as? [String: Any])?["value"] as? String,
                              let data = Data(base64Encoded: encoded),
                              let name = String(data: data, encoding: .utf8) else { continue }
                        let albumType = PhotoAsset.number((fields["albumType"] as? [String: Any])?["value"]).map(Int.init)
                        if albumType == PhotoLibrary.folderAlbumType {
                            if !visited.contains(id) {
                                visited.insert(id)
                                next.append((id, "\(prefix)\(name)/"))
                            }
                        } else {
                            albums.append(("\(prefix)\(name)", record))
                        }
                    }
                }
            }
            level = next
        }
        return albums
    }

    /// Folders asked for at the same time while walking the album tree.
    static let folderRequests = 4

    /// The records of one folder, carried out of the task that fetched them.
    private struct FolderListing: @unchecked Sendable {
        let records: [[String: Any]]
    }

    // MARK: Changes

    static func deleteOperation(_ asset: PhotoAsset) throws -> [String: Any] {
        guard let changeTag = asset.assetRecordChangeTag else {
            throw ICloudError.unexpectedResponse("asset has no change tag")
        }
        return [
            "operationType": "update",
            "record": [
                "fields": ["isDeleted": ["value": 1]],
                "recordChangeTag": changeTag,
                "recordName": asset.assetRecordName,
                "recordType": "CPLAsset",
            ],
        ]
    }

    func deleteBody(_ operations: [[String: Any]]) -> [String: Any] {
        ["atomic": true, "desiredKeys": ["isDeleted"], "operations": operations, "zoneID": zoneID]
    }

    /// Moves a photo to Recently Deleted in iCloud. Returns false when iCloud asks to try again later.
    public func delete(_ asset: PhotoAsset) async throws -> Bool {
        let body = deleteBody([try PhotoLibrary.deleteOperation(asset)])
        do {
            _ = try await post("records/modify", body, contentType: "application/json")
            return true
        } catch ICloudError.server(let code, _) where code == "TRY_AGAIN_LATER" {
            return false // e.g. "Sync zone CAS Op-Lock failed" (#1283)
        }
    }

    /// Moves several photos to Recently Deleted with one request. The request is atomic: false
    /// means iCloud refused it and deleted none of them, so they can be tried one at a time.
    public func delete(_ assets: [PhotoAsset]) async throws -> Bool {
        let body = deleteBody(try assets.map(PhotoLibrary.deleteOperation))
        do {
            let response = try await post("records/modify", body, contentType: "application/json")
            // A refused record comes back in "records" with its error instead of failing the request.
            let records = response["records"] as? [[String: Any]] ?? []
            return !records.contains { $0["serverErrorCode"] != nil }
        } catch ICloudError.server(let code, _) where code != "ACCESS_DENIED" {
            return false
        }
    }
}

public struct PhotoAlbum: @unchecked Sendable {
    public enum Kind: Sendable {
        case all
        case smart
        case user
    }

    public let library: PhotoLibrary
    /// "" for the whole library, the smart album name, or "Folder/Album" for user albums.
    public let name: String
    let listType: String
    let objType: String
    let filter: [[String: Any]]
    public let kind: Kind

    public var title: String { name.isEmpty ? "All Photos" : name }

    /// Number of items, from iCloud's index (HyperionIndexCountLookup).
    public func count() async throws -> Int {
        let body: [String: Any] = [
            "batch": [[
                "resultsLimit": 1,
                "query": [
                    "filterBy": [
                        "fieldName": "indexCountID",
                        "fieldValue": ["type": "STRING_LIST", "value": [objType]],
                        "comparator": "IN",
                    ],
                    "recordType": "HyperionIndexCountLookup",
                ],
                "zoneWide": true,
                "zoneID": library.zoneID,
            ]],
        ]
        let response = try await library.post("internal/records/query/batch", body)
        guard let batch = (response["batch"] as? [[String: Any]])?.first,
              let record = (batch["records"] as? [[String: Any]])?.first,
              let fields = record["fields"] as? [String: Any],
              let value = PhotoAsset.number((fields["itemCount"] as? [String: Any])?["value"])
        else { throw ICloudError.unexpectedResponse("photo count") }
        return Int(value)
    }

    public func pager(pageSize: Int = 100, offset: Int = 0) -> AssetPager {
        AssetPager(album: self, pageSize: pageSize, offset: offset)
    }

    /// Every asset in the album, newest first.
    public func photos(pageSize: Int = 100) -> AsyncThrowingStream<PhotoAsset, Error> {
        let pager = pager(pageSize: pageSize)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled, let page = try await pager.nextPage() {
                        for asset in page { continuation.yield(asset) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listQuery(offset: Int, pageSize: Int) -> [String: Any] {
        PhotoAlbum.listQuery(offset: offset, pageSize: pageSize, listType: listType, zoneID: library.zoneID, filter: filter)
    }

    static func listQuery(offset: Int, pageSize: Int, listType: String, zoneID: [String: Any],
                          filter: [[String: Any]] = []) -> [String: Any] {
        var filterBy: [[String: Any]] = [
            ["fieldName": "startRank", "fieldValue": ["type": "INT64", "value": offset], "comparator": "EQUALS"],
            ["fieldName": "direction", "fieldValue": ["type": "STRING", "value": "ASCENDING"], "comparator": "EQUALS"],
        ]
        filterBy += filter
        return [
            "query": ["filterBy": filterBy, "recordType": listType],
            "resultsLimit": pageSize * 2,
            "desiredKeys": desiredKeys,
            "zoneID": zoneID,
        ]
    }

    static let desiredKeys: [String] = {
        let resources = ["resJPEGFull", "resJPEGLarge", "resJPEGMed", "resJPEGThumb", "resVidFull", "resVidMed",
                         "resVidSmall", "resSidecar"]
        var keys: [String] = []
        for r in resources { keys += ["Width", "Height", "FileType", "Fingerprint", "Res"].map { r + $0 } }
        keys += ["itemType", "dataClassType", "filenameEnc", "originalOrientation"]
        for r in ["resOriginal", "resOriginalAlt", "resOriginalVidCompl"] {
            keys += ["Width", "Height", "FileType", "Fingerprint", "Res"].map { r + $0 }
        }
        keys += [
            "isDeleted", "isExpunged", "dateExpunged", "remappedRef", "recordName", "recordType", "recordChangeTag",
            "masterRef", "adjustmentRenderType", "assetDate", "addedDate", "isFavorite", "isHidden", "orientation",
            "duration", "assetSubtype", "assetSubtypeV2", "assetHDRType", "burstFlags", "burstFlagsExt", "burstId",
            "captionEnc", "locationEnc", "locationV2Enc", "locationLatitude", "locationLongitude", "adjustmentType",
            "timeZoneOffset", "vidComplDurValue", "vidComplDurScale", "vidComplDispValue", "vidComplDispScale",
            "keywordsEnc", "extendedDescEnc", "adjustedMediaMetaDataEnc", "adjustmentSimpleDataEnc",
            "vidComplVisibilityState", "customRenderedValue", "containerId", "itemId", "position", "isKeyAsset",
        ]
        return keys
    }()
}

/// Pages through an album. The offset can be moved back when an asset is deleted from
/// iCloud during the run, so the next page doesn't skip one (like icloudpd's increment_offset(-1)).
public final class AssetPager: @unchecked Sendable {
    let album: PhotoAlbum
    let pageSize: Int
    public private(set) var offset: Int
    private var previousMasters: [String: [String: Any]] = [:]
    private var finished = false

    init(album: PhotoAlbum, pageSize: Int, offset: Int) {
        self.album = album
        self.pageSize = pageSize
        self.offset = offset
    }

    public func adjustOffset(by delta: Int) { offset = max(0, offset + delta) }

    /// The next page, or nil at the end.
    public func nextPage() async throws -> [PhotoAsset]? {
        if finished { return nil }
        let response = try await album.library.post("records/query", album.listQuery(offset: offset, pageSize: pageSize))
        let page = AssetPager.parsePage(response, previousMasters: previousMasters)
        if page.assetCount == 0 {
            finished = true
            return nil
        }
        offset += page.assetCount
        previousMasters = page.masters
        return page.assets
    }

    struct Page {
        var assets: [PhotoAsset]
        /// CPLAsset records in the page, including ones skipped for a missing master; startRank counts these.
        var assetCount: Int
        var masters: [String: [String: Any]]
    }

    /// Pairs each CPLAsset with its CPLMaster. Iterates per asset, not per master: several
    /// assets can share one master (Photos' "Duplicate").
    static func parsePage(_ response: [String: Any], previousMasters: [String: [String: Any]]) -> Page {
        let records = response["records"] as? [[String: Any]] ?? []
        var assetRecords: [[String: Any]] = []
        var masters: [String: [String: Any]] = [:]
        for record in records {
            switch record["recordType"] as? String {
            case "CPLAsset": assetRecords.append(record)
            case "CPLMaster": if let name = record["recordName"] as? String { masters[name] = record }
            default: break
            }
        }
        var assets: [PhotoAsset] = []
        for record in assetRecords {
            let fields = record["fields"] as? [String: Any]
            let ref = (fields?["masterRef"] as? [String: Any])?["value"] as? [String: Any]
            guard let masterID = ref?["recordName"] as? String,
                  let master = masters[masterID] ?? previousMasters[masterID] else { continue }
            assets.append(PhotoAsset(master: master, asset: record))
        }
        return Page(assets: assets, assetCount: assetRecords.count, masters: masters)
    }
}
