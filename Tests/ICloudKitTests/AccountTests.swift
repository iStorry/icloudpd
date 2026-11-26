import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ICloudKit

/// A fake setup.icloud.com / idmsa.apple.com: answers the calls a test sets up, by path suffix.
final class FakeAccountServer: URLProtocol {
    struct Reply {
        var status = 200
        var json: Any = [String: Any]()
    }

    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var calls: [String] = []
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        replies = [:]
        calls = []
    }

    /// Replies for a path ending in `suffix`, used in turn; the last one repeats.
    static func on(_ suffix: String, _ replies: Reply...) {
        lock.lock(); defer { lock.unlock() }
        self.replies[suffix] = replies
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["setup.icloud.com", "setup.icloud.com.cn", "idmsa.apple.com", "idmsa.apple.com.cn"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let path = request.url!.path
        FakeAccountServer.lock.lock()
        FakeAccountServer.calls.append(path)
        var reply = Reply(status: 404)
        if let key = FakeAccountServer.replies.keys.first(where: { path.hasSuffix($0) }),
           var list = FakeAccountServer.replies[key], !list.isEmpty {
            reply = list.count > 1 ? list.removeFirst() : list[0]
            FakeAccountServer.replies[key] = list
        }
        FakeAccountServer.lock.unlock()
        let body = (try? JSONSerialization.data(withJSONObject: reply.json)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class AccountTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        HTTPClient.protocolClassesForTesting = [FakeAccountServer.self]
        ICloudAccount.pcsRetryDelay = 1_000
        FakeAccountServer.reset()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func account(_ domain: ICloudDomain = .com) -> ICloudAccount {
        ICloudAccount(appleID: "someone@example.com", domain: domain, store: SessionStore(directory: dir))
    }

    func testWebAccessReportsWhetherICloudConfirmedIt() async throws {
        FakeAccountServer.on("/requestWebAccessState", .init(json: ["isWebAccessAllowed": true, "isDeviceConsentedForPCS": true]))
        FakeAccountServer.on("/generateSessionIdToken", .init())
        FakeAccountServer.on("/requestPCS", .init(json: ["status": "retry"]), .init(json: ["status": "success"]))
        let confirmed = try await account().requestWebAccess()
        XCTAssertTrue(confirmed)
        XCTAssertEqual(FakeAccountServer.calls.filter { $0.hasSuffix("/requestPCS") }.count, 2)

        FakeAccountServer.reset()
        FakeAccountServer.on("/requestWebAccessState", .init(json: ["isWebAccessAllowed": true, "isDeviceConsentedForPCS": true]))
        FakeAccountServer.on("/generateSessionIdToken", .init())
        FakeAccountServer.on("/requestPCS", .init(json: ["status": "retry"]))
        let refused = try await account().requestWebAccess()
        XCTAssertFalse(refused)
        XCTAssertEqual(FakeAccountServer.calls.filter { $0.hasSuffix("/requestPCS") }.count, 1 + ICloudAccount.pcsAttempts)
    }

    func testDecryptFailureExplainsAdvancedDataProtection() {
        XCTAssertThrowsError(try HTTPClient.checkBody(["serverErrorCode": "INTERNAL_ERROR", "reason": "could not decrypt bytes"])) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("Advanced Data Protection"), text)
            XCTAssertTrue(text.contains("could not decrypt bytes"), text)
        }
        XCTAssertFalse(ICloudError.server(code: "INTERNAL_ERROR", reason: "other").localizedDescription.contains("Advanced Data Protection"))
    }
}
