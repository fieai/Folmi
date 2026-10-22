import SwiftUI
import XCTest
@testable import Folmi
import FolmiCore

@MainActor
final class StartupEnvironmentTests: XCTestCase {
    private func withModel(checkEnvironmentOnStartup: Bool = false, _ action: (FolmiModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-startup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(url: root.appendingPathComponent("workspace.json"))
        let model = FolmiModel(store: store, checkEnvironmentOnStartup: checkEnvironmentOnStartup)
        try await action(model)
    }

    func testAppModelBlocksRepositoryActionsBeforeTheFirstProbe() async throws {
        try await withModel(checkEnvironmentOnStartup: true) { model in
            XCTAssertEqual(model.gitStartupState, .checking)
            model.open(URL(fileURLWithPath: "/missing-folmi-before-probe"))
            model.loadDemo()
            XCTAssertNil(model.errorMessage)
            XCTAssertNil(model.repositoryURL)
            XCTAssertFalse(model.busy)
            XCTAssertTrue(model.projects.isEmpty)
        }
    }

    func testMissingToolsPreventOpeningAndCreatingRepositoriesAndRetryRecovers() async throws {
        try await withModel { model in
            await model.checkGitEnvironment { .needsCommandLineTools(details: "not installed") }
            XCTAssertTrue(model.gitStartupState.blocksGit)
            XCTAssertFalse(model.startupResumed)
            model.open(URL(fileURLWithPath: "/path/that/must/not/be/read"))
            model.loadDemo()
            XCTAssertNil(model.errorMessage)
            XCTAssertNil(model.repositoryURL)
            XCTAssertTrue(model.projects.isEmpty)
            XCTAssertFalse(model.busy)
            await model.checkGitEnvironment { .ready(version: "git version test") }
            XCTAssertFalse(model.gitStartupState.blocksGit)
            XCTAssertTrue(model.startupResumed)
            XCTAssertEqual(model.gitStartupState, .checked(.ready(version: "git version test")))
        }
    }

    func testBrokenGitIsNotTreatedAsACompletedStartup() async throws {
        try await withModel { model in
            await model.checkGitEnvironment { .unavailable(details: "Xcode license required") }
            XCTAssertTrue(model.gitStartupState.blocksGit)
            XCTAssertFalse(model.startupResumed)
            XCTAssertEqual(model.gitStartupState, .checked(.unavailable(details: "Xcode license required")))
        }
    }

    func testSavedProjectRestoresOnlyAfterToolsBecomeAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-startup-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("moved-project").path
        let store = WorkspaceStore(url: root.appendingPathComponent("workspace.json"))
        try store.save(WorkspacePreferences(projects: [.init(rootPath: missing, name: "保留项目")], selectedProjectPath: missing))
        let model = FolmiModel(store: store)
        await model.checkGitEnvironment { .needsCommandLineTools(details: "not installed") }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try store.load().selectedProjectPath, missing)
        await model.checkGitEnvironment { .ready(version: "git version test") }
        XCTAssertEqual(model.missingProjectPath, missing, "the saved project is retried only after Git is usable")
        XCTAssertEqual(model.projects.first?.name, "保留项目")
        model.errorMessage = nil
        model.missingProjectPath = nil
        await model.checkGitEnvironment { .ready(version: "git version test") }
        XCTAssertNil(model.errorMessage, "a subsequent check must not reopen the startup project")
    }

    func testColdStartLinkIsQueuedUntilTheGitCheckCompletes() async throws {
        try await withModel { model in
            model.gitStartupState = .checking
            let link = try XCTUnwrap(URL(string: "folmi://open?repo=/missing-folmi-startup-repository&path=README.md&line=1"))
            model.handleFolmiLink(link)
            XCTAssertEqual(model.pendingFolmiLink, link)
            XCTAssertNil(model.errorMessage)
            await model.checkGitEnvironment { .ready(version: "git version test") }
            XCTAssertNil(model.pendingFolmiLink)
            XCTAssertTrue(model.errorMessage?.contains("missing-folmi-startup-repository") == true)
        }
    }

    func testLinkQueuedDuringLaterRecheckIsStillDispatched() async throws {
        try await withModel { model in
            await model.checkGitEnvironment { .ready(version: "git version test") }
            XCTAssertTrue(model.startupResumed)
            model.gitStartupState = .checking
            let link = try XCTUnwrap(URL(string: "folmi://open?repo=/missing-folmi-later-repository"))
            model.handleFolmiLink(link)
            XCTAssertEqual(model.pendingFolmiLink, link)
            await model.checkGitEnvironment { .ready(version: "git version test") }
            XCTAssertNil(model.pendingFolmiLink)
            XCTAssertTrue(model.errorMessage?.contains("missing-folmi-later-repository") == true)
        }
    }

    func testStartupScreensRenderForMissingToolsAndBrokenGit() async throws {
        try await withModel { model in
            let states: [(String, GitStartupState)] = [
                ("missing-tools", .checked(.needsCommandLineTools(details: "xcode-select: unable to get active developer directory"))),
                ("broken-git", .checked(.unavailable(details: "You have not agreed to the Xcode license agreements"))),
                ("checking", .checking)
            ]
            for (name, state) in states {
                model.gitStartupState = state
                let renderer = ImageRenderer(content: StartupEnvironmentView(model: model)
                    .frame(width: 1000, height: 650).environment(\.folmiTheme, model.theme).preferredColorScheme(.dark))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.nsImage)
                XCTAssertEqual(image.size, NSSize(width: 1000, height: 650))
                if name == "checking" {
                    // Only a title and a spinner: they sit in the middle, not at the left of the results column.
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                    let background = bitmap.colorAt(x: 2, y: 2)
                    let inked = (0..<bitmap.pixelsWide).filter { x in
                        stride(from: 0, to: bitmap.pixelsHigh, by: 2).contains { bitmap.colorAt(x: x, y: $0) != background }
                    }
                    let middle = (Double(try XCTUnwrap(inked.first)) + Double(try XCTUnwrap(inked.last))) / 2
                    XCTAssertEqual(middle, 500, accuracy: 12)
                }
                if let directory = ProcessInfo.processInfo.environment["FOLMI_QA_OUTPUT"] {
                    let url = URL(fileURLWithPath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("startup-\(name).png"))
                }
            }
        }
    }
}
