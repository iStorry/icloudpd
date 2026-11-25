import Foundation

public enum ICloudError: LocalizedError, Equatable {
    /// Apple refused the Apple ID / password.
    case invalidCredentials
    /// A saved session is gone and no password was given.
    case passwordRequired
    /// The account uses the legacy two-step verification, which this app does not support yet.
    case twoStepNotSupported
    /// The account only signs in with security keys, which this app does not support yet.
    case securityKeysNotSupported
    case wrongVerificationCode
    /// Apple wants the other domain (icloud.com vs icloud.com.cn).
    case wrongDomain(String)
    case serviceNotActivated(String)
    case libraryIndexing
    case http(status: Int, message: String)
    case server(code: String, reason: String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Apple didn't accept this Apple ID and password."
        case .passwordRequired:
            return "Your saved session has expired. Enter your password to sign in again."
        case .twoStepNotSupported:
            return "This Apple ID uses the older two-step verification, which isn't supported yet."
        case .securityKeysNotSupported:
            return "This Apple ID signs in with security keys, which aren't supported yet."
        case .wrongVerificationCode:
            return "That verification code wasn't accepted."
        case .wrongDomain(let domain):
            return "Apple asks this account to use \(domain). Change the region in settings."
        case .serviceNotActivated(let reason):
            return reason
        case .libraryIndexing:
            return "iCloud Photos is still indexing this library. Try again later."
        case .http(let status, let message):
            return "iCloud returned HTTP \(status). \(message)"
        case .server(let code, let reason):
            if code == "ACCESS_DENIED" {
                return "iCloud denied access (\(reason)). Check that \"Access iCloud Data on the Web\" is on, and that Advanced Data Protection is off."
            }
            return "iCloud error \(code): \(reason)"
        case .unexpectedResponse(let what):
            return "Unexpected response from iCloud: \(what)"
        }
    }
}
