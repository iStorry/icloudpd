import Foundation

/// Minimal arbitrary-precision unsigned integer, just enough for SRP-6a
/// (multiplication, division with remainder, modular exponentiation).
/// Limbs are 32-bit, little-endian, and always normalized (no high zero limbs).
public struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    var limbs: [UInt32]

    public static let zero = BigUInt(limbs: [])

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    public init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    /// Big-endian bytes, like Python's `bytes_to_long`.
    public init<C: Collection>(bytes: C) where C.Element == UInt8 {
        var result: [UInt32] = []
        result.reserveCapacity(bytes.count / 4 + 1)
        let array = Array(bytes)
        var index = array.count
        while index > 0 {
            let start = max(0, index - 4)
            var limb: UInt32 = 0
            for byte in array[start..<index] {
                limb = (limb << 8) | UInt32(byte)
            }
            result.append(limb)
            index = start
        }
        self.init(limbs: result)
    }

    public init?(hex: String) {
        var bytes: [UInt8] = []
        var chars = Array(hex.filter { !$0.isWhitespace })
        if chars.count % 2 == 1 { chars.insert("0", at: 0) }
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(byte)
            i += 2
        }
        self.init(bytes: bytes)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    public var isZero: Bool { limbs.isEmpty }

    /// Minimal big-endian bytes, like Python's `long_to_bytes` (zero gives no bytes).
    public func serialize() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(limbs.count * 4)
        for limb in limbs.reversed() {
            out.append(UInt8(truncatingIfNeeded: limb >> 24))
            out.append(UInt8(truncatingIfNeeded: limb >> 16))
            out.append(UInt8(truncatingIfNeeded: limb >> 8))
            out.append(UInt8(truncatingIfNeeded: limb))
        }
        if let first = out.firstIndex(where: { $0 != 0 }) {
            return Array(out[first...])
        }
        return []
    }

    /// Big-endian bytes left-padded with zeros to `width`.
    public func serialize(paddedTo width: Int) -> [UInt8] {
        let raw = serialize()
        if raw.count >= width { return raw }
        return [UInt8](repeating: 0, count: width - raw.count) + raw
    }

    public var hexString: String {
        let bytes = serialize()
        if bytes.isEmpty { return "0" }
        var s = bytes.map { String(format: "%02x", $0) }.joined()
        if s.hasPrefix("0") { s.removeFirst() }
        return s
    }

    public var description: String { "0x" + hexString }

    var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return limbs.count * 32 - last.leadingZeroBitCount
    }

    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt32(index % 32)) & 1 == 1
    }

    // MARK: Comparison

    public static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        var i = lhs.limbs.count - 1
        while i >= 0 {
            if lhs.limbs[i] != rhs.limbs[i] { return lhs.limbs[i] < rhs.limbs[i] }
            i -= 1
        }
        return false
    }

    // MARK: Arithmetic

    public static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        let n = max(lhs.limbs.count, rhs.limbs.count)
        var out = [UInt32](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for i in 0..<n {
            let a = i < lhs.limbs.count ? UInt64(lhs.limbs[i]) : 0
            let b = i < rhs.limbs.count ? UInt64(rhs.limbs[i]) : 0
            let s = a + b + carry
            out[i] = UInt32(truncatingIfNeeded: s)
            carry = s >> 32
        }
        out[n] = UInt32(carry)
        return BigUInt(limbs: out)
    }

    /// Requires lhs >= rhs.
    public static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        precondition(lhs >= rhs, "BigUInt subtraction underflow")
        var out = lhs.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            let b = i < rhs.limbs.count ? Int64(rhs.limbs[i]) : 0
            var d = Int64(out[i]) - b - borrow
            if d < 0 {
                d += 1 << 32
                borrow = 1
            } else {
                borrow = 0
            }
            out[i] = UInt32(d)
        }
        return BigUInt(limbs: out)
    }

    public static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return .zero }
        var out = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0..<lhs.limbs.count {
            var carry: UInt64 = 0
            let a = UInt64(lhs.limbs[i])
            for j in 0..<rhs.limbs.count {
                let t = a * UInt64(rhs.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            out[i + rhs.limbs.count] = UInt32(carry)
        }
        return BigUInt(limbs: out)
    }

    public static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).remainder
    }

    public static func / (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        lhs.quotientAndRemainder(dividingBy: rhs).quotient
    }

    /// Knuth, TAOCP vol. 2, 4.3.1, Algorithm D.
    public func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "BigUInt division by zero")
        if self < divisor { return (.zero, self) }

        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var q = [UInt32](repeating: 0, count: limbs.count)
            var r: UInt64 = 0
            for i in stride(from: limbs.count - 1, through: 0, by: -1) {
                let cur = (r << 32) | UInt64(limbs[i])
                q[i] = UInt32(cur / d)
                r = cur % d
            }
            return (BigUInt(limbs: q), BigUInt(r))
        }

        let n = divisor.limbs.count
        let m = limbs.count - n
        let shift = divisor.limbs[n - 1].leadingZeroBitCount
        let vn = BigUInt.shiftLeft(divisor.limbs, by: shift, extraLimb: false)
        var un = BigUInt.shiftLeft(limbs, by: shift, extraLimb: true)
        var q = [UInt32](repeating: 0, count: m + 1)
        let base: UInt64 = 1 << 32
        let vTop = UInt64(vn[n - 1])
        let vNext = UInt64(vn[n - 2])

        for j in stride(from: m, through: 0, by: -1) {
            let num = (UInt64(un[j + n]) << 32) | UInt64(un[j + n - 1])
            var qhat = num / vTop
            var rhat = num % vTop
            while qhat >= base || qhat * vNext > ((rhat << 32) | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += vTop
                if rhat >= base { break }
            }

            // Multiply and subtract qhat * vn from un[j ... j+n].
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(vn[i]) + carry
                carry = p >> 32
                let t = Int64(un[i + j]) - borrow - Int64(p & 0xFFFF_FFFF)
                un[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = t < 0 ? 1 : 0
            }
            let t = Int64(un[j + n]) - borrow - Int64(carry)
            un[j + n] = UInt32(truncatingIfNeeded: t)

            if t < 0 {
                // qhat was one too large: add the divisor back.
                qhat -= 1
                var c: UInt64 = 0
                for i in 0..<n {
                    let s = UInt64(un[i + j]) + UInt64(vn[i]) + c
                    un[i + j] = UInt32(truncatingIfNeeded: s)
                    c = s >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + c)
            }
            q[j] = UInt32(truncatingIfNeeded: qhat)
        }

        let remainder = BigUInt.shiftRight(Array(un[0..<n]), by: shift)
        return (BigUInt(limbs: q), BigUInt(limbs: remainder))
    }

    private static func shiftLeft(_ limbs: [UInt32], by shift: Int, extraLimb: Bool) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: limbs.count + (extraLimb ? 1 : 0))
        if shift == 0 {
            for i in 0..<limbs.count { out[i] = limbs[i] }
            return out
        }
        var carry: UInt32 = 0
        for i in 0..<limbs.count {
            out[i] = (limbs[i] << UInt32(shift)) | carry
            carry = limbs[i] >> UInt32(32 - shift)
        }
        if extraLimb { out[limbs.count] = carry }
        return out
    }

    private static func shiftRight(_ limbs: [UInt32], by shift: Int) -> [UInt32] {
        if shift == 0 { return limbs }
        var out = [UInt32](repeating: 0, count: limbs.count)
        for i in 0..<limbs.count {
            let high: UInt32 = i + 1 < limbs.count ? limbs[i + 1] << UInt32(32 - shift) : 0
            out[i] = (limbs[i] >> UInt32(shift)) | high
        }
        return out
    }

    /// self^exponent mod modulus, left-to-right square-and-multiply.
    public func power(_ exponent: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(!modulus.isZero)
        if modulus == BigUInt(1) { return .zero }
        var result = BigUInt(1)
        let base = self % modulus
        let bits = exponent.bitWidth
        var i = bits - 1
        while i >= 0 {
            result = (result * result) % modulus
            if exponent.bit(i) {
                result = (result * base) % modulus
            }
            i -= 1
        }
        return result
    }
}
