import AppKit
import Vision
import XCTest

/// The text a view draws, read back with Vision: what the user sees, not what the model holds.
enum ScreenText {
    @MainActor
    /// `top`: read only that many points from the top edge (small text in a wide view is easier to find alone);
    /// `skip`: leave out that many points above it, when a busy row there would swallow the line being read.
    static func read(_ view: NSView, top: CGFloat? = nil, skip: CGFloat = 0, scale: CGFloat = 2) throws -> String {
        // SwiftUI draws into layers; render the layer tree (cacheDisplay comes back blank).
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let layer = try XCTUnwrap(view.layer)
        let size = view.bounds.size
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white); context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped { context.translateBy(x: 0, y: size.height); context.scaleBy(x: 1, y: -1) }
        layer.render(in: context)
        var image = try XCTUnwrap(context.makeImage())
        if let top { image = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: skip * scale, width: size.width * scale, height: (top - skip) * scale))) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
