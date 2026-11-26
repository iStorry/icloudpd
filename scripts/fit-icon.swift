// Fits a square icon illustration (a coloured or dark tile on a flat, pale backdrop) onto the macOS icon grid.
//
//   swift scripts/fit-icon.swift <in.png> <out.png> [inset]
//
// It finds the tile by its colour, crops a little inside its edge (inset, a fraction of the tile's
// size, default 0.03) so none of the backdrop survives, scales it to the 824 px squircle in the middle
// of a transparent 1024 px canvas and adds the grid's standard drop shadow.
import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count >= 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: swift scripts/fit-icon.swift <in.png> <out.png> [inset]\n".data(using: .utf8)!)
    exit(2)
}
let inset = args.count >= 4 ? Double(args[3])! : 0.03

// Read the pixels.
let w = cg.width, h = cg.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

// The tile is either saturated (a coloured tile) or dark (a graphite one). The pale backdrop and the
// grey slab edge some illustrations give the tile are neither, so both get cropped away.
func isTile(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
    let hi = max(r, g, b), lo = min(r, g, b)
    let saturation = hi == 0 ? 0 : (hi - lo) / hi
    let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return saturation > 0.35 || luminance < 90
}
// Scan the middle row and column so the cloud and print on the tile don't matter.
func span(_ count: Int, _ hit: (Int) -> Bool) -> (Int, Int) {
    let first = (0..<count).first(where: hit)!
    let last = (0..<count).last(where: hit)!
    return (first, last)
}
var xs: [(Int, Int)] = [], ys: [(Int, Int)] = []
for frac in stride(from: 0.3, through: 0.7, by: 0.1) {
    let row = Int(Double(h) * frac), col = Int(Double(w) * frac)
    xs.append(span(w) { isTile($0, row) })
    ys.append(span(h) { isTile(col, $0) })
}
let left = xs.map(\.0).min()!, right = xs.map(\.1).max()!
let top = ys.map(\.0).min()!, bottom = ys.map(\.1).max()!
var tile = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
tile = tile.insetBy(dx: tile.width * inset, dy: tile.height * inset)
print("Tile found at \(Int(tile.minX)),\(Int(tile.minY)) size \(Int(tile.width))×\(Int(tile.height))")

let cropped = cg.cropping(to: tile)!

struct Fitted: View {
    let image: CGImage
    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: 824, height: 824)
            .clipShape(.rect(cornerRadius: 185, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 10)
            .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Fitted(image: cropped))
    renderer.scale = 1
    renderer.isOpaque = false
    let out = renderer.cgImage!
    try! NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: args[2]))
    print("Wrote \(args[2])")
}
