import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse {
    public let status: Int
    public let data: Data
    public let response: HTTPURLResponse

    public var isOK: Bool { (200..<400).contains(status) }

    public func header(_ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }

    public var isJSON: Bool {
        let type = (header("Content-Type") ?? "").split(separator: ";").first.map(String.init) ?? ""
        return type == "application/json" || type == "text/json"
    }

    public func json() throws -> [String: Any] {
        if status == 204 || data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            throw ICloudError.unexpectedResponse("expected a JSON object (HTTP \(status))")
        }
        return dict
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// The HTTP session shared by sign-in and Photos calls. Port of pyicloud_ipd's
/// PyiCloudSession: browser-like headers, its own cookie jar, and it records the
/// X-Apple-* tokens Apple sends back so the sign-in survives a relaunch.
public final class HTTPClient: @unchecked Sendable {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

    /// Tests install a URLProtocol here to fake iCloud.
    nonisolated(unsafe) static var protocolClassesForTesting: [AnyClass]?

    let urlSession: URLSession
    let homeEndpoint: String
    let store: SessionStore?
    private let jar: CookieJar
    private var _sessionData: SessionData
    private let lock = NSLock()

    public init(homeEndpoint: String, store: SessionStore?, timeout: TimeInterval = 60) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        if let classes = HTTPClient.protocolClassesForTesting { config.protocolClasses = classes }
        self.urlSession = URLSession(configuration: config)
        self.homeEndpoint = homeEndpoint
        self.store = store
        let (session, cookies) = store?.load() ?? (SessionData(), [])
        self._sessionData = session
        self.jar = CookieJar(cookies: cookies)
    }

    public var sessionData: SessionData {
        get { lock.lock(); defer { lock.unlock() }; return _sessionData }
        set { lock.lock(); _sessionData = newValue; lock.unlock(); persist() }
    }

    public func resetSession() {
        lock.lock()
        _sessionData = SessionData()
        jar.removeAll()
        lock.unlock()
        store?.clear()
    }

    private func persist() {
        lock.lock()
        let session = _sessionData
        let cookies = jar.cookies
        lock.unlock()
        store?.save(session: session, cookies: cookies)
    }

    func makeRequest(_ method: String, _ url: URL, headers: [String: String], body: Data?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(homeEndpoint, forHTTPHeaderField: "Origin")
        request.setValue(homeEndpoint + "/", forHTTPHeaderField: "Referer")
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        lock.lock()
        let cookieHeader = jar.header(for: url)
        lock.unlock()
        if let cookieHeader { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        request.httpBody = body
        return request
    }

    /// Saves cookies and the X-Apple-* session headers from a response.
    func absorb(_ response: HTTPURLResponse, url: URL) {
        lock.lock()
        jar.store(from: response, url: url)
        func capture(_ header: String, _ apply: (inout SessionData, String) -> Void) {
            if let value = response.value(forHTTPHeaderField: header), !value.isEmpty { apply(&_sessionData, value) }
        }
        capture("X-Apple-ID-Account-Country") { $0.accountCountry = $1 }
        capture("X-Apple-ID-Session-Id") { $0.sessionID = $1 }
        capture("X-Apple-Session-Token") { $0.sessionToken = $1 }
        capture("X-Apple-TwoSV-Trust-Token") { $0.trustToken = $1 }
        capture("scnt") { $0.scnt = $1 }
        lock.unlock()
        persist()
    }

    /// Sends a request. With `checkErrors` (the default) it throws the way pyicloud_ipd
    /// does: on a failed non-JSON response, or on a JSON body that reports an error.
    @discardableResult
    public func send(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data? = nil,
                     checkErrors: Bool = true) async throws -> HTTPResponse {
        let request = makeRequest(method, url, headers: headers, body: body)
        let (data, urlResponse) = try await urlSession.compatData(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw ICloudError.unexpectedResponse("not an HTTP response")
        }
        absorb(http, url: url)
        let response = HTTPResponse(status: http.statusCode, data: data, response: http)
        if checkErrors { try HTTPClient.check(response) }
        return response
    }

    static func check(_ response: HTTPResponse) throws {
        if response.status == 503 {
            throw ICloudError.http(status: 503, message: "Apple is rate limiting this account. Wait a while and try again.")
        }
        if !response.isOK && (!response.isJSON || [421, 450, 500].contains(response.status)) {
            if [421, 450, 500].contains(response.status) {
                throw ICloudError.http(status: response.status, message: "Authentication required for account.")
            }
            throw ICloudError.http(status: response.status, message: HTTPURLResponse.localizedString(forStatusCode: response.status))
        }
        guard response.isJSON, let dict = try? response.json() else { return }
        try checkBody(dict)
    }

    static func checkBody(_ dict: [String: Any]) throws {
        if dict["hasError"] as? Bool == true {
            let first = (dict["service_errors"] as? [[String: Any]])?.first
            throw ICloudError.server(code: first?["code"] as? String ?? "Unknown",
                                     reason: first?["message"] as? String ?? "Unknown")
        }
        if dict["success"] as? Bool != true {
            var reason = dict["errorMessage"] as? String ?? dict["reason"] as? String ?? dict["errorReason"] as? String
            if reason == nil, let e = dict["error"] as? String { reason = e }
            if reason == nil, let e = dict["error"], !(e is NSNull) {
                if (e as? Bool) != false && (e as? Int) != 0 { reason = "Unknown reason" }
            }
            guard let reason else { return }
            let code = stringValue(dict["errorCode"]) ?? stringValue(dict["serverErrorCode"]) ?? stringValue(dict["error"]) ?? "Unknown"
            if code == "ZONE_NOT_FOUND" || code == "AUTHENTICATION_FAILED" {
                throw ICloudError.serviceNotActivated(
                    "iCloud setup isn't complete for this account. Sign in at icloud.com once to finish setting up iCloud (\(code)).")
            }
            throw ICloudError.server(code: code, reason: reason)
        }
    }

    static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let i as Int: return String(i)
        default: return nil
        }
    }

    /// Downloads `url` into `partURL`, continuing a partial file left by an earlier run
    /// (with an HTTP Range request) when there is one. Returns the HTTP status.
    public func downloadFile(_ url: URL, to partURL: URL,
                             progress: (@Sendable (Int) -> Void)? = nil) async throws -> Int {
        let existing = (try? FileManager.default.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.intValue ?? 0
        var headers: [String: String] = [:]
        if existing > 0 { headers["Range"] = "bytes=\(existing)-" }
        let request = makeRequest("GET", url, headers: headers, body: nil)
        let (status, response) = try await DownloadRouter.shared.run(request, to: partURL, existingBytes: existing, progress: progress)
        absorb(response, url: url)
        return status
    }
}

extension URLSession {
    /// async data(for:) that also builds against swift-corelibs-foundation.
    func compatData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                guard let response else {
                    continuation.resume(throwing: ICloudError.unexpectedResponse("no response")); return
                }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    var task: URLSessionTask?
}

/// Streams response bodies straight to disk (so large videos never sit in memory), appending to
/// a partial file when the server honours the Range request.
final class DownloadRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = DownloadRouter()

    private final class State {
        let fileURL: URL
        let existingBytes: Int
        let progress: (@Sendable (Int) -> Void)?
        let continuation: CheckedContinuation<(Int, HTTPURLResponse), Error>
        var handle: FileHandle?
        var response: HTTPURLResponse?
        var failure: Error?

        init(fileURL: URL, existingBytes: Int, progress: (@Sendable (Int) -> Void)?,
             continuation: CheckedContinuation<(Int, HTTPURLResponse), Error>) {
            self.fileURL = fileURL
            self.existingBytes = existingBytes
            self.progress = progress
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]
    /// Created once in init: a lazy var isn't thread-safe, and two sessions would hand out
    /// clashing task identifiers.
    private var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 120
        config.httpMaximumConnectionsPerHost = 16
        if let classes = HTTPClient.protocolClassesForTesting { config.protocolClasses = classes }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func run(_ request: URLRequest, to fileURL: URL, existingBytes: Int,
             progress: (@Sendable (Int) -> Void)?) async throws -> (Int, HTTPURLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                let state = State(fileURL: fileURL, existingBytes: existingBytes, progress: progress, continuation: continuation)
                lock.lock(); states[task.taskIdentifier] = state; lock.unlock()
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private func state(_ task: URLSessionTask) -> State? {
        lock.lock(); defer { lock.unlock() }
        return states[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let state = state(dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        state.response = http
        guard (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel); return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: state.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 206 continues the partial file; a full 200 answer starts it over.
            if http.statusCode != 206 || !fm.fileExists(atPath: state.fileURL.path) {
                fm.createFile(atPath: state.fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: state.fileURL)
            if http.statusCode == 206 {
                handle.seekToEndOfFile()
            } else {
                handle.truncateFile(atOffset: 0)
            }
            state.handle = handle
            completionHandler(.allow)
        } catch {
            state.failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let state = state(dataTask), let handle = state.handle else { return }
        handle.write(data)
        state.progress?(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let state = states.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let state else { return }
        state.handle?.closeFile()
        if let response = state.response, !(200..<300).contains(response.statusCode) {
            // 416: the partial file is already complete or no longer matches; the caller decides.
            state.continuation.resume(returning: (response.statusCode, response))
        } else if let failure = state.failure ?? error {
            state.continuation.resume(throwing: failure)
        } else if let response = state.response {
            state.continuation.resume(returning: (response.statusCode, response))
        } else {
            state.continuation.resume(throwing: ICloudError.unexpectedResponse("no response"))
        }
    }
}
