// Draws the app icon on the macOS icon grid: a 1024 px transparent canvas with the 824 px tile in
// the middle and the grid's drop shadow. A dark tile like the app's own and a small stack of photos.
//
//   swift scripts/draw-icon.swift <out.png>
import AppKit
import SwiftUI

let tileBottom = Color(red: 0.05, green: 0.05, blue: 0.06)

/// A dusk landscape: sky, sun, far ridge and near hill.
struct Landscape: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(stops: [
                    .init(color: Color(red: 0.16, green: 0.25, blue: 0.62), location: 0),
                    .init(color: Color(red: 0.55, green: 0.42, blue: 0.78), location: 0.45),
                    .init(color: Color(red: 1.0, green: 0.62, blue: 0.45), location: 0.75),
                    .init(color: Color(red: 1.0, green: 0.80, blue: 0.55), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                Circle()
                    .fill(Color(red: 1, green: 0.9, blue: 0.68))
                    .frame(width: w * 0.2, height: w * 0.2)
                    .shadow(color: Color(red: 1, green: 0.85, blue: 0.6).opacity(0.9), radius: w * 0.06)
                    .position(x: w * 0.68, y: h * 0.5)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.64))
                    p.addLine(to: CGPoint(x: w * 0.24, y: h * 0.44))
                    p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.6))
                    p.addLine(to: CGPoint(x: w * 0.62, y: h * 0.4))
                    p.addLine(to: CGPoint(x: w, y: h * 0.66))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.36, green: 0.27, blue: 0.56))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.8))
                    p.addQuadCurve(to: CGPoint(x: w, y: h * 0.74), control: CGPoint(x: w * 0.45, y: h * 0.58))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(Color(red: 0.16, green: 0.12, blue: 0.3))
            }
        }
    }
}

/// A photo behind the front one: a plain card, so the stack reads at small sizes.
func backCard(_ shade: Double, angle: Double, x: CGFloat, y: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 46, style: .continuous)
        .fill(Color(white: shade))
        .overlay(RoundedRectangle(cornerRadius: 46, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 3))
        .frame(width: 470, height: 380)
        .rotationEffect(.degrees(angle))
        .offset(x: x, y: y)
}

struct Icon: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.16, blue: 0.19), tileBottom], startPoint: .top, endPoint: .bottom)
            backCard(0.25, angle: -11, x: -24, y: -24)
            backCard(0.33, angle: 7, x: 22, y: -16)
            Landscape()
                .frame(width: 520, height: 416)
                .clipShape(RoundedRectangle(cornerRadius: 50, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 50, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 3))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                .offset(y: 10)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 2))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
        .frame(width: 1024, height: 1024)
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift scripts/draw-icon.swift <out.png>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("couldn't draw the icon\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: out)
}
