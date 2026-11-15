// 12 面總表：一排排成 4×3，每格下面是名字（RC 閘門②「12 面總表點頭」用）。
// 用法：swiftc -O -parse-as-library tooling/contact-sheet.swift -o .build/contact-sheet
//       .build/contact-sheet out.png name=in.png name2=in2.png …
// 只讀 PNG、寫一張 PNG；不碰偏好與網路。
import AppKit
@main struct S { static func main() {
  let a = CommandLine.arguments
  guard a.count >= 3 else { print("contact-sheet <out.png> name=in.png …"); exit(2) }
  var cells: [(String, CGImage)] = []
  for spec in a[2...] {
    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2, let img = NSImage(contentsOfFile: parts[1]),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      print("ERR \(spec)"); exit(1)
    }
    cells.append((parts[0], cg))
  }
  let side = 256, gap = 16, label: CGFloat = 40, cols = 4
  let rows = (cells.count + cols - 1) / cols
  let w = CGFloat(cols * side + (cols + 1) * gap), h = CGFloat(rows * (side + Int(label)) + gap)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let g = NSGraphicsContext.current!.cgContext
  g.setFillColor(NSColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 1).cgColor)
  g.fill(CGRect(x: 0, y: 0, width: w, height: h))
  for (i, cell) in cells.enumerated() {
    let c = i % cols, r = i / cols
    let x = CGFloat(gap + c * (side + gap)), y = h - CGFloat((r + 1) * (side + Int(label)) + gap) + label
    let rect = CGRect(x: x, y: y, width: CGFloat(side), height: CGFloat(side))
    g.saveGState(); g.addRect(rect); g.clip()
    g.translateBy(x: rect.minX, y: rect.minY); g.scaleBy(x: rect.width / CGFloat(cell.1.width), y: rect.height / CGFloat(cell.1.height))
    g.draw(cell.1, in: CGRect(x: 0, y: 0, width: CGFloat(cell.1.width), height: CGFloat(cell.1.height)))
    g.restoreGState()
    let s = NSAttributedString(string: cell.0, attributes: [
      .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
      .foregroundColor: NSColor(white: 0.92, alpha: 1)])
    let sz = s.size()
    s.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.minY - sz.height - 8))
  }
  NSGraphicsContext.restoreGraphicsState()
  try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: a[1]))
  print("contact-sheet \(cells.count) faces → \(a[1])")
} }
