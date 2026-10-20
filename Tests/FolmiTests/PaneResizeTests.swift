import AppKit
import XCTest
@testable import Folmi

@MainActor
final class PaneResizeTests: XCTestCase {
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    func testDividerDragsInWindowCoordinatesClampsAndCommitsOnce() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let divider = PaneDividerView(vertical: true)
        divider.frame = NSRect(x: 0, y: 300, width: 800, height: 8)
        window.contentView?.addSubview(divider)
        divider.inverted = true
        var value = 240.0, began = 0, ended = 0
        divider.value = { value }
        divider.limit = { _ in 120...400 }
        divider.onBegin = { began += 1 }
        divider.onChange = { value = $0 }
        divider.onEnd = { ended += 1 }

        divider.mouseDown(with: mouse(.leftMouseDown, at: NSPoint(x: 10, y: 304), in: window))
        // Up 60 pt grows the terminal below by 60.
        divider.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 10, y: 364), in: window))
        XCTAssertEqual(value, 300)
        // The limit holds however far the mouse goes.
        divider.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 10, y: 1_000), in: window))
        XCTAssertEqual(value, 400)
        divider.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: 10, y: -500), in: window))
        XCTAssertEqual(value, 120)
        divider.mouseUp(with: mouse(.leftMouseUp, at: NSPoint(x: 10, y: -500), in: window))
        XCTAssertEqual(began, 1)
        XCTAssertEqual(ended, 1)
    }

    func testDoubleClickResetsWithoutStartingADrag() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let divider = PaneDividerView(vertical: false)
        window.contentView?.addSubview(divider)
        var resets = 0, began = 0
        divider.onReset = { resets += 1 }
        divider.onBegin = { began += 1 }
        divider.mouseDown(with: mouse(.leftMouseDown, at: .zero, in: window, clicks: 2))
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(began, 0)
    }

    func testSizesFollowTheModelExceptDuringADrag() {
        let sizes = PaneSizes()
        var layout = PaneLayoutState()
        layout.sidebarWidth = 400
        sizes.sync(from: layout)
        XCTAssertEqual(sizes.sidebarWidth, 400)
        sizes.begin()
        XCTAssertTrue(PaneLiveResize.isActive)
        sizes.sidebarWidth = 450
        sizes.sync(from: layout)
        XCTAssertEqual(sizes.sidebarWidth, 450, "the model's older value must not snap a live drag back")
        let ended = expectation(forNotification: PaneLiveResize.didEnd, object: nil)
        sizes.end()
        wait(for: [ended], timeout: 1)
        XCTAssertFalse(PaneLiveResize.isActive)
    }

    func testTerminalKeepsItsSizeDuringADragAndTakesTheFinalSizeOnce() {
        let terminal = FolmiTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let host = TerminalHostView(terminal: terminal)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(terminal.frame.size, NSSize(width: 600, height: 240))

        PaneLiveResize.begin()
        host.setFrameSize(NSSize(width: 600, height: 300))
        host.layoutSubtreeIfNeeded()
        host.setFrameSize(NSSize(width: 600, height: 360))
        host.layoutSubtreeIfNeeded()
        // The cursor line fits, so the text stays under the card's top edge and follows it up.
        XCTAssertEqual(terminal.frame, NSRect(x: 0, y: 120, width: 600, height: 240), "no reflow or SIGWINCH while dragging")
        PaneLiveResize.end()
        XCTAssertEqual(terminal.frame, NSRect(x: 0, y: 0, width: 600, height: 360))
    }

    func testTerminalTakesTheFinalSizeAfterAnAnimatedChange() {
        let terminal = FolmiTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let host = TerminalHostView(terminal: terminal)
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        host.layoutSubtreeIfNeeded()
        // Sizes arriving frame after frame (a card animating): the terminal waits, then takes the last one.
        host.setFrameSize(NSSize(width: 600, height: 400))
        host.setFrameSize(NSSize(width: 600, height: 520))
        host.layoutSubtreeIfNeeded()
        // A pane drag starting and ending in between must not lose the pending size.
        PaneLiveResize.begin()
        host.needsLayout = true; host.layoutSubtreeIfNeeded()
        PaneLiveResize.end()
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(terminal.frame, NSRect(x: 0, y: 0, width: 600, height: 520))
    }

    /// A rebuilt card hands the terminal to a new host; the old host's pending settle must not shrink it afterwards.
    func testOldHostNeverResizesATerminalThatMovedAway() {
        let terminal = FolmiTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        let old = TerminalHostView(terminal: terminal)
        old.frame = NSRect(x: 0, y: 0, width: 600, height: 240)
        old.layoutSubtreeIfNeeded()
        old.setFrameSize(NSSize(width: 600, height: 120)); old.setFrameSize(NSSize(width: 600, height: 100))
        old.layoutSubtreeIfNeeded()
        let new = TerminalHostView(terminal: terminal)
        new.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        new.layoutSubtreeIfNeeded()
        PaneLiveResize.begin(); PaneLiveResize.end()
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertTrue(terminal.superview === new)
        XCTAssertEqual(terminal.frame, NSRect(x: 0, y: 0, width: 600, height: 500))
    }
}
