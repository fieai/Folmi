import AppKit
import SwiftUI
import ObjectiveC
import XCTest
@testable import Folmi

/// Exercise the actual button and rendered overlay, not just particle geometry.
final class TerrazzoInteractionTests: XCTestCase {
    @MainActor
    private final class Actions {
        var count = 0
        var observedReduceMotion: Bool?
    }

    private final class ReducedMotionSource: NSObject {
        @objc dynamic func forcedReduceMotion() -> Bool { true }
        @objc dynamic func forcedFullMotion() -> Bool { false }
    }

    @MainActor
    private struct MotionProbe: ViewModifier {
        let actions: Actions
        @Environment(\.accessibilityReduceMotion) private var reduced
        func body(content: Content) -> some View {
            content.onAppear { actions.observedReduceMotion = reduced }
                .onChange(of: reduced) { _, value in actions.observedReduceMotion = value }
        }
    }

    /// Override only this test process's read-only workspace getter; the user's accessibility settings are untouched.
    @MainActor
    private func reducedMotionOverride(_ reduced: Bool) throws -> () -> Void {
        let original = try XCTUnwrap(class_getInstanceMethod(NSWorkspace.self,
            #selector(getter: NSWorkspace.accessibilityDisplayShouldReduceMotion)))
        let replacement = try XCTUnwrap(class_getInstanceMethod(ReducedMotionSource.self,
            reduced ? #selector(ReducedMotionSource.forcedReduceMotion) : #selector(ReducedMotionSource.forcedFullMotion)))
        let implementation = method_setImplementation(original, method_getImplementation(replacement))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: NSWorkspace.shared)
        return {
            method_setImplementation(original, implementation)
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                       object: NSWorkspace.shared)
        }
    }

    @MainActor
    private struct Fixture {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let actions: Actions
        let restoreMotion: (() -> Void)?

        func close() {
            window.orderOut(nil)
            window.contentView = nil
            restoreMotion?()
        }
    }

    @MainActor
    private func show(theme: FolmiTheme = .terrazzo, disabled: Bool = false,
                      reduceMotion: Bool = false, welcome: Bool = false) async throws -> Fixture {
        let restoreMotion = try reducedMotionOverride(reduceMotion)
        let actions = Actions()
        let control = Button { actions.count += 1 } label: {
            Text("Run action").frame(width: 160, height: 28)
        }
        .buttonStyle(.folmiProminent)
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(disabled)
        let root = (welcome ? AnyView(WelcomeMark()) : AnyView(control))
        .frame(width: 360, height: 200)
        .background(Color.white)
        .environment(\.folmiTheme, theme)
        .environment(\.colorScheme, .light)
        .environment(\.scenePhase, .active)
        .modifier(MotionProbe(actions: actions))
        let host = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 360, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
        return Fixture(window: window, host: host, actions: actions, restoreMotion: restoreMotion)
    }

    @MainActor
    private func click(in fixture: Fixture) throws {
        let release = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp,
            location: NSPoint(x: 180, y: 100), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        NSApp.postEvent(release, atStart: false)
        try mouse(.leftMouseDown, at: NSPoint(x: 180, y: 100), in: fixture)
        drainMouseEvents(in: fixture)
    }

    @MainActor
    private func drainMouseEvents(in fixture: Fixture) {
        while let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(),
                                         inMode: .default, dequeue: true) {
            if event.windowNumber == fixture.window.windowNumber { fixture.window.sendEvent(event) }
        }
    }

    @MainActor
    private func shortcut(in fixture: Fixture) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "r",
            charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
    }

    @MainActor
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in fixture: Fixture) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        fixture.window.sendEvent(event)
    }

    private struct Frame {
        let image: CGImage
        let rgba: [UInt8]
        let width: Int
        let height: Int

        func changedPixels(from other: Frame) -> Int {
            var changed = 0
            for offset in stride(from: 0, to: rgba.count, by: 4) {
                if (0..<3).contains(where: { abs(Int(rgba[offset + $0]) - Int(other.rgba[offset + $0])) > 12 }) {
                    changed += 1
                }
            }
            return changed
        }

        /// Exclude the whole button, its border and its resting shadow. Only particle pixels can change here.
        func changedOuterPixels(from other: Frame) -> Int {
            var changed = 0
            for y in 55..<145 {
                for x in 65..<295 where y < 74 || y >= 126 {
                    let offset = (y * width + x) * 4
                    let delta = (0..<3).map { abs(Int(rgba[offset + $0]) - Int(other.rgba[offset + $0])) }.max() ?? 0
                    if delta > 12 { changed += 1 }
                }
            }
            return changed
        }
    }

    @MainActor
    private func capture(_ fixture: Fixture) throws -> Frame {
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()
        let layer = try XCTUnwrap(fixture.host.layer)
        let width = 360, height = 200
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if fixture.host.isFlipped {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        let image = try XCTUnwrap(context.makeImage())
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Frame(image: image, rgba: Array(UnsafeBufferPointer(start: bytes, count: width * height * 4)),
                     width: width, height: height)
    }

    private func save(_ frame: Frame, name: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-terrazzo-interaction-frames")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @MainActor
    func testNativeClickAndKeyboardActivationEachExecuteExactlyOnceInEveryTheme() async throws {
        for theme in FolmiTheme.allCases {
            let fixture = try await show(theme: theme)
            defer { fixture.close() }
            try click(in: fixture)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(fixture.actions.count, 1, "\(theme.title): native press must not double-trigger")
            XCTAssertTrue(fixture.window.performKeyEquivalent(with: try shortcut(in: fixture)), theme.title)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(fixture.actions.count, 2, "\(theme.title): shortcut must trigger exactly once")
        }
    }

    @MainActor
    func testDisabledButtonIgnoresNativePressAndKeyboardInEveryTheme() async throws {
        for theme in FolmiTheme.allCases {
            let fixture = try await show(theme: theme, disabled: true)
            defer { fixture.close() }
            try click(in: fixture)
            _ = fixture.window.performKeyEquivalent(with: try shortcut(in: fixture))
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(fixture.actions.count, 0, "\(theme.title): disabled actions cannot execute")
        }
    }

    /// Stone grains belong to finished work (a commit, a finished review); pressing a button stays quiet.
    @MainActor
    func testPressingTheStoneButtonRunsTheActionWithoutParticles() async throws {
        let fixture = try await show()
        defer { fixture.close() }
        let baseline = try capture(fixture)
        try click(in: fixture)
        let start = ContinuousClock.now
        var peakCount = 0
        while ContinuousClock.now - start < .milliseconds(380) {
            try await Task.sleep(for: .milliseconds(25))
            peakCount = max(peakCount, try capture(fixture).changedOuterPixels(from: baseline))
        }
        XCTAssertEqual(fixture.actions.count, 1)
        XCTAssertEqual(peakCount, 0, "no particles appear outside the button when it is pressed")
    }

    @MainActor
    func testReduceMotionSuppressesRenderedParticlesWithoutSuppressingTheAction() async throws {
        let fixture = try await show(reduceMotion: true)
        defer { fixture.close() }
        XCTAssertEqual(fixture.actions.observedReduceMotion, true, "the hosted SwiftUI environment must actually see Reduce Motion")
        let baseline = try capture(fixture)
        try click(in: fixture)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(35))
            XCTAssertEqual(try capture(fixture).changedOuterPixels(from: baseline), 0,
                           "Reduce Motion must leave the button surroundings still")
        }
        XCTAssertEqual(fixture.actions.count, 1)
    }

    @MainActor
    func testDraggingOutCancelsActionAndParticles() async throws {
        let fixture = try await show()
        defer { fixture.close() }
        let baseline = try capture(fixture)
        // Queue the release before mouseDown: AppKit is allowed to enter a synchronous tracking loop.
        for type in [NSEvent.EventType.leftMouseDragged, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: fixture.window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
            NSApp.postEvent(event, atStart: false)
        }
        try mouse(.leftMouseDown, at: NSPoint(x: 180, y: 100), in: fixture)
        drainMouseEvents(in: fixture)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(35))
            XCTAssertEqual(try capture(fixture).changedOuterPixels(from: baseline), 0)
        }
        XCTAssertEqual(fixture.actions.count, 0, "releasing outside the native button cancels activation")
    }

    /// Each theme's launch mark, with how long its introduction plays.
    private let welcomeThemes: [(FolmiTheme, Double)] = [
        (.indigo, FolmiGreeting.duration), (.zinc, ZincTrace.duration), (.terrazzo, 1.1), (.pixel, PixelBricks.duration),
    ]

    @MainActor
    func testWelcomeMarksPlayTheirIntroThenRenderedFramesStayStill() async throws {
        for (theme, duration) in welcomeThemes {
            let fixture = try await show(theme: theme, welcome: true)
            defer { fixture.close() }
            XCTAssertEqual(fixture.actions.observedReduceMotion, false)
            let entering = try capture(fixture)
            try await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            let settled = try capture(fixture)
            try await Task.sleep(for: .milliseconds(180))
            let resting = try capture(fixture)
            try save(entering, name: "welcome-\(theme.rawValue)-entering")
            try save(settled, name: "welcome-\(theme.rawValue)-settled")
            XCTAssertGreaterThan(entering.changedPixels(from: settled), 100,
                                 "\(theme.title): the welcome mark must visibly enter, not jump straight to a static image")
            XCTAssertEqual(resting.changedPixels(from: settled), 0,
                           "\(theme.title): the welcome mark must stop animating after its introduction")
            XCTAssertGreaterThan(settled.rgba.filter { $0 < 200 }.count, 100, "\(theme.title): the settled mark is drawn")
        }
    }

    @MainActor
    func testReducedMotionWelcomeMarksRenderWithoutIntroductoryMovement() async throws {
        for (theme, _) in welcomeThemes {
            let fixture = try await show(theme: theme, reduceMotion: true, welcome: true)
            defer { fixture.close() }
            XCTAssertEqual(fixture.actions.observedReduceMotion, true)
            let initial = try capture(fixture)
            try await Task.sleep(for: .milliseconds(500))
            let resting = try capture(fixture)
            XCTAssertEqual(resting.changedPixels(from: initial), 0,
                           "\(theme.title): Reduce Motion must show the finished mark immediately and keep it still")
            XCTAssertGreaterThan(initial.rgba.filter { $0 < 200 }.count, 100,
                                 "\(theme.title): the reduced-motion fallback must still draw the mark")
        }
    }

}
