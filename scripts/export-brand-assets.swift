#!/usr/bin/env swift
// Run: swift scripts/export-brand-assets.swift
// App icons resample approved raster artwork; UI characters render the editable SVG.
import AppKit
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ExportError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

let manager = FileManager.default
let root = URL(fileURLWithPath: #filePath).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let brand = root.appendingPathComponent("Sources/Folmi/Resources/Brand", isDirectory: true)
var entries: [[String: Any]] = []

func fail(_ message: String) throws -> Never { throw ExportError.failed(message) }
func makeDirectory(_ relative: String) throws {
    try manager.createDirectory(at: brand.appendingPathComponent(relative), withIntermediateDirectories: true)
}
func readImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        try fail("Cannot read PNG: \(url.path)")
    }
    return image
}
func hasAlpha(_ image: CGImage) -> Bool {
    [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
}
func canvas(_ size: Int) throws -> CGContext {
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        try fail("Cannot allocate \(size) px RGBA canvas")
    }
    return context
}
func record(_ relative: String, pixels: Int, points: Int? = nil, scale: Int? = nil, source: String, usage: String) throws {
    let image = try readImage(brand.appendingPathComponent(relative))
    guard image.width == pixels, image.height == pixels, hasAlpha(image) else {
        try fail("Unexpected dimensions or missing alpha: \(relative)")
    }
    var entry: [String: Any] = ["path": relative, "width": pixels, "height": pixels,
                               "alpha": true, "source": source, "usage": usage]
    if let points { entry["points"] = points }
    if let scale { entry["scale"] = scale }
    entries.append(entry)
}
func writePNG(_ image: CGImage, _ relative: String) throws {
    let url = brand.appendingPathComponent(relative)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        try fail("Cannot write PNG: \(relative)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { try fail("PNG export failed: \(relative)") }
}
func resized(_ source: CGImage, to size: Int) throws -> CGImage {
    let context = try canvas(size)
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage() else { try fail("Resize failed: \(size)") }
    return image
}

// NSImage uses the macOS SVG renderer, keeping the layered SVG as the only geometry source.
func renderedSVG(_ data: Data, size: Int) throws -> CGImage {
    guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
        try fail("Native macOS SVG renderer could not open the character")
    }
    let context = try canvas(size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
               operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    guard let result = context.makeImage() else { try fail("SVG render failed: \(size) px") }
    return result
}

func menuBarSVG(from mascot: Data) throws -> String {
    let document = try XMLDocument(data: mascot)
    func element(_ xpath: String) throws -> XMLElement {
        guard let element = try document.nodes(forXPath: xpath).first as? XMLElement else {
            try fail("Missing canonical SVG element: \(xpath)")
        }
        return element
    }
    func attribute(_ name: String, of element: XMLElement) throws -> String {
        guard let value = element.attribute(forName: name)?.stringValue else { try fail("Missing SVG attribute: \(name)") }
        return value
    }
    let tail = try attribute("d", of: element("//*[@id='folmi-tail']/path[1]"))
    let body = try attribute("d", of: element("//*[@id='folmi-body']/path[1]"))
    var eyes: [String] = []
    for part in ["eye-left", "eye-right"] {
        let ellipse = try element("//*[@data-part='\(part)']/ellipse[1]")
        let cx = try attribute("cx", of: ellipse), cy = try attribute("cy", of: ellipse)
        guard let rx = Double(try attribute("rx", of: ellipse)), let ry = Double(try attribute("ry", of: ellipse)) else {
            try fail("Non-numeric canonical eye radius")
        }
        // Modestly enlarge the transparent eye holes for small-size readability.
        eyes.append("<ellipse cx=\"\(cx)\" cy=\"\(cy)\" rx=\"\(rx * 1.35)\" ry=\"\(ry * 1.2)\" fill=\"black\"/>")
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="54.444 39.444 431.112 431.112" role="img" aria-label="Folmi menu bar template">
      <!-- Generated from Mascot/folmi-mascot.svg; body, tail and eye geometry share that source. -->
      <!-- Ear shading, eye highlights, eyelids and accents are omitted at menu-bar sizes. -->
      <defs><mask id="eyes" maskUnits="userSpaceOnUse" x="54" y="39" width="432" height="432">
        <rect x="54" y="39" width="432" height="432" fill="white"/>
        \(eyes.joined(separator: "\n    "))
      </mask></defs>
      <g fill="black" mask="url(#eyes)"><path d="\(tail)"/><path d="\(body)"/></g>
    </svg>
    """
}

func runIconutil(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = arguments
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { try fail("iconutil failed: \(arguments.joined(separator: " "))") }
}

do {
    let iconSource = brand.appendingPathComponent("Source/folmi-app-icon-master.png")
    let mascotSource = brand.appendingPathComponent("Mascot/folmi-mascot.svg")
    let iconSourcePath = "Source/folmi-app-icon-master.png"
    let mascotSourcePath = "Mascot/folmi-mascot.svg"
    let icon = try readImage(iconSource)
    let mascotData = try Data(contentsOf: mascotSource)
    let templateSVG = try menuBarSVG(from: mascotData)
    guard let templateData = templateSVG.data(using: .utf8) else { try fail("Cannot encode template SVG") }
    guard icon.width == icon.height, hasAlpha(icon) else {
        try fail("Application icon master must be a square PNG image with alpha")
    }
    for directory in ["AppIcon.iconset", "AppIcon.appiconset", "UI", "MenuBar"] { try makeDirectory(directory) }
    var xcodeImages: [[String: Any]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            let image = try resized(icon, to: pixels)
            for directory in ["AppIcon.iconset", "AppIcon.appiconset"] {
                let relative = "\(directory)/\(name)"
                try writePNG(image, relative)
                try record(relative, pixels: pixels, points: points, scale: scale, source: iconSourcePath, usage: "macOS application icon")
            }
            xcodeImages.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
        }
    }
    let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let contents: [String: Any] = ["images": xcodeImages, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: jsonOptions)
        .write(to: brand.appendingPathComponent("AppIcon.appiconset/Contents.json"), options: .atomic)
    try writePNG(resized(icon, to: 1024), "AppIcon-1024.png")
    try record("AppIcon-1024.png", pixels: 1024, source: iconSourcePath, usage: "Application icon master export and preview")
    // Replace the rejected raster cutout at the same path with a clean SVG-rendered export.
    try writePNG(renderedSVG(mascotData, size: 1024), "Mascot/folmi-mascot-master.png")
    try record("Mascot/folmi-mascot-master.png", pixels: 1024, source: mascotSourcePath,
               usage: "Generated master: simplified editable vector redraw, not an exact imagegen cutout")
    for size in [16, 20, 24, 32, 48, 64, 128, 256, 512, 1024] {
        let relative = "UI/folmi-mascot-\(size).png"
        try writePNG(renderedSVG(mascotData, size: size), relative)
        try record(relative, pixels: size, source: mascotSourcePath,
                   usage: "Transparent UI character rendered from simplified editable SVG redraw; not an exact imagegen cutout")
    }
    for points in [16, 18, 20, 24] {
        for scale in [1, 2] {
            let relative = "MenuBar/folmi-\(points)Template\(scale == 2 ? "@2x" : "").png"
            try writePNG(renderedSVG(templateData, size: points * scale), relative)
            try record(relative, pixels: points * scale, points: points, scale: scale, source: mascotSourcePath,
                       usage: "Reserved monochrome template; set NSImage.isTemplate; existing Git status icon unchanged")
        }
    }
    try templateSVG.write(to: brand.appendingPathComponent("MenuBar/folmi-template.svg"), atomically: true, encoding: .utf8)
    try runIconutil(["-c", "icns", brand.appendingPathComponent("AppIcon.iconset").path,
                     "-o", brand.appendingPathComponent("Folmi.icns").path])
    let roundtrip = manager.temporaryDirectory.appendingPathComponent("folmi-icon-check-\(UUID().uuidString).iconset")
    defer { try? manager.removeItem(at: roundtrip) }
    try runIconutil(["-c", "iconset", brand.appendingPathComponent("Folmi.icns").path, "-o", roundtrip.path])
    let roundtripNames = try manager.contentsOfDirectory(atPath: roundtrip.path).filter { $0.hasSuffix(".png") }.sorted()
    guard roundtripNames.count == 10 else { try fail("ICNS round trip did not retain all 10 representations") }
    for name in roundtripNames {
        let expected = try readImage(brand.appendingPathComponent("AppIcon.iconset/\(name)"))
        let actual = try readImage(roundtrip.appendingPathComponent(name))
        guard actual.width == expected.width, actual.height == expected.height, hasAlpha(actual) else {
            try fail("ICNS round trip mismatch: \(name)")
        }
    }
    let sources: [[String: Any]] = [
        ["path": iconSourcePath, "format": "PNG", "width": icon.width, "height": icon.height,
         "alpha": hasAlpha(icon), "sha256": SHA256.hash(data: try Data(contentsOf: iconSource)).map { String(format: "%02x", $0) }.joined()],
        ["path": mascotSourcePath, "format": "SVG", "width": 512, "height": 512, "alpha": true,
         "sha256": SHA256.hash(data: mascotData).map { String(format: "%02x", $0) }.joined(),
         "artwork": "Simplified editable layered vector redraw of approved D3; not an exact imagegen cutout"]
    ]
    let manifest: [String: Any] = [
        "schemaVersion": 2,
        "generator": "swift scripts/export-brand-assets.swift",
        "sources": sources,
        "assets": entries.sorted { ($0["path"] as! String) < ($1["path"] as! String) },
        "icns": ["path": "Folmi.icns", "representations": 10, "roundTripValidated": true],
        "notes": ["Application icons preserve the approved source raster artwork and alpha without cleanup or recoloring.",
                  "UI PNGs and generated mascot master render the editable layered SVG using the native macOS SVG renderer.",
                  "The UI mascot is a simplified vector redraw; it is not an exact imagegen cutout.",
                  "Menu bar artwork extracts canonical body, tail and eyes from the same SVG and removes details; reserved for future use.",
                  "AppIcon.appiconset is for future Xcode adoption; current SwiftPM packaging uses Folmi.icns."]
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: jsonOptions)
        .write(to: brand.appendingPathComponent("manifest.json"), options: .atomic)
    print("Exported \(entries.count) PNGs + Folmi.icns + editable template SVG. ICNS round trip: all 10 sizes passed.")
} catch {
    fputs("Brand export failed: \(error)\n", stderr)
    exit(1)
}
