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

    /// Downloads `url` to a temporary file and returns it with the response.
    public func download(_ url: URL) async throws -> (URL, HTTPURLResponse) {
        let request = makeRequest("GET", url, headers: [:], body: nil)
        let (fileURL, urlResponse) = try await urlSession.compatDownload(for: request)
        guard let http = urlResponse as? HTTPURLResponse else {
            throw ICloudError.unexpectedResponse("not an HTTP response")
        }
        absorb(http, url: url)
        return (fileURL, http)
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

    /// async download(for:). The file is moved out of the system's temporary
    /// location before returning, because URLSession deletes it after the callback.
    func compatDownload(for request: URLRequest) async throws -> (URL, URLResponse) {
        let taskBox = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = downloadTask(with: request) { location, response, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let location, let response else {
                        continuation.resume(throwing: ICloudError.unexpectedResponse("no file")); return
                    }
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("icloudphotos-" + UUID().uuidString)
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                taskBox.task = task
                task.resume()
            }
        } onCancel: {
            taskBox.task?.cancel()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    var task: URLSessionTask?
}
