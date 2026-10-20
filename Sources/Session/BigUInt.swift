// 自带的小型无符号大整数（SRP 用）。正确优先；modPow 走 Montgomery（要求模数为奇数）。
import Foundation

package struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    /// 小端 64 位分片，无多余的高位零。
    package private(set) var limbs: [UInt64]

    package init() { limbs = [] }

    package init(_ value: UInt64) { limbs = value == 0 ? [] : [value] }

    private init(normalizing raw: [UInt64]) {
        var l = raw
        while let last = l.last, last == 0 { l.removeLast() }
        limbs = l
    }

    /// 大端字节。
    package init(bytes: [UInt8]) {
        var l: [UInt64] = []
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 8)
            var limb: UInt64 = 0
            for b in bytes[start ..< i] { limb = (limb << 8) | UInt64(b) }
            l.append(limb)
            i = start
        }
        self.init(normalizing: l)
    }

    package init(hex: String) {
        var digits = hex.filter { $0.isHexDigit }
        if digits.count % 2 == 1 { digits = "0" + digits }
        var bytes: [UInt8] = []
        var idx = digits.startIndex
        while idx < digits.endIndex {
            let next = digits.index(idx, offsetBy: 2)
            bytes.append(UInt8(digits[idx ..< next], radix: 16)!)
            idx = next
        }
        self.init(bytes: bytes)
    }

    package var isZero: Bool { limbs.isEmpty }

    package var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    package func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    /// 最短大端字节（零 -> [0]，同 MacPlay 的 toBuf(0n)）。
    package var bytes: [UInt8] {
        guard !limbs.isEmpty else { return [0] }
        var out: [UInt8] = []
        for (i, limb) in limbs.reversed().enumerated() {
            for shift in stride(from: 56, through: 0, by: -8) {
                let b = UInt8((limb >> UInt64(shift)) & 0xff)
                if i == 0, out.isEmpty, b == 0 { continue }
                out.append(b)
            }
        }
        return out
    }

    /// 左补零到至少 `count` 字节（已更长则原样）。
    package func padded(to count: Int) -> [UInt8] {
        let b = bytes
        return b.count >= count ? b : [UInt8](repeating: 0, count: count - b.count) + b
    }

    package var description: String { bytes.map { String(format: "%02x", $0) }.joined() }

    package static func < (a: BigUInt, b: BigUInt) -> Bool { compare(a.limbs, b.limbs) < 0 }

    private static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    package static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let (long, short) = a.limbs.count >= b.limbs.count ? (a.limbs, b.limbs) : (b.limbs, a.limbs)
        var out = [UInt64](repeating: 0, count: long.count + 1)
        var carry: UInt64 = 0
        for i in 0 ..< long.count {
            let (s1, o1) = long[i].addingReportingOverflow(i < short.count ? short[i] : 0)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        out[long.count] = carry
        return BigUInt(normalizing: out)
    }

    /// a - b，要求 a >= b。
    package static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(a >= b, "BigUInt 下溢")
        var out = a.limbs
        var borrow: UInt64 = 0
        for i in 0 ..< out.count {
            let (d1, o1) = out[i].subtractingReportingOverflow(i < b.limbs.count ? b.limbs[i] : 0)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(normalizing: out)
    }

    package static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var out = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        out.withUnsafeMutableBufferPointer { o in
            a.limbs.withUnsafeBufferPointer { x in
                b.limbs.withUnsafeBufferPointer { y in
                    for i in 0 ..< x.count {
                        var carry: UInt64 = 0
                        let xi = x[i]
                        for j in 0 ..< y.count {
                            let (hi, lo) = xi.multipliedFullWidth(by: y[j])
                            let (s1, c1) = lo.addingReportingOverflow(o[i + j])
                            let (s2, c2) = s1.addingReportingOverflow(carry)
                            o[i + j] = s2
                            carry = hi &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
                        }
                        o[i + y.count] = carry
                    }
                }
            }
        }
        return BigUInt(normalizing: out)
    }

    package static func << (a: BigUInt, bits: Int) -> BigUInt {
        if a.isZero { return a }
        let limbShift = bits / 64
        let bitShift = UInt64(bits % 64)
        var out = [UInt64](repeating: 0, count: a.limbs.count + limbShift + 1)
        for i in 0 ..< a.limbs.count {
            out[i + limbShift] |= a.limbs[i] << bitShift
            if bitShift > 0 { out[i + limbShift + 1] |= a.limbs[i] >> (64 - bitShift) }
        }
        return BigUInt(normalizing: out)
    }

    /// 余数（逐位移位减法，正确优先；只在少数几次大数约简里用）。
    package static func % (a: BigUInt, m: BigUInt) -> BigUInt {
        precondition(!m.isZero, "模数为零")
        if a < m { return a }
        let n = m.limbs.count
        var r = [UInt64](repeating: 0, count: n + 1)
        let mm = m.limbs
        var i = a.bitWidth - 1
        while i >= 0 {
            var carry: UInt64 = a.bit(i) ? 1 : 0
            for k in 0 ... n {
                let v = r[k]
                r[k] = (v << 1) | carry
                carry = v >> 63
            }
            if geq(r, mm) {
                var borrow: UInt64 = 0
                for k in 0 ... n {
                    let (d1, o1) = r[k].subtractingReportingOverflow(k < n ? mm[k] : 0)
                    let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                    r[k] = d2
                    borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
                }
            }
            i -= 1
        }
        return BigUInt(normalizing: r)
    }

    private static func geq(_ r: [UInt64], _ m: [UInt64]) -> Bool {
        let n = m.count
        if r[n] != 0 { return true }
        var i = n - 1
        while i >= 0 {
            if r[i] != m[i] { return r[i] > m[i] }
            i -= 1
        }
        return true
    }

    /// base^exp mod modulus。模数必须为奇数（SRP 群都是）。Montgomery CIOS，64 位分片。
    /// 热循环用 while + 裸指针 + 比较式进位：Debug 构建里 for-in 区间、下标检查和 addingReportingOverflow 都是实打实的调用，
    /// 这样写能让 3072 位 modPow 在 Debug 下保持在 2 秒内。
    package func modPow(_ exp: BigUInt, modulus: BigUInt) -> BigUInt {
        precondition(modulus.limbs.first.map { $0 & 1 == 1 } ?? false, "modPow 需要奇数模数")
        if exp.isZero { return BigUInt(1) % modulus }
        let s = modulus.limbs.count
        let n = modulus.limbs
        // n' = -n^-1 mod 2^64（Newton 迭代）
        var inv: UInt64 = 1
        for _ in 0 ..< 6 { inv = inv &* (2 &- n[0] &* inv) }
        let nPrime = 0 &- inv

        func pad(_ b: BigUInt) -> [UInt64] { b.limbs + [UInt64](repeating: 0, count: s - b.limbs.count) }
        let baseM = pad((self << (64 * s)) % modulus)                   // base * R mod N
        var acc = pad((BigUInt(1) << (64 * s)) % modulus)               // 1 * R mod N
        var tmp = [UInt64](repeating: 0, count: s)
        var t = [UInt64](repeating: 0, count: s + 2)
        var one = [UInt64](repeating: 0, count: s)
        one[0] = 1

        func montMul(_ a: UnsafePointer<UInt64>, _ b: UnsafePointer<UInt64>, _ n: UnsafePointer<UInt64>,
                     _ t: UnsafeMutablePointer<UInt64>, _ out: UnsafeMutablePointer<UInt64>) {
            var k = 0
            while k < s + 2 { t[k] = 0; k += 1 }
            var i = 0
            while i < s {
                let bi = b[i]
                var c: UInt64 = 0
                var j = 0
                while j < s {
                    let (hi, lo) = a[j].multipliedFullWidth(by: bi)
                    var sum = lo &+ t[j]
                    var h = hi &+ (sum < lo ? 1 : 0)
                    sum = sum &+ c
                    h = h &+ (sum < c ? 1 : 0)
                    t[j] = sum
                    c = h
                    j += 1
                }
                let top = t[s] &+ c
                t[s] = top
                t[s + 1] = top < c ? 1 : 0
                let m = t[0] &* nPrime
                let (hi0, lo0) = m.multipliedFullWidth(by: n[0])
                c = hi0 &+ ((lo0 &+ t[0]) < lo0 ? 1 : 0)
                j = 1
                while j < s {
                    let (hi, lo) = m.multipliedFullWidth(by: n[j])
                    var sum = lo &+ t[j]
                    var h = hi &+ (sum < lo ? 1 : 0)
                    sum = sum &+ c
                    h = h &+ (sum < c ? 1 : 0)
                    t[j - 1] = sum
                    c = h
                    j += 1
                }
                let e = t[s] &+ c
                t[s - 1] = e
                t[s] = t[s + 1] &+ (e < c ? 1 : 0)
                i += 1
            }
            var ge = t[s] != 0
            if !ge {
                ge = true
                var q = s - 1
                while q >= 0 {
                    if t[q] != n[q] { ge = t[q] > n[q]; break }
                    q -= 1
                }
            }
            if ge {
                var borrow: UInt64 = 0
                var q = 0
                while q < s {
                    let d = t[q] &- n[q]
                    let b1: UInt64 = t[q] < n[q] ? 1 : 0
                    let d2 = d &- borrow
                    let b2: UInt64 = d < borrow ? 1 : 0
                    t[q] = d2
                    borrow = b1 &+ b2
                    q += 1
                }
            }
            k = 0
            while k < s { out[k] = t[k]; k += 1 }
        }

        n.withUnsafeBufferPointer { np in
        baseM.withUnsafeBufferPointer { bp in
        one.withUnsafeBufferPointer { onep in
        t.withUnsafeMutableBufferPointer { tp in
        tmp.withUnsafeMutableBufferPointer { op in
        acc.withUnsafeMutableBufferPointer { ap in
            let nB = np.baseAddress!, bB = bp.baseAddress!, tB = tp.baseAddress!, oB = op.baseAddress!, aB = ap.baseAddress!
            var i = exp.bitWidth - 1
            while i >= 0 {
                montMul(aB, aB, nB, tB, oB)
                var k = 0
                while k < s { aB[k] = oB[k]; k += 1 }
                if exp.bit(i) {
                    montMul(aB, bB, nB, tB, oB)
                    k = 0
                    while k < s { aB[k] = oB[k]; k += 1 }
                }
                i -= 1
            }
            montMul(aB, onep.baseAddress!, nB, tB, oB)
        }}}}}}
        return BigUInt(normalizing: tmp)
    }
}
