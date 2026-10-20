import XCTest

/// Under Reduce Motion every animation becomes a plain switch (checklist N3): each SwiftUI animation goes through
/// `.motion` / `withMotion` or checks `reduceMotion` itself, and AppKit layer animations check it first.
final class MotionTests: XCTestCase {
    func testEveryAnimationRespectsReduceMotion() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Folmi")
        var offenders: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: sources.path) where name.hasSuffix(".swift") && name != "DesignTokens.swift" {
            let lines = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if (code.contains(".animation(") || code.contains("withAnimation(")), !code.contains("reduceMotion"), !code.contains("Motion.resolved") {
                    offenders.append("\(name):\(index + 1) \(code)")
                }
                // A layer animation must sit in a function that returned early under Reduce Motion.
                if code.contains("CABasicAnimation(") || code.contains("CASpringAnimation(") {
                    let before = lines[max(0, index - 12)..<index].joined(separator: "\n")
                    if !before.contains("if reduceMotion") { offenders.append("\(name):\(index + 1) \(code)") }
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }

    func testReaderStopsTransitionsUnderReduceMotion() throws {
        let reader = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Folmi/MarkdownReader.swift")
        let text = try String(contentsOf: reader, encoding: .utf8)
        let media = try XCTUnwrap(text.range(of: "@media (prefers-reduced-motion:reduce){"))
        XCTAssertTrue(text[media.upperBound...].prefix(200).contains("transition:none"))
    }
}
