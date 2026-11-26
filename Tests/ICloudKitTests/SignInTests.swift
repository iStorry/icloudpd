import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ICloudKit

/// A fake idmsa / setup server for sign-in. Replies are keyed by "host/path"; the longest key
/// that the request's host and path end with wins.
final class FakeSignInServer: URLProtocol {
    nonisolated(unsafe) static var replies: [String: (status: Int, json: Any)] = [:]
    nonisolated(unsafe) static var calls: [String] = []
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        calls = []
        replies = [
            "/signin/init": (200, [
                "salt": Data(repeating: 7, count: 16).base64EncodedString(),
                "b": Data(repeating: 0x11, count: 256).base64EncodedString(),
                "c": "challenge", "iteration": 1000, "protocol": "s2k",
            ]),
            "/signin/complete": (200, [String: Any]()),
            "/accountLogin": (200, ["dsInfo": ["dsid": "1", "hsaVersion": 0], "webservices": [String: Any]()]),
        ]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        let host = request.url?.host ?? ""
        return host.hasPrefix("idmsa.apple.com") || host.hasPrefix("setup.icloud.com")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let target = (request.url!.host ?? "") + request.url!.path
        FakeSignInServer.lock.lock()
        FakeSignInServer.calls.append(target)
        let key = FakeSignInServer.replies.keys.filter { target.hasSuffix($0) }.max { $0.count < $1.count }
        let reply = key.flatMap { FakeSignInServer.replies[$0] } ?? (404, [String: Any]())
        FakeSignInServer.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class SignInTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        HTTPClient.protocolClassesForTesting = [FakeSignInServer.self]
        FakeSignInServer.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func signIn(_ domain: ICloudDomain) async throws -> (ICloudAccount, SignInResult) {
        let account = ICloudAccount(appleID: "someone@example.com", domain: domain, store: SessionStore(directory: dir))
        return (account, try await account.signIn(password: { "secret" }))
    }

    func testSignsIn() async throws {
        let (_, result) = try await signIn(.com)
        XCTAssertEqual(result, .signedIn)
        XCTAssertTrue(FakeSignInServer.calls.contains("idmsa.apple.com/appleauth/auth/signin/complete"))
    }

    func testChinaFallsBackToTheGlobalSignInHostOn503() async throws {
        FakeSignInServer.replies["idmsa.apple.com.cn/appleauth/auth/signin/complete"] = (503, [String: Any]())
        let (account, result) = try await signIn(.cn)
        XCTAssertEqual(result, .signedIn)
        XCTAssertEqual(FakeSignInServer.calls.filter { $0.hasSuffix("/signin/init") },
                       ["idmsa.apple.com.cn/appleauth/auth/signin/init", "idmsa.apple.com/appleauth/auth/signin/init"])
        XCTAssertTrue(FakeSignInServer.calls.contains("setup.icloud.com.cn/setup/ws/1/accountLogin"))

        // Two-factor calls go to the host the sign-in used.
        await account.requestCodeOnTrustedDevices()
        XCTAssertEqual(FakeSignInServer.calls.last, "idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode")
    }

    func testChinaStaysOnItsOwnHostWhenItWorks() async throws {
        _ = try await signIn(.cn)
        XCTAssertFalse(FakeSignInServer.calls.contains { $0.hasPrefix("idmsa.apple.com/") })
    }

    func testServiceOutageIsNotReportedAsAWrongPassword() async throws {
        FakeSignInServer.replies["/signin/complete"] = (503, [String: Any]())
        do {
            _ = try await signIn(.com)
            XCTFail("expected an error")
        } catch ICloudError.http(let status, _) {
            XCTAssertEqual(status, 503)
        }

        FakeSignInServer.replies["/signin/complete"] = (401, [String: Any]())
        do {
            _ = try await signIn(.com)
            XCTFail("expected an error")
        } catch let error as ICloudError {
            XCTAssertEqual(error, .invalidCredentials)
        }
    }
}
