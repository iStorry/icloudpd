import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The iCloud Photos CloudKit database for one library (port of pyicloud_ipd's
/// PhotosService / PhotoLibrary / PhotoAlbum, primary library and "All Photos" only for now).
public final class PhotosService: @unchecked Sendable {
    let http: HTTPClient
    let endpoint: String
    let params: String
    public let zoneID: [String: Any]
    public var zoneName: String { zoneID["zoneName"] as? String ?? "PrimarySync" }

    static let indexingAttempts = 15
    static let indexingRetryDelay: UInt64 = 4_000_000_000

    init(http: HTTPClient, endpoint: String, params: String, zoneID: [String: Any]) {
        self.http = http
        self.endpoint = endpoint
        self.params = params
        self.zoneID = zoneID
    }

    static func endpoint(serviceRoot: String, libraryType: String = "private") -> String {
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

    /// Opens the primary library, waiting for iCloud to finish indexing it.
    /// Falls back to a moved primary zone (PrimarySync1 and so on) like icloudpd does.
    static func open(serviceRoot: String, dsid: String, http: HTTPClient) async throws -> PhotosService {
        let endpoint = endpoint(serviceRoot: serviceRoot)
        let params = query(dsid: dsid)
        let primary = PhotosService(http: http, endpoint: endpoint, params: params, zoneID: ["zoneName": "PrimarySync"])
        do {
            try await primary.waitForIndexing()
            return primary
        } catch ICloudError.serviceNotActivated(let reason) {
            let zones = (try? await primary.zoneIDs()) ?? []
            guard let moved = zones.first(where: {
                let name = $0["zoneName"] as? String ?? ""
                return name.hasPrefix("PrimarySync") && name != "PrimarySync"
            }) else { throw ICloudError.serviceNotActivated(reason) }
            let library = PhotosService(http: http, endpoint: endpoint, params: params, zoneID: moved)
            try await library.waitForIndexing()
            return library
        }
    }

    private func url(_ path: String) -> URL {
        URL(string: "\(endpoint)/\(path)?\(params)")!
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.send("POST", url(path), headers: ["Content-Type": "text/plain"], body: data)
        return try response.json()
    }

    func waitForIndexing() async throws {
        let body: [String: Any] = ["query": ["recordType": "CheckIndexingState"], "zoneID": zoneID]
        for attempt in 1...PhotosService.indexingAttempts {
            let response = try await post("records/query", body)
            let record = (response["records"] as? [[String: Any]])?.first
            let state = ((record?["fields"] as? [String: Any])?["state"] as? [String: Any])?["value"] as? String
            if state == "FINISHED" { return }
            if attempt < PhotosService.indexingAttempts {
                try await Task.sleep(nanoseconds: PhotosService.indexingRetryDelay)
            }
        }
        throw ICloudError.libraryIndexing
    }

    func zoneIDs() async throws -> [[String: Any]] {
        let data = Data("{}".utf8)
        let response = try await http.send("POST", URL(string: "\(endpoint)/zones/list")!,
                                           headers: ["Content-Type": "text/plain"], body: data)
        let zones = try response.json()["zones"] as? [[String: Any]] ?? []
        return zones.compactMap { zone in
            if zone["deleted"] as? Bool == true || zone["serverErrorCode"] != nil { return nil }
            guard let id = zone["zoneID"] as? [String: Any], id["zoneName"] as? String != nil else { return nil }
            return id
        }
    }

    // MARK: All Photos

    static let allPhotosListType = "CPLAssetAndMasterByAssetDateWithoutHiddenOrDeleted"
    static let allPhotosObjType = "CPLAssetByAssetDateWithoutHiddenOrDeleted"

    /// Number of items in All Photos.
    public func count() async throws -> Int {
        let body: [String: Any] = [
            "batch": [[
                "resultsLimit": 1,
                "query": [
                    "filterBy": [
                        "fieldName": "indexCountID",
                        "fieldValue": ["type": "STRING_LIST", "value": [PhotosService.allPhotosObjType]],
                        "comparator": "IN",
                    ],
                    "recordType": "HyperionIndexCountLookup",
                ],
                "zoneWide": true,
                "zoneID": zoneID,
            ]],
        ]
        let response = try await post("internal/records/query/batch", body)
        guard let batch = (response["batch"] as? [[String: Any]])?.first,
              let record = (batch["records"] as? [[String: Any]])?.first,
              let fields = record["fields"] as? [String: Any],
              let itemCount = fields["itemCount"] as? [String: Any],
              let value = itemCount["value"] as? Int
        else { throw ICloudError.unexpectedResponse("photo count") }
        return value
    }

    /// All Photos, oldest first, a page at a time.
    public func allPhotos(pageSize: Int = 100) -> AsyncThrowingStream<PhotoAsset, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var offset = 0
                    var previousMasters: [String: [String: Any]] = [:]
                    while !Task.isCancelled {
                        let body = PhotosService.listQuery(offset: offset, pageSize: pageSize,
                                                           listType: PhotosService.allPhotosListType, zoneID: zoneID)
                        let response = try await post("records/query", body)
                        let page = PhotosService.parsePage(response, previousMasters: previousMasters)
                        if page.assetCount == 0 { break }
                        for asset in page.assets { continuation.yield(asset) }
                        offset += page.assetCount
                        previousMasters = page.masters
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    struct Page {
        var assets: [PhotoAsset]
        /// CPLAsset records in the page, including ones skipped for a missing master; the offset counts these.
        var assetCount: Int
        var masters: [String: [String: Any]]
    }

    /// Pairs each CPLAsset with its CPLMaster. Iterates per asset, not per master: several
    /// assets can share one master (Photos' "Duplicate"), and startRank counts assets.
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
