import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ICloudDomain: String, Codable, CaseIterable, Sendable {
    case com
    case cn

    var authRoot: String { self == .cn ? "https://idmsa.apple.com.cn" : "https://idmsa.apple.com" }
    var authEndpoint: String { authRoot + "/appleauth/auth" }
    var home: String { self == .cn ? "https://www.icloud.com.cn" : "https://www.icloud.com" }
    var setup: String { self == .cn ? "https://setup.icloud.com.cn/setup/ws/1" : "https://setup.icloud.com/setup/ws/1" }
}

public enum SignInResult: Equatable, Sendable {
    /// Signed in and trusted; Photos can be used.
    case signedIn
    /// Apple wants a six-digit code. Call `requestCodeOnTrustedDevices()` or the SMS
    /// methods, then `verify(code:)`.
    case needsVerificationCode
    /// Older "two-step verification" accounts: pick a trusted device with `trustedDevices()`,
    /// call `sendVerificationCode(to:)`, then `verify(code:device:)`.
    case needsTwoStepVerification
}

/// A device that can receive a two-step verification code (older accounts).
public struct TrustedDevice: Identifiable, @unchecked Sendable {
    public let id: Int
    let raw: [String: Any]
    public var name: String {
        if let phone = raw["phoneNumber"] as? String { return "Text message to \(phone)" }
        return raw["deviceName"] as? String ?? "Device \(id + 1)"
    }
}

public struct TrustedPhoneNumber: Equatable, Identifiable, Sendable {
    public let id: Int
    public let obfuscatedNumber: String
}

/// An Apple ID signed in to iCloud. Port of pyicloud_ipd's PyiCloudService
/// (sign-in with SRP, two-factor codes, session trust, account login).
public final class ICloudAccount: @unchecked Sendable {
    public let appleID: String
    public let domain: ICloudDomain
    let http: HTTPClient

    /// The accountLogin / validate answer: dsInfo, webservices, trust flags.
    private(set) var accountData: [String: Any] = [:]

    // Apple's web sign-in widget key, the same constant icloudpd and icloud.com use.
    static let widgetKey = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"

    public init(appleID: String, domain: ICloudDomain = .com, store: SessionStore? = nil) {
        self.appleID = appleID
        self.domain = domain
        self.http = HTTPClient(homeEndpoint: domain.home,
                               store: store ?? SessionStore(directory: SessionStore.defaultDirectory(for: appleID)))
    }

    // MARK: Sign-in

    /// Signs in, reusing the saved session when it is still valid.
    /// - Parameter password: only needed when there is no valid saved session. Pass a closure so
    ///   the password is only read (for example from the Keychain) when it is really needed.
    public func signIn(password: () -> String?) async throws -> SignInResult {
        var signedIn = false
        if http.sessionData.sessionToken != nil {
            do {
                accountData = try await validateToken()
                signedIn = true
            } catch {
                // fall through to a full sign-in
            }
        }
        if !signedIn {
            guard let password = password(), !password.isEmpty else { throw ICloudError.passwordRequired }
            try await authenticateSRP(password: password)
            try await authenticateWithToken()
        }
        if requires2FA { return .needsVerificationCode }
        if requires2SA { return .needsTwoStepVerification }
        return .signedIn
    }

    /// Forgets the saved session and cookies.
    public func signOut() {
        http.resetSession()
        accountData = [:]
    }

    var dsInfo: [String: Any] { accountData["dsInfo"] as? [String: Any] ?? [:] }

    var isTrustedSession: Bool { accountData["hsaTrustedBrowser"] as? Bool ?? false }

    var requires2SA: Bool {
        (dsInfo["hsaVersion"] as? Int ?? 0) >= 1
            && ((accountData["hsaChallengeRequired"] as? Bool ?? false) || !isTrustedSession)
    }

    var requires2FA: Bool {
        (dsInfo["hsaVersion"] as? Int ?? 0) == 2
            && ((accountData["hsaChallengeRequired"] as? Bool ?? false) || !isTrustedSession)
            && (dsInfo["hasICloudQualifyingDevice"] as? Bool ?? false)
    }

    public var dsid: String? {
        if let s = dsInfo["dsid"] as? String { return s }
        if let i = dsInfo["dsid"] as? Int { return String(i) }
        return nil
    }

    public var fullName: String? { dsInfo["fullName"] as? String }

    func authHeaders(_ overrides: [String: String] = [:]) -> [String: String] {
        let session = http.sessionData
        var headers = [
            "Accept": "application/json, text/javascript",
            "Content-Type": "application/json",
            "X-Apple-OAuth-Client-Id": ICloudAccount.widgetKey,
            "X-Apple-OAuth-Client-Type": "firstPartyAuth",
            "X-Apple-OAuth-Redirect-URI": domain.home,
            "X-Apple-OAuth-Require-Grant-Code": "true",
            "X-Apple-OAuth-Response-Mode": "web_message",
            "X-Apple-OAuth-Response-Type": "code",
            "X-Apple-OAuth-State": session.clientID,
            "X-Apple-Widget-Key": ICloudAccount.widgetKey,
        ]
        if let scnt = session.scnt { headers["scnt"] = scnt }
        if let id = session.sessionID { headers["X-Apple-ID-Session-Id"] = id }
        headers.merge(overrides) { $1 }
        return headers
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func jsonBody(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func authenticateSRP(password: String) async throws {
        let client = SRPClient(accountName: appleID)
        let headers = authHeaders(["Origin": domain.authRoot, "Referer": domain.authRoot + "/"])

        // Step 1: send A, get back salt, B, c, iteration count and protocol.
        let initBody: [String: Any] = [
            "a": Data(client.publicKey).base64EncodedString(),
            "accountName": appleID,
            "protocols": ["s2k", "s2k_fo"],
        ]
        let initResponse = try await http.send("POST", url(domain.authEndpoint + "/signin/init"),
                                               headers: headers, body: jsonBody(initBody), checkErrors: false)
        if initResponse.status == 401 { throw ICloudError.invalidCredentials }
        guard initResponse.isOK else {
            throw ICloudError.http(status: initResponse.status, message: "Couldn't start the sign-in.")
        }
        let challenge = try initResponse.json()
        guard let saltString = challenge["salt"] as? String, let salt = Data(base64Encoded: saltString),
              let bString = challenge["b"] as? String, let b = Data(base64Encoded: bString),
              let c = challenge["c"] as? String,
              let iterations = challenge["iteration"] as? Int,
              let proto = challenge["protocol"] as? String
        else { throw ICloudError.unexpectedResponse("signin/init") }

        // Step 2: prove we know the password.
        let key = try SRPClient.derivePassword(password, protocol: proto, salt: Array(salt), iterations: iterations)
        let (m1, m2) = try client.processChallenge(passwordKey: key, salt: Array(salt), serverPublicKey: Array(b))
        var completeBody: [String: Any] = [
            "accountName": appleID,
            "c": c,
            "m1": Data(m1).base64EncodedString(),
            "m2": Data(m2).base64EncodedString(),
            "rememberMe": true,
            "trustTokens": [String](),
        ]
        if let trust = http.sessionData.trustToken { completeBody["trustTokens"] = [trust] }

        let complete = try await http.send("POST", url(domain.authEndpoint + "/signin/complete?isRememberMeEnabled=true"),
                                           headers: headers, body: jsonBody(completeBody), checkErrors: false)
        switch complete.status {
        case 409:
            break // two-factor code needed; accountLogin below tells us
        case 412:
            // Accounts without 2FA get "precondition failed" and must finish with repair/complete.
            try await http.send("POST", url(domain.authEndpoint + "/repair/complete"),
                                headers: authHeaders(), body: jsonBody([String: Any]()), checkErrors: false)
        case 400..<600:
            throw ICloudError.invalidCredentials
        default:
            break
        }
    }

    private func authenticateWithToken() async throws {
        let session = http.sessionData
        let body: [String: Any] = [
            "accountCountryCode": session.accountCountry ?? NSNull(),
            "dsWebAuthToken": session.sessionToken ?? NSNull(),
            "extended_login": true,
            "trustToken": session.trustToken ?? "",
        ]
        let response: HTTPResponse
        do {
            response = try await http.send("POST", url(domain.setup + "/accountLogin"),
                                           headers: ["Content-Type": "text/plain;charset=UTF-8"], body: jsonBody(body))
        } catch let error as ICloudError {
            if case .http(let status, _) = error, status == 421 || status == 450 || status == 401 {
                throw ICloudError.invalidCredentials
            }
            throw error
        }
        let data = try response.json()
        if let other = data["domainToUse"] as? String { throw ICloudError.wrongDomain(other) }
        guard data["dsInfo"] != nil else { throw ICloudError.unexpectedResponse("accountLogin had no account info") }
        accountData = data
    }

    private func validateToken() async throws -> [String: Any] {
        let response = try await http.send("POST", url(domain.setup + "/validate"),
                                           headers: ["Content-Type": "text/plain;charset=UTF-8"],
                                           body: Data("null".utf8))
        let data = try response.json()
        guard data["dsInfo"] != nil else { throw ICloudError.unexpectedResponse("validate") }
        return data
    }

    // MARK: Two-factor authentication

    /// Asks Apple to show a code on the account's trusted devices.
    /// Apple's newer web flow needs this PUT before a code is shown. Failure is not fatal.
    @discardableResult
    public func requestCodeOnTrustedDevices() async -> Bool {
        do {
            let response = try await http.send("PUT", url(domain.authEndpoint + "/verify/trusteddevice/securitycode"),
                                               headers: authHeaders(["Accept": "application/json"]), checkErrors: false)
            return response.isOK
        } catch {
            return false
        }
    }

    /// Verifies a code shown on a trusted device, then trusts this Mac so later
    /// launches skip the code (until Apple expires the trust, usually after a couple of months).
    public func verify(code: String) async throws {
        let body = ["securityCode": ["code": code]]
        let response = try await http.send("POST", url(domain.authEndpoint + "/verify/trusteddevice/securitycode"),
                                           headers: authHeaders(["Accept": "application/json"]),
                                           body: jsonBody(body), checkErrors: false)
        guard response.isOK else { throw ICloudError.wrongVerificationCode }
        try await trustSession()
        if requires2SA { throw ICloudError.wrongVerificationCode }
    }

    /// The phone numbers Apple can text a code to. An empty list together with no
    /// trusted devices means the account uses security keys.
    public func trustedPhoneNumbers() async throws -> [TrustedPhoneNumber] {
        let response = try await http.send("GET", url(domain.authEndpoint),
                                           headers: oauthHeaders(), checkErrors: false)
        guard response.status == 200 || response.status == 204 else { return [] }
        return TrustedPhoneParser.parse(html: response.text)
    }

    public func sendSMSCode(to phone: TrustedPhoneNumber) async throws {
        let body: [String: Any] = ["phoneNumber": ["id": phone.id], "mode": "sms"]
        let response = try await http.send("PUT", url(domain.authEndpoint + "/verify/phone"),
                                           headers: oauthHeaders(["Content-Type": "application/json; charset=utf-8"]),
                                           body: jsonBody(body), checkErrors: false)
        guard response.isOK else {
            throw ICloudError.http(status: response.status, message: "Apple didn't send the text message.")
        }
    }

    public func verifySMS(code: String, phone: TrustedPhoneNumber) async throws {
        let body: [String: Any] = ["phoneNumber": ["id": phone.id], "securityCode": ["code": code], "mode": "sms"]
        let response = try await http.send("POST", url(domain.authEndpoint + "/verify/phone/securitycode"),
                                           headers: oauthHeaders(["Content-Type": "application/json; charset=utf-8",
                                                                  "Accept": "application/json; charset=utf-8"]),
                                           body: jsonBody(body), checkErrors: false)
        guard response.isOK else { throw ICloudError.wrongVerificationCode }
        try await trustSession()
    }

    private func oauthHeaders(_ extra: [String: String] = [:]) -> [String: String] {
        let session = http.sessionData
        var headers = [
            "X-Apple-OAuth-Client-Id": ICloudAccount.widgetKey,
            "X-Apple-OAuth-Client-Type": "firstPartyAuth",
            "X-Apple-OAuth-Require-Grant-Code": "true",
            "X-Apple-Widget-Key": ICloudAccount.widgetKey,
            "X-Apple-OAuth-Redirect-URI": domain.home,
            "X-Apple-OAuth-State": session.clientID,
        ]
        if let scnt = session.scnt { headers["scnt"] = scnt }
        if let id = session.sessionID { headers["X-Apple-ID-Session-Id"] = id }
        headers.merge(extra) { $1 }
        return headers
    }

    private func trustSession() async throws {
        _ = try await http.send("GET", url(domain.authEndpoint + "/2sv/trust"), headers: authHeaders(), checkErrors: false)
        try await authenticateWithToken()
    }

    /// True when the account signs in with security keys instead of codes (Apple then lists
    /// no trusted phone numbers and sends an fsaChallenge).
    public func usesSecurityKeys() async -> Bool {
        guard let response = try? await http.send("GET", url(domain.authEndpoint),
                                                  headers: authHeaders(["Accept": "application/json"]), checkErrors: false),
              let data = try? response.json(),
              let challenge = data["fsaChallenge"] as? [String: Any] else { return false }
        return challenge["challenge"] != nil && challenge["keyHandles"] != nil && challenge["rpId"] != nil
    }

    // MARK: Two-step verification (older accounts)

    private var dsidQuery: String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "dsid", value: dsid ?? "")]
        return components.percentEncodedQuery ?? ""
    }

    public func trustedDevices() async throws -> [TrustedDevice] {
        let response = try await http.send("GET", url(domain.setup + "/listDevices?" + dsidQuery))
        let devices = try response.json()["devices"] as? [[String: Any]] ?? []
        return devices.enumerated().map { TrustedDevice(id: $0.offset, raw: $0.element) }
    }

    public func sendVerificationCode(to device: TrustedDevice) async throws {
        let response = try await http.send("POST", url(domain.setup + "/sendVerificationCode?" + dsidQuery),
                                           headers: ["Content-Type": "text/plain;charset=UTF-8"], body: jsonBody(device.raw))
        guard try response.json()["success"] as? Bool == true else {
            throw ICloudError.unexpectedResponse("Apple didn't send the code.")
        }
    }

    public func verify(code: String, device: TrustedDevice) async throws {
        var body = device.raw
        body["verificationCode"] = code
        body["trustBrowser"] = true
        do {
            _ = try await http.send("POST", url(domain.setup + "/validateVerificationCode?" + dsidQuery),
                                    headers: ["Content-Type": "text/plain;charset=UTF-8"], body: jsonBody(body))
        } catch ICloudError.server(let code, _) where code == "-21669" {
            throw ICloudError.wrongVerificationCode
        }
        try await authenticateWithToken()
        if requires2SA { throw ICloudError.wrongVerificationCode }
    }

    // MARK: Advanced Data Protection

    /// Replays the icloud.com sequence that unlocks data protected by Advanced Data Protection
    /// (`--adp-web-access`). The first time, Apple shows an approval request on your devices.
    /// - Parameter waiting: called once when the approval prompt has been sent.
    /// - Returns: false when iCloud never confirmed the unlock (`requestPCS` didn't report success).
    ///   Listing photos may then fail with "could not decrypt" errors.
    @discardableResult
    public func requestWebAccess(appName: String = "photos", timeout: TimeInterval = 120,
                                 waiting: (@Sendable () -> Void)? = nil) async throws -> Bool {
        let workflow = ["workflowUuid": UUID().uuidString.uppercased()]
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "dsid", value: dsid ?? ""),
                                 URLQueryItem(name: "clientId", value: http.sessionData.clientID)]
        let query = components.percentEncodedQuery ?? ""
        func call(_ method: String, _ name: String, _ body: [String: Any]?) async throws -> [String: Any] {
            let response = try await http.send(method, url("\(domain.setup)/\(name)?\(query)"),
                                               headers: ["Content-Type": "text/plain;charset=UTF-8"],
                                               body: body.map(jsonBody))
            return try response.json()
        }
        var state = try await call("POST", "requestWebAccessState", workflow)
        guard state["isWebAccessAllowed"] as? Bool == true else {
            throw ICloudError.webAccessDenied("Web access to iCloud data is off. Turn on \"Access iCloud Data on the Web\" on your iPhone or iPad.")
        }
        if state["isDeviceConsentedForPCS"] as? Bool != true {
            _ = try await call("POST", "enableDeviceConsentForPCS", workflow)
            waiting?()
            let deadline = Date().addingTimeInterval(timeout)
            while state["isDeviceConsentedForPCS"] as? Bool != true {
                if Date() > deadline {
                    throw ICloudError.webAccessDenied("The iCloud web access approval didn't arrive in time.")
                }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                state = try await call("POST", "requestWebAccessState", workflow)
            }
        }
        _ = try await call("GET", "generateSessionIdToken", nil)
        var pcs: [String: Any] = ["appName": appName, "isFinalAttempt": false, "derivedFromUserAction": true]
        pcs.merge(workflow) { $1 }
        var result = try await call("POST", "requestPCS", pcs)
        for _ in 0..<ICloudAccount.pcsAttempts where result["status"] as? String != "success" {
            try await Task.sleep(nanoseconds: ICloudAccount.pcsRetryDelay)
            pcs["derivedFromUserAction"] = false
            result = try await call("POST", "requestPCS", pcs)
        }
        return result["status"] as? String == "success"
    }

    static let pcsAttempts = 10
    nonisolated(unsafe) static var pcsRetryDelay: UInt64 = 3_000_000_000

    // MARK: Services

    func webserviceURL(_ key: String) throws -> String {
        guard let services = accountData["webservices"] as? [String: Any],
              let service = services[key] as? [String: Any],
              let url = service["url"] as? String
        else { throw ICloudError.serviceNotActivated("The iCloud \(key) service isn't available for this account.") }
        return url
    }

    /// The Photos service for the primary library. Throws until sign-in is complete.
    public func photos(ignoreIndexingState: Bool = false) async throws -> PhotosService {
        guard let dsid else { throw ICloudError.unexpectedResponse("not signed in") }
        let root = try webserviceURL("ckdatabasews")
        return try await PhotosService.open(serviceRoot: root, dsid: dsid, http: http, ignoreIndexingState: ignoreIndexingState)
    }
}

/// Reads the trusted phone numbers out of the `boot_args` JSON that Apple's
/// auth page embeds in a `<script type="application/json" class="boot_args">` tag.
enum TrustedPhoneParser {
    static func parse(html: String) -> [TrustedPhoneNumber] {
        guard let json = bootArgs(in: html),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        let twoSV = (root["direct"] as? [String: Any])?["twoSV"] as? [String: Any] ?? [:]
        var numbers = (twoSV["phoneNumberVerification"] as? [String: Any])?["trustedPhoneNumbers"] as? [[String: Any]] ?? []
        if numbers.isEmpty {
            let bridge = twoSV["bridgeInitiateData"] as? [String: Any] ?? [:]
            numbers = (bridge["phoneNumberVerification"] as? [String: Any])?["trustedPhoneNumbers"] as? [[String: Any]] ?? []
        }
        return numbers.compactMap { entry in
            guard let id = entry["id"] as? Int, let number = entry["obfuscatedNumber"] as? String else { return nil }
            return TrustedPhoneNumber(id: id, obfuscatedNumber: number.replacingOccurrences(of: "•", with: "*"))
        }
    }

    static func bootArgs(in html: String) -> String? {
        var searchRange = html.startIndex..<html.endIndex
        while let open = html.range(of: "<script", options: .caseInsensitive, range: searchRange) {
            guard let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex) else { return nil }
            let tag = html[open.upperBound..<tagEnd.lowerBound]
            guard let close = html.range(of: "</script>", options: .caseInsensitive, range: tagEnd.upperBound..<html.endIndex) else { return nil }
            let isBootArgs = tag.range(of: #"class\s*=\s*"boot_args""#, options: .regularExpression) != nil
                && tag.range(of: #"type\s*=\s*"application/json""#, options: .regularExpression) != nil
            if isBootArgs { return String(html[tagEnd.upperBound..<close.lowerBound]) }
            searchRange = close.upperBound..<html.endIndex
        }
        return nil
    }
}
