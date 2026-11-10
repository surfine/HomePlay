import AppKit
@main struct D { static func main() {
  let a = CommandLine.arguments
  guard a.count >= 3 else { print("imgdiff <a.png> <b.png> [threshold]"); exit(2) }
  let th = a.count > 3 ? Double(a[3]) ?? 0.02 : 0.02
  func load(_ p: String) -> (Int, Int, [UInt8])? {
    guard let i = NSImage(contentsOfFile: p), let t = i.tiffRepresentation, let r = NSBitmapImageRep(data: t) else { return nil }
    let w = r.pixelsWide, h = r.pixelsHigh
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
      guard let c = r.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
      let o = (y * w + x) * 4
      out[o] = UInt8(max(0, min(255, c.redComponent * 255)))
      out[o+1] = UInt8(max(0, min(255, c.greenComponent * 255)))
      out[o+2] = UInt8(max(0, min(255, c.blueComponent * 255)))
      out[o+3] = UInt8(max(0, min(255, c.alphaComponent * 255)))
    }}
    return (w, h, out)
  }
  guard let A = load(a[1]), let B = load(a[2]) else { print("ERR load"); exit(1) }
  guard A.0 == B.0 && A.1 == B.1 else { print("DIFF size \(A.0)x\(A.1) vs \(B.0)x\(B.1)"); exit(1) }
  var sum = 0.0, over = 0
  for i in stride(from: 0, to: A.2.count, by: 4) {
    let d = (abs(Int(A.2[i]) - Int(B.2[i])) + abs(Int(A.2[i+1]) - Int(B.2[i+1])) + abs(Int(A.2[i+2]) - Int(B.2[i+2]))) / 3
    sum += Double(d) / 255
    if d > 10 { over += 1 }
  }
  let n = Double(A.0 * A.1)
  let mean = sum / n, frac = Double(over) / n
  let ok = mean <= th && frac <= th * 8
  print(String(format: "%@ mean=%.4f changed=%.2f%%", ok ? "PASS" : "FAIL", mean, frac * 100))
  exit(ok ? 0 : 1)
} }
