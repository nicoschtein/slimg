#!/usr/bin/env swift
//
//  generate-icons.swift
//  Slimg — reproducible icon + web asset generator
//
//  Draws the Slimg "squeeze" icon programmatically (no rsvg/cairo/ImageMagick)
//  and emits:
//    • Resources/AppIcon.icns         — native macOS app icon (built via iconutil)
//    • brand/web/favicon.svg          — vector logomark (transparent bg)
//    • brand/web/favicon-32.png       — 32×32 squircle icon
//    • brand/web/favicon-180.png      — 180×180 apple-touch icon
//    • brand/web/icon-512.png         — 512×512 squircle icon
//    • brand/web/og-image.png         — 1200×630 social card
//
//  Run from the repo root:   swift Scripts/generate-icons.swift
//  Requires: macOS 13+, swift 6.x, iconutil (system).
//
//  Geometry reference: brand/icon-master.svg (1024px canvas).
//  Idempotent: re-running overwrites outputs deterministically.
//

import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Brand constants (sRGB)

/// Gradient stops for the Slimg gradient: 135° topLeft → bottomRight.
let gradStart = (r: 0.1765, g: 0.8314, b: 0.7490) // #2DD4BF Teal 400
let gradEnd = (r: 0.0235, g: 0.7137, b: 0.8314) // #06B6D4 Cyan 500
let ink950 = (r: 0.0392, g: 0.0588, b: 0.1020) // #0A0F1A
let slate400 = (r: 0.5804, g: 0.6392, b: 0.7216) // #94A3B8

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func cg(_ c: (r: Double, g: Double, b: Double), _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(c.r), CGFloat(c.g), CGFloat(c.b), a])!
}

// MARK: - Paths & geometry

/// macOS continuous-corner squircle (superellipse), full-bleed in `rect`.
/// Sampled superellipse with exponent `n` (~5 matches Apple's continuous corner feel).
/// Centered superellipse: |x/a|^n + |y/b|^n = 1.
func squirclePath(in rect: CGRect, n: CGFloat = 5.0, samples: Int = 720) -> CGPath {
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let path = CGMutablePath()
    let inv = 2.0 / n
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples) * 2 * .pi
        let ct = cos(t), st = sin(t)
        // Signed power keeps the superellipse parameterization correct per quadrant.
        let x = a * CGFloat(copysign(pow(Double(abs(ct)), Double(inv)), Double(ct)))
        let y = b * CGFloat(copysign(pow(Double(abs(st)), Double(inv)), Double(st)))
        let p = CGPoint(x: cx + x, y: cy + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

/// The white "squeeze" mark, drawn in 1024-space coordinates with a TOP-LEFT
/// origin (SVG convention). The caller supplies a context already flipped so
/// that y grows downward, matching icon-master.svg directly.
func drawMark(in ctx: CGContext, scale: CGFloat) {
    // Coordinates straight from brand/icon-master.svg (1024 canvas).
    let strokeW: CGFloat = 92 * scale

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }

    ctx.saveGState()
    ctx.setStrokeColor(CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!)
    ctx.setLineWidth(strokeW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Left chevron `>` : 300,330 → 410,512 → 300,694
    ctx.beginPath()
    ctx.move(to: pt(300, 330))
    ctx.addLine(to: pt(410, 512))
    ctx.addLine(to: pt(300, 694))
    ctx.strokePath()

    // Right chevron `<` : 724,330 → 614,512 → 724,694
    ctx.beginPath()
    ctx.move(to: pt(724, 330))
    ctx.addLine(to: pt(614, 512))
    ctx.addLine(to: pt(724, 694))
    ctx.strokePath()

    // Central bar: rect x466 y356 w92 h312 rx46
    let bar = CGRect(x: 466 * scale, y: 356 * scale, width: 92 * scale, height: 312 * scale)
    let barPath = CGPath(roundedRect: bar, cornerWidth: 46 * scale, cornerHeight: 46 * scale, transform: nil)
    ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!)
    ctx.addPath(barPath)
    ctx.fillPath()

    ctx.restoreGState()
}

// MARK: - Context helpers

/// Create an sRGB premultiplied-alpha bitmap context of `px` × `px`.
func makeContext(_ px: Int) -> CGContext {
    let ctx = CGContext(
        data: nil,
        width: px, height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

/// Flip a context so drawing uses a top-left origin (SVG/UIKit convention) at
/// the given pixel size. Call once after creating the context.
func flipTopLeft(_ ctx: CGContext, px: CGFloat) {
    ctx.translateBy(x: 0, y: px)
    ctx.scaleBy(x: 1, y: -1)
}

/// Draw the full squircle app icon (gradient + top-light + mark) at `px` px.
/// `withSquircle` false → full-bleed gradient with no corner shaping (unused
/// here but kept for flexibility). Returns a CGImage.
func renderAppIcon(px: Int) -> CGImage {
    let ctx = makeContext(px)
    let size = CGFloat(px)
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let scale = size / 1024.0

    // --- Background squircle, clipped ---
    ctx.saveGState()
    // Slightly higher exponent at tiny sizes keeps corners from looking mushy.
    let n: CGFloat = px <= 64 ? 4.6 : 5.0
    let squircle = squirclePath(in: rect, n: n)
    ctx.addPath(squircle)
    ctx.clip()

    // Slimg gradient, 135° (topLeft → bottomRight).
    let grad = CGGradient(
        colorsSpace: sRGB,
        colors: [cg(gradStart), cg(gradEnd)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: 0, y: size),      // top-left in default y-up space
        end: CGPoint(x: size, y: 0),        // bottom-right
        options: []
    )

    // Subtle top-light overlay (white 18% → 0 at mid-height) for depth.
    let topLight = CGGradient(
        colorsSpace: sRGB,
        colors: [
            CGColor(colorSpace: sRGB, components: [1, 1, 1, 0.16])!,
            CGColor(colorSpace: sRGB, components: [1, 1, 1, 0.0])!,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        topLight,
        start: CGPoint(x: 0, y: size),      // top
        end: CGPoint(x: 0, y: size * 0.45), // fades by ~55% down
        options: []
    )
    ctx.restoreGState()

    // --- White mark (drawn in flipped top-left space to match the SVG) ---
    ctx.saveGState()
    flipTopLeft(ctx, px: size)
    drawMark(in: ctx, scale: scale)
    ctx.restoreGState()

    return ctx.makeImage()!
}

/// Render just the transparent-background gradient mark (for web favicons that
/// want the mark, though our PNG favicons use the full squircle per the brief).
/// Kept available; not currently exported as PNG.

// MARK: - OG social card (1200×630)

func renderOGImage() -> CGImage {
    let w = 1200, h = 630
    let ctx = makeContext0(w: w, h: h)
    let W = CGFloat(w), H = CGFloat(h)

    // Background: Ink-950 with a faint teal radial glow toward the icon.
    ctx.setFillColor(cg(ink950))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    let glow = CGGradient(
        colorsSpace: sRGB,
        colors: [cg(gradStart, 0.22), cg(gradStart, 0.0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 300, y: H / 2), startRadius: 0,
        endCenter: CGPoint(x: 300, y: H / 2), endRadius: 520,
        options: []
    )

    // --- Icon on the left ---
    let iconSize: CGFloat = 300
    let iconX: CGFloat = 110
    let iconY = (H - iconSize) / 2
    let icon = renderAppIcon(px: 600) // render high-res, draw scaled
    ctx.saveGState()
    ctx.interpolationQuality = .high
    ctx.draw(icon, in: CGRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
    ctx.restoreGState()

    // --- Text block on the right (flip to top-left for CoreText layout math) ---
    let textX = iconX + iconSize + 80

    // Wordmark "slimg" — bold, white. Use SF (system) bold.
    let wordFont = NSFont.systemFont(ofSize: 132, weight: .bold)
    drawText(
        ctx, string: "slimg",
        font: wordFont,
        color: CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!,
        x: textX, baselineY: H / 2 + 36, tracking: -3.0
    )

    // Tagline — slate, medium.
    let tagFont = NSFont.systemFont(ofSize: 44, weight: .medium)
    drawText(
        ctx, string: "Slim your images. Lose nothing.",
        font: tagFont,
        color: cg(slate400),
        x: textX + 4, baselineY: H / 2 - 56, tracking: 0.2
    )

    return ctx.makeImage()!
}

/// Non-square context.
func makeContext0(w: Int, h: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    return ctx
}

/// Draw a single line of text with CoreText. `baselineY` is in default y-up
/// CoreGraphics space (origin bottom-left). `tracking` in points.
func drawText(_ ctx: CGContext, string: String, font: NSFont, color: CGColor, x: CGFloat, baselineY: CGFloat, tracking: CGFloat) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .kern: tracking,
    ]
    let attr = NSAttributedString(string: string, attributes: attrs)
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.textPosition = CGPoint(x: x, y: baselineY)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

// MARK: - PNG writing

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw Err("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw Err("Could not finalize PNG at \(url.path)")
    }
}

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Driver

let fm = FileManager.default

// Resolve repo root from CWD (script is run as `swift Scripts/generate-icons.swift`
// from repo root). Fall back to the script's parent's parent if needed.
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
func repoRoot() -> URL {
    // If brand/ and Resources/ exist under CWD, use it.
    if fm.fileExists(atPath: cwd.appendingPathComponent("brand").path),
       fm.fileExists(atPath: cwd.appendingPathComponent("Resources").path) {
        return cwd
    }
    // Else derive from script location: Scripts/generate-icons.swift → repo root.
    let scriptPath = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    return scriptPath.deletingLastPathComponent()
}

let root = repoRoot()
let resourcesDir = root.appendingPathComponent("Resources")
let webDir = root.appendingPathComponent("brand/web")
let iconsetDir = resourcesDir.appendingPathComponent("AppIcon.iconset")
let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")

func log(_ s: String) { print("  \(s)") }

print("Slimg icon generator")
print("Repo root: \(root.path)")

do {
    try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
    try fm.createDirectory(at: webDir, withIntermediateDirectories: true)

    // --- 1. Build the .iconset (re-render each size natively for crispness) ---
    // Apple iconset naming: each logical size at @1x and @2x.
    let iconsetSpecs: [(name: String, px: Int)] = [
        ("icon_16x16", 16),
        ("icon_16x16@2x", 32),
        ("icon_32x32", 32),
        ("icon_32x32@2x", 64),
        ("icon_128x128", 128),
        ("icon_128x128@2x", 256),
        ("icon_256x256", 256),
        ("icon_256x256@2x", 512),
        ("icon_512x512", 512),
        ("icon_512x512@2x", 1024),
    ]

    // Fresh iconset dir each run (idempotent).
    if fm.fileExists(atPath: iconsetDir.path) {
        try fm.removeItem(at: iconsetDir)
    }
    try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

    // Cache by pixel size so 32/256/512 aren't rendered twice.
    var cache: [Int: CGImage] = [:]
    for spec in iconsetSpecs {
        let img = cache[spec.px] ?? renderAppIcon(px: spec.px)
        cache[spec.px] = img
        let out = iconsetDir.appendingPathComponent("\(spec.name).png")
        try writePNG(img, to: out)
    }
    log("Wrote iconset (\(iconsetSpecs.count) PNGs) → \(iconsetDir.lastPathComponent)/")

    // --- 2. iconutil → .icns ---
    if fm.fileExists(atPath: icnsURL.path) { try fm.removeItem(at: icnsURL) }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
    let pipe = Pipe()
    proc.standardError = pipe
    proc.standardOutput = pipe
    try proc.run()
    proc.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if proc.terminationStatus != 0 {
        throw Err("iconutil failed (status \(proc.terminationStatus)): \(out)")
    }
    log("Built \(icnsURL.path)")

    // Clean up the intermediate iconset; .icns is the canonical output.
    try fm.removeItem(at: iconsetDir)
    log("Cleaned up intermediate \(iconsetDir.lastPathComponent)/")

    // --- 3. Web exports ---

    // favicon.svg — copy the brand logomark (transparent-bg gradient mark).
    let logomarkSrc = root.appendingPathComponent("brand/logomark.svg")
    let faviconSVG = webDir.appendingPathComponent("favicon.svg")
    if fm.fileExists(atPath: faviconSVG.path) { try fm.removeItem(at: faviconSVG) }
    try fm.copyItem(at: logomarkSrc, to: faviconSVG)
    log("Wrote brand/web/favicon.svg (copied from logomark.svg)")

    // PNG icons (full squircle icon).
    let favicon32 = webDir.appendingPathComponent("favicon-32.png")
    let favicon180 = webDir.appendingPathComponent("favicon-180.png")
    let icon512 = webDir.appendingPathComponent("icon-512.png")
    try writePNG(renderAppIcon(px: 32), to: favicon32)
    log("Wrote brand/web/favicon-32.png (32×32)")
    try writePNG(renderAppIcon(px: 180), to: favicon180)
    log("Wrote brand/web/favicon-180.png (180×180)")
    try writePNG(cache[512] ?? renderAppIcon(px: 512), to: icon512)
    log("Wrote brand/web/icon-512.png (512×512)")

    // og-image.png — 1200×630 social card.
    let og = webDir.appendingPathComponent("og-image.png")
    try writePNG(renderOGImage(), to: og)
    log("Wrote brand/web/og-image.png (1200×630)")

    print("Done. Canonical icon: \(icnsURL.path)")
} catch {
    FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
    exit(1)
}
