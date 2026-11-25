import Foundation

/// Client side of the SRP-6a exchange Apple's idmsa sign-in uses.
///
/// Matches icloudpd exactly: python `srp` with `rfc5054_enable()` and
/// `no_username_in_x()`, SHA-256, the RFC 5054 2048-bit group, and a password
/// that is first run through PBKDF2 (Apple's "s2k" / "s2k_fo" protocols).
public struct SRPClient {
    static let N = BigUInt(hex:
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
    )!
    static let g = BigUInt(2)
    static var width: Int { N.serialize().count }

    public enum SRPError: Error {
        case unsupportedProtocol(String)
        case badServerValue
    }

    public let accountName: String
    let a: BigUInt
    let A: BigUInt

    /// - Parameter privateKey: 32 bytes. Only pass one in tests; normally a random key is made.
    public init(accountName: String, privateKey: [UInt8]? = nil) {
        self.accountName = accountName
        if let privateKey {
            a = BigUInt(bytes: privateKey)
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            var rng = SystemRandomNumberGenerator()
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: .min ... .max, using: &rng) }
            bytes[0] |= 0x80 // like srp's get_random_of_length(32)
            a = BigUInt(bytes: bytes)
        }
        A = SRPClient.g.power(a, modulus: SRPClient.N)
    }

    /// The public value A to send to `signin/init`.
    public var publicKey: [UInt8] { A.serialize() }

    /// Apple's password derivation: PBKDF2-SHA256 over SHA-256(password)
    /// (as raw bytes for "s2k", as a lowercase hex string for "s2k_fo").
    public static func derivePassword(_ password: String, protocol proto: String, salt: [UInt8], iterations: Int) throws -> [UInt8] {
        let digest = Hashing.sha256(Array(password.utf8))
        let input: [UInt8]
        switch proto {
        case "s2k": input = digest
        case "s2k_fo": input = Array(digest.map { String(format: "%02x", $0) }.joined().utf8)
        default: throw SRPError.unsupportedProtocol(proto)
        }
        return Hashing.pbkdf2SHA256(password: input, salt: salt, iterations: iterations, keyLength: 32)
    }

    /// Computes the proofs M1 and M2 for `signin/complete`.
    public func processChallenge(passwordKey: [UInt8], salt: [UInt8], serverPublicKey: [UInt8]) throws -> (m1: [UInt8], m2: [UInt8]) {
        let N = SRPClient.N
        let g = SRPClient.g
        let width = SRPClient.width
        func H(_ bytes: [UInt8]) -> [UInt8] { Hashing.sha256(bytes) }

        let s = BigUInt(bytes: salt)
        let B = BigUInt(bytes: serverPublicKey)
        guard !(B % N).isZero else { throw SRPError.badServerValue }

        let k = BigUInt(bytes: H(N.serialize(paddedTo: width) + g.serialize(paddedTo: width)))
        let u = BigUInt(bytes: H(A.serialize(paddedTo: width) + B.serialize(paddedTo: width)))
        guard !u.isZero else { throw SRPError.badServerValue }

        // x = H(s | H(":" | password)), username left out (no_username_in_x)
        let x = BigUInt(bytes: H(s.serialize() + H(Array(":".utf8) + passwordKey)))
        let v = g.power(x, modulus: N)

        // S = (B - k*v) ^ (a + u*x) mod N, kept non-negative
        let kv = (k * v) % N
        let base = ((B % N) + N - kv) % N
        let S = base.power(a + u * x, modulus: N)
        let K = H(S.serialize())

        let hN = H(N.serialize())
        let hg = H(g.serialize(paddedTo: width))
        let hNxorg = zip(hN, hg).map { $0 ^ $1 }
        let hI = H(Array(accountName.utf8))
        var m1Input: [UInt8] = hNxorg
        m1Input += hI
        m1Input += s.serialize()
        m1Input += A.serialize()
        m1Input += B.serialize()
        m1Input += K
        let m1 = H(m1Input)
        var m2Input: [UInt8] = A.serialize()
        m2Input += m1
        m2Input += K
        let m2 = H(m2Input)
        return (m1, m2)
    }
}
