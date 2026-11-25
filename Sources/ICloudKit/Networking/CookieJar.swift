import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A cookie jar the app owns, so each Apple ID gets its own cookies and they
/// can be saved to disk between launches (like icloudpd's LWPCookieJar).
public struct StoredCookie: Codable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var secure: Bool

    func matches(host: String, path requestPath: String, isSecure: Bool, now: Date) -> Bool {
        if let expires, expires < now { return false }
        if secure && !isSecure { return false }
        let host = host.lowercased()
        let domain = self.domain.lowercased()
        if domain.hasPrefix(".") {
            let bare = String(domain.dropFirst())
            guard host == bare || host.hasSuffix(domain) else { return false }
        } else {
            guard host == domain else { return false }
        }
        let p = requestPath.isEmpty ? "/" : requestPath
        return p == path || p.hasPrefix(path.hasSuffix("/") ? path : path + "/") || path == "/"
    }
}

public final class CookieJar {
    public private(set) var cookies: [StoredCookie]

    public init(cookies: [StoredCookie] = []) {
        self.cookies = cookies
    }

    /// Stores the cookies from a response's Set-Cookie headers.
    public func store(from response: HTTPURLResponse, url: URL, now: Date = Date()) {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let k = key as? String, let v = value as? String { fields[k] = v }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            let stored = StoredCookie(
                name: cookie.name,
                value: cookie.value,
                domain: cookie.domain,
                path: cookie.path.isEmpty ? "/" : cookie.path,
                expires: cookie.expiresDate,
                secure: cookie.isSecure
            )
            cookies.removeAll { $0.name == stored.name && $0.domain == stored.domain && $0.path == stored.path }
            if let expires = stored.expires, expires < now { continue } // a deletion
            cookies.append(stored)
        }
    }

    /// The Cookie header value for a request to `url`, or nil when nothing matches.
    public func header(for url: URL, now: Date = Date()) -> String? {
        guard let host = url.host else { return nil }
        let isSecure = url.scheme == "https"
        let matching = cookies
            .filter { $0.matches(host: host, path: url.path, isSecure: isSecure, now: now) }
            .sorted { $0.path.count > $1.path.count }
        guard !matching.isEmpty else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func removeAll() { cookies.removeAll() }
}
