#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Renders Sable's 1024×1024 app icon: a blue squircle with a custom white
// "sparkle" mark. The sparkle is hand-built from Bézier curves (not an SF
// Symbol) so it's safe to use as an app icon. Run: swift scripts/make-icon.swift out.png

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }
ctx.setAllowsAntialiasing(true)

// Squircle geometry (centered, with margin for the Dock drop shadow).
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = rect.width * 0.2237
let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow beneath the squircle.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: NSColor.black.withAlphaComponent(0.22).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Blue gradient fill.
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let fill = CGGradient(
    colorsSpace: space,
    colors: [
        NSColor(srgbRed: 0.36, green: 0.64, blue: 1.0, alpha: 1).cgColor,
        NSColor(srgbRed: 0.0, green: 0.40, blue: 0.95, alpha: 1).cgColor,
    ] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(fill, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

// Soft top highlight.
let highlight = CGGradient(
    colorsSpace: space,
    colors: [NSColor.white.withAlphaComponent(0.20).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(highlight, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
ctx.restoreGState()

/// A 4-point sparkle centered at `center`, tips at `r`, with concave sides whose
/// curvature is set by `pinch` (smaller = thinner spikes).
func sparkle(center: CGPoint, r: CGFloat, pinch: CGFloat) -> CGPath {
    let c = r * pinch
    let p = CGMutablePath()
    let top = CGPoint(x: center.x, y: center.y + r)
    let right = CGPoint(x: center.x + r, y: center.y)
    let bottom = CGPoint(x: center.x, y: center.y - r)
    let left = CGPoint(x: center.x - r, y: center.y)
    p.move(to: top)
    p.addQuadCurve(to: right, control: CGPoint(x: center.x + c, y: center.y + c))
    p.addQuadCurve(to: bottom, control: CGPoint(x: center.x + c, y: center.y - c))
    p.addQuadCurve(to: left, control: CGPoint(x: center.x - c, y: center.y - c))
    p.addQuadCurve(to: top, control: CGPoint(x: center.x - c, y: center.y + c))
    p.closeSubpath()
    return p
}

ctx.setFillColor(NSColor.white.cgColor)
// Main sparkle, nudged slightly down-left to leave room for the accent sparkle.
ctx.addPath(sparkle(center: CGPoint(x: size * 0.46, y: size * 0.47), r: rect.width * 0.40, pinch: 0.17))
ctx.fillPath()
// Small accent sparkle, upper-right.
ctx.addPath(sparkle(center: CGPoint(x: size * 0.685, y: size * 0.70), r: rect.width * 0.115, pinch: 0.17))
ctx.fillPath()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else { fatalError("encode failed") }

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
