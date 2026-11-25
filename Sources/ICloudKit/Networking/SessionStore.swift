import Foundation

/// What icloudpd keeps in its `<appleid>.session` file: tokens Apple hands out in
/// response headers, which let later launches skip the password and 2FA.
public struct SessionData: Codable, Equatable {
    public var clientID: String
    public var sessionToken: String?
    public var trustToken: String?
    public var sessionID: String?
    public var scnt: String?
    public var accountCountry: String?

    public init(clientID: String = "auth-" + UUID().uuidString.lowercased()) {
        self.clientID = clientID
    }
}

/// Saves session data and cookies for one Apple ID under a private folder
/// (by default ~/Library/Application Support/ICloudPhotos/Sessions/<appleid>).
/// The files hold sign-in tokens, so they are written with 0600 permissions.
public struct SessionStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func defaultDirectory(for appleID: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let safe = appleID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        return base
            .appendingPathComponent("ICloudPhotos", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(String(String.UnicodeScalarView(safe)), isDirectory: true)
    }

    private var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private var cookiesURL: URL { directory.appendingPathComponent("cookies.json") }

    public func load() -> (SessionData, [StoredCookie]) {
        let decoder = JSONDecoder()
        let session = (try? Data(contentsOf: sessionURL)).flatMap { try? decoder.decode(SessionData.self, from: $0) } ?? SessionData()
        let cookies = (try? Data(contentsOf: cookiesURL)).flatMap { try? decoder.decode([StoredCookie].self, from: $0) } ?? []
        return (session, cookies)
    }

    public func save(session: SessionData, cookies: [StoredCookie]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            try write(encoder.encode(session), to: sessionURL)
            try write(encoder.encode(cookies), to: cookiesURL)
        } catch {
            // Not fatal: the next launch just signs in again.
        }
    }

    /// Forget the saved sign-in (used by "Sign Out").
    public func clear() {
        try? FileManager.default.removeItem(at: sessionURL)
        try? FileManager.default.removeItem(at: cookiesURL)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
