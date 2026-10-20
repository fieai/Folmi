import Foundation
import Observation
import XCTest
@testable import Folmi

/// FolmiModel is @Observable: a view re-renders only for the properties its body read, not for every change.
final class ModelObservationTests: XCTestCase {
    private final class Flag: @unchecked Sendable { var fired = false }

    /// Registers `read` for tracking and returns a flag the next change to anything it read sets.
    @MainActor
    private func track(_ read: () -> Void) -> Flag {
        let flag = Flag()
        withObservationTracking(read, onChange: { flag.fired = true })
        return flag
    }

    private func makeStore() throws -> WorkspaceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Folmi-Observation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return WorkspaceStore(url: directory.appendingPathComponent("workspace.json"))
    }

    @MainActor
    func testTypingInTheFileSearchDoesNotInvalidateUnrelatedReaders() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let model = FolmiModel(store: store)
        let content = track { _ = model.content; _ = model.paneLayout }
        let search = track { _ = model.fileSearch }
        model.fileSearch = "a"
        XCTAssertFalse(content.fired, "only readers of fileSearch re-render")
        XCTAssertTrue(search.fired)
        model.content = .history
        XCTAssertTrue(content.fired)
    }

    @MainActor
    func testEditorTextChangesReachTheWindowOnlyThroughTheChrome() async throws {
        let demo = try await DemoRepository.create(includeNavigationSamples: true)
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        let model = FolmiModel(store: store)
        defer { try? model.savePreferencesNow() }
        model.open(demo.root, environment: demo.environment, demo: true)
        let deadline = Date().addingTimeInterval(8)
        while model.busy || model.snapshot == nil {
            guard Date() < deadline else { return XCTFail("等待超时：打开演示项目") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let editor = try XCTUnwrap(model.editorWorkspace)
        try editor.open(path: "docs/guide.md")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.editorChrome?.selected, "docs/guide.md")
        XCTAssertTrue(model.isMarkdownDocument)
        let text = try XCTUnwrap(editor.selectedDocument?.text)

        // The first edit turns on the dirty dot: the tab strip has to re-render.
        var chrome = track { _ = model.editorChrome }
        editor.updateText(id: "docs/guide.md", text: text + "x")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(chrome.fired)
        XCTAssertEqual(model.editorChrome?.dirty, [true])

        // Further typing changes nothing the window shows.
        chrome = track { _ = model.editorChrome; _ = model.content; _ = model.snapshot }
        editor.updateText(id: "docs/guide.md", text: text + "xy")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(chrome.fired)
    }
}
