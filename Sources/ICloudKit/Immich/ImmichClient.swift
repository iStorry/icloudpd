import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public enum ImmichError: LocalizedError, Equatable {
    /// The address isn't something a server can be reached at.
    case badAddress
    /// The server didn't answer, after a few tries.
    case unreachable(String)
    /// Something answered at the address, but it isn't Immich.
    case notImmich
    /// Immich doesn't know the API key.
    case keyRefused
    /// The API key is known but isn't allowed to upload.
    case keyCannotUpload
    case http(status: Int, message: String)

    /// True when every other photo would fail the same way, so the run stops instead of going on.
    public var stopsRun: Bool {
        if case .http = self { return false }
        return true
    }

    public var errorDescription: String? {
        switch self {
        case .badAddress:
            return "That Immich address doesn't look right. It should look like http://192.168.1.10:2283."
        case .unreachable(let reason):
            return "Couldn't reach your Immich server. \(reason)"
        case .notImmich:
            return "There's no Immich server at that address."
        case .keyRefused:
            return "Immich didn't accept the API key."
        case .keyCannotUpload:
            return "This Immich API key isn't allowed to upload. Make a key with the asset.upload permission."
        case .http(let status, let message):
            return "Immich returned HTTP \(status). \(message)"
        }
    }
}

/// Who an API key belongs to. The name is missing when the key may upload but not read the account.
public struct ImmichAccount: Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var email: String?
}

/// The parts of Immich's API that uploading needs: checking the server and the key, asking whether
/// a file is already there, and sending one.
public struct ImmichClient: Sendable {
    public enum Outcome: Equatable, Sendable { case created, duplicate }

    /// The server's address without "/api".
    public let server: URL
    let apiKey: String
    let session: URLSession
    /// Seconds to wait before trying a request again; tests make it zero.
    var retryDelay: Double = 2

    public init(address: String, apiKey: String) throws {
        guard let server = ImmichClient.normalise(address) else { throw ImmichError.badAddress }
        self.server = server
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120 // without any data moving; a large video takes as long as it takes
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    /// "192.168.1.10:2283", "photos.example.com/api/" and "https://photos.example.com" all work.
    /// Without "http://" or "https://", a plain host on the local network gets http and anything else https.
    public static func normalise(_ address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let name = host.split(separator: ":").first.map(String.init) ?? host
            let isLocal = host.contains(":") || name == "localhost" || name.hasSuffix(".local") || !name.contains(".")
                || name.allSatisfy { $0.isNumber || $0 == "." }
            text = (isLocal ? "http://" : "https://") + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/api") { text.removeLast(4) }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func request(_ method: String, _ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: server.absoluteString + "/api/" + path) ?? server)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Runs a request, trying again when the network or the server stumbles.
    func send(_ request: URLRequest, fromFile file: URL? = nil, attempts: Int = 3) async throws -> (Data, Int) {
        var lastError: Error = ImmichError.unreachable("")
        for attempt in 1...attempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.immichData(for: request, fromFile: file)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (500..<600).contains(status), attempt < attempts {
                    lastError = ImmichError.http(status: status, message: ImmichClient.message(in: data))
                } else {
                    return (data, status)
                }
            } catch {
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                lastError = ImmichError.unreachable(error.localizedDescription)
            }
            if attempt < attempts { try await Task.sleep(nanoseconds: UInt64(Double(attempt) * retryDelay * 1_000_000_000)) }
        }
        throw lastError
    }

    static func message(in data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String { return message }
            if let messages = object["message"] as? [String] { return messages.joined(separator: " ") }
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }

    /// The errors every authenticated request can end in.
    static func check(_ status: Int, _ data: Data) throws {
        switch status {
        case 200..<300: return
        case 401: throw ImmichError.keyRefused
        case 403: throw ImmichError.keyCannotUpload
        default: throw ImmichError.http(status: status, message: message(in: data))
        }
    }

    /// Checks that the address is an Immich server and that it knows the key.
    public func connect() async throws -> ImmichAccount {
        let (pong, pingStatus) = try await send(request("GET", "server/ping"), attempts: 2)
        guard pingStatus == 200,
              (try? JSONSerialization.jsonObject(with: pong) as? [String: Any])?["res"] as? String == "pong" else {
            throw ImmichError.notImmich
        }
        let (data, status) = try await send(request("GET", "users/me"), attempts: 2)
        // A key that may only upload can't read the account: it is still a key Immich knows.
        if status == 403 { return ImmichAccount() }
        try ImmichClient.check(status, data)
        let user = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ImmichAccount(id: user["id"] as? String, name: user["name"] as? String, email: user["email"] as? String)
    }

    /// True when Immich already has a file with this checksum, so it needn't be sent.
    func alreadyThere(name: String, checksum: String) async throws -> Bool {
        var check = request("POST", "assets/bulk-upload-check")
        check.setValue("application/json", forHTTPHeaderField: "Content-Type")
        check.httpBody = try JSONSerialization.data(withJSONObject: ["assets": [["id": name, "checksum": checksum]]])
        let (data, status) = try await send(check)
        if status == 401 { throw ImmichError.keyRefused }
        if status == 403 { throw ImmichError.keyCannotUpload }
        guard (200..<300).contains(status),
              let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]],
              let result = results.first else { return false } // not sure: sending it settles it
        return result["action"] as? String == "reject" && result["reason"] as? String == "duplicate"
    }

    /// Sends one photo or video, with its XMP sidecar when there is one. Immich keeps one copy of
    /// a file however often it is sent, so a file it already has comes back as `.duplicate`.
    /// `workFolder` is where the request is put together; it should be on a disk with room for the file.
    @discardableResult
    public func upload(file: URL, sidecar: URL? = nil, created: Date, modified: Date? = nil, workFolder: URL) async throws -> Outcome {
        let name = file.lastPathComponent
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
        if let checksum = ImmichClient.sha1(of: file), try await alreadyThere(name: name, checksum: checksum) {
            return .duplicate
        }
        try Task.checkCancellation()

        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var fields = [
            ("fileCreatedAt", dates.string(from: created)),
            ("fileModifiedAt", dates.string(from: modified ?? created)),
            ("filename", name),
            // Older servers ask for these two; newer ones ignore them.
            ("deviceAssetId", "\(name)-\(size)"),
            ("deviceId", "icloudpd-swift"),
        ]
        if file.pathExtension.isEmpty { fields.removeAll { $0.0 == "filename" } }

        let boundary = "icloudpd-swift-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let body = workFolder.appendingPathComponent(UUID().uuidString + ".upload")
        defer { try? FileManager.default.removeItem(at: body) }
        var files = [("assetData", file)]
        if let sidecar { files.append(("sidecarData", sidecar)) }
        try ImmichClient.writeMultipart(to: body, boundary: boundary, fields: fields, files: files)

        var upload = request("POST", "assets")
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await send(upload, fromFile: body)
        try ImmichClient.check(status, data)
        let answer = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
        return answer == "duplicate" || status == 200 ? .duplicate : .created
    }

    /// Writes a multipart/form-data body to a file, copying the files in pieces so a large video
    /// never sits in memory.
    static func writeMultipart(to url: URL, boundary: String, fields: [(String, String)], files: [(String, URL)]) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        func write(_ text: String) throws { try out.write(contentsOf: Data(text.utf8)) }
        for (name, value) in fields {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        for (name, file) in files {
            let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                      + "Content-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try write("\r\n")
        }
        try write("--\(boundary)--\r\n")
    }

    /// The file's SHA-1 as hex, which is how Immich recognises a file it already has.
    /// Nil where CryptoKit is missing: the file is then simply sent.
    static func sha1(of file: URL) -> String? {
        #if canImport(CryptoKit)
        guard let input = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? input.close() }
        var hash = Insecure.SHA1()
        while let chunk = try? input.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

private final class ImmichTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

extension URLSession {
    /// A request, with its body read from a file when one is given, that stops when its task is cancelled.
    func immichData(for request: URLRequest, fromFile file: URL?) async throws -> (Data, URLResponse) {
        let box = ImmichTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let done: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let response else {
                        continuation.resume(throwing: ImmichError.unreachable("No answer.")); return
                    }
                    continuation.resume(returning: (data ?? Data(), response))
                }
                let task = file.map { uploadTask(with: request, fromFile: $0, completionHandler: done) }
                    ?? dataTask(with: request, completionHandler: done)
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}
