import AppKit
import FolmiCore
import XCTest
@testable import Folmi

@MainActor
final class ProjectRailIconTests: XCTestCase {
    func testAbbreviationsAndColors() async {
        let names = ["folmi-core": "FC", "myApp": "MA", "fastapi-server": "FS", "folmi": "Fo",
                     "frontend": "Fr", "验收台": "验", "": "?", "2026": "20", "👩🏽‍💻App": "👩🏽‍💻",
                     "one_two": "OT", "one.two": "OT", "one two": "OT", "URLParser": "UP"]
        for (name, expected) in names { XCTAssertEqual(ProjectIconCache.abbreviation(name), expected, name) }
        XCTAssertEqual(ProjectIconCache.paletteIndex("/projects/Folmi"), 1)
        XCTAssertEqual(ProjectIconCache.paletteIndex("/projects/Folmi"), 1)
        for theme in FolmiTheme.allCases {
            XCTAssertEqual(theme.definition.projectBadges.count, 8)
            for fill in theme.definition.projectBadges {
                XCTAssertGreaterThanOrEqual(fill.contrast(with: theme.definition.light.foreground), 4.5)
            }
        }
    }

    func testPreferencesReadOldSettingsAndRoundTripCustomIcons() async throws {
        var project = try JSONDecoder().decode(ProjectPreferences.self, from: Data(#"{"rootPath":"/test/project"}"#.utf8))
        XCTAssertNil(project.customIcon)
        for icon in [ProjectIcon.emoji("🚀"), .image("custom-example.png")] {
            project.customIcon = icon
            XCTAssertEqual(try JSONDecoder().decode(ProjectPreferences.self, from: JSONEncoder().encode(project)), project)
        }
    }

    func testDiscoveryRanksTrackedCandidatesSkipsExcludedPathsAndReusesBlob() async throws {
        let demo = try await DemoRepository.create()
        defer { try? FileManager.default.removeItem(at: demo.root.deletingLastPathComponent()) }
        func put(_ path: String, width: Int, height: Int) throws {
            let url = demo.root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try makePNG(width, height).write(to: url)
        }
        func git(_ args: [String]) async throws -> String {
            try await CommandRunner.git(args, at: demo.root, environment: demo.environment)
        }
        func find(cached: ProjectIconCache.Source? = nil) async throws -> (ProjectIconCache.Source?, Data?) {
            try await ProjectIconCache.find(root: demo.root, name: "project", environment: demo.environment, cached: cached)
        }
        let near = "Sources/AppIcon.appiconset/near.png"
        let large = "AppIcon.appiconset/large.png"
        let excluded = "node_modules/AppIcon.appiconset/128.png"
        let deep = "a/b/c/d/e/f/AppIcon.appiconset/128.png"
        let untracked = "local/AppIcon.appiconset/128.png"
        let favicon = "public/favicon.png"
        let wide = "src/app/icon.png"
        let logo = "logo.png"
        let androidSmall = "android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
        let androidLarge = "android/app/src/main/res/mipmap-hdpi/ic_launcher.png"
        for path in [excluded, deep, untracked] { try put(path, width: 128, height: 128) }
        for (path, width, height) in [(near, 120, 120), (large, 256, 256), (favicon, 100, 100), (wide, 100, 40),
                                       (logo, 85, 85), (androidSmall, 48, 48), (androidLarge, 72, 72)] {
            try put(path, width: width, height: height)
        }
        _ = try await git(["add", "-f", "--", excluded, deep, near, large, favicon, wide, logo, androidSmall, androidLarge])
        let first = try await find()
        XCTAssertEqual(first.0?.path, near)
        XCTAssertNotNil(first.1)
        let hit = try await find(cached: first.0)
        XCTAssertEqual(hit.0, first.0)
        XCTAssertNil(hit.1)
        try put(near, width: 124, height: 124)
        _ = try await git(["add", "--", near])
        let changed = try await find(cached: first.0)
        XCTAssertEqual(changed.0?.path, near)
        XCTAssertNotEqual(changed.0?.blob, first.0?.blob)
        XCTAssertNotNil(changed.1)
        _ = try await git(["rm", "--cached", "-f", "--", near, large])
        let web = try await find()
        XCTAssertEqual(web.0?.path, favicon)
        try Data("corrupt".utf8).write(to: demo.root.appendingPathComponent(favicon))
        let general = try await find()
        XCTAssertEqual(general.0?.path, logo)
        _ = try await git(["rm", "--cached", "-f", "--", logo])
        let android = try await find()
        XCTAssertEqual(android.0?.path, androidLarge)
    }

    func testStartupReusesFreshCacheAndRescansAfterExpirationOrManualRequest() async throws {
        let demo = try await DemoRepository.create()
        let folder = demo.root.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let workspace = folder.appendingPathComponent("settings/workspace.json")
        let cache = ProjectIconCache(workspace: workspace)
        let path = demo.root.path
        let project = ProjectPreferences(rootPath: path, name: "Demo", isDemo: true, environment: demo.environment)
        let icon = demo.root.appendingPathComponent("logo.png")
        try makePNG(96, 96).write(to: icon)
        _ = try await CommandRunner.git(["add", "--", "logo.png"], at: demo.root, environment: demo.environment)

        // A fresh miss avoids another Git search, even if a new candidate has since appeared.
        let filename = "custom-\(ProjectIconCache.key(path))-1.png"
        var withCustom = project
        withCustom.customIcon = .image(filename)
        let customURL = try XCTUnwrap(cache.customImage(filename, path: path))
        try cache.write(try makePNG(128, 128), to: customURL)
        let fresh = ProjectIconCache.Search(source: nil, date: Date())
        try cache.write(JSONEncoder().encode(fresh), to: cache.metadata(path))
        let icons = ProjectIcons(workspace: workspace)
        icons.load(withCustom)
        try await waitForIcon { icons.custom[path] != nil }
        XCTAssertNil(icons.automatic[path])
        icons.load(project, force: true)
        try await waitForIcon { icons.automatic[path] != nil }
        let first = try JSONDecoder().decode(ProjectIconCache.Search.self, from: Data(contentsOf: cache.metadata(path)))
        XCTAssertEqual(first.source?.path, "logo.png")

        let stale = ProjectIconCache.Search(source: first.source, date: Date().addingTimeInterval(-25 * 3600))
        try cache.write(JSONEncoder().encode(stale), to: cache.metadata(path))
        try makePNG(100, 100).write(to: icon)
        _ = try await CommandRunner.git(["add", "--", "logo.png"], at: demo.root, environment: demo.environment)
        let reopened = ProjectIcons(workspace: workspace)
        reopened.load(withCustom)
        try await waitForIcon {
            guard let data = try? Data(contentsOf: cache.metadata(path)),
                  let search = try? JSONDecoder().decode(ProjectIconCache.Search.self, from: data) else { return false }
            return search.source?.blob != first.source?.blob && search.date > stale.date
        }
        XCTAssertNotNil(reopened.automatic[path])
        XCTAssertNotNil(reopened.custom[path])
    }

    private func waitForIcon(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "project icon cache did not settle")
    }

    func testCustomImageDropResizesCopiesResetsAndCleansCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("project-icons-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("original.png")
        try makePNG(32, 80).write(to: input)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let invalid = folder.appendingPathComponent("invalid.png")
        try Data("broken".utf8).write(to: invalid)
        pasteboard.writeObjects([invalid as NSURL])
        XCTAssertNil(ProjectIconDropView.thumbnail(pasteboard))
        pasteboard.clearContents()
        pasteboard.writeObjects([input as NSURL])
        let thumb = try XCTUnwrap(ProjectIconDropView.thumbnail(pasteboard))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: thumb))
        XCTAssertEqual(rep.pixelsWide, 128); XCTAssertEqual(rep.pixelsHigh, 128)
        XCTAssertEqual(thumb.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertLessThan(rep.colorAt(x: 10, y: 64)?.alphaComponent ?? 1, 0.01)
        XCTAssertGreaterThan(rep.colorAt(x: 64, y: 64)?.alphaComponent ?? 0, 0.99)

        let store = WorkspaceStore(url: folder.appendingPathComponent("workspace.json"))
        let model = FolmiModel(store: store)
        let path = folder.appendingPathComponent("project").path
        model.projects = [ProjectPreferences(rootPath: path, name: "Project")]
        let cache = model.projectIcons.cache
        XCTAssertEqual(cache.directory.path, folder.appendingPathComponent("project-icons").path)

        model.setProjectImage(thumb, path: path)
        guard case let .image(name)? = model.projects.first?.customIcon else { return XCTFail("custom image not saved") }
        let url = try XCTUnwrap(cache.customImage(name, path: path))
        XCTAssertEqual(try store.load().projects.first?.customIcon, .image(name))
        try FileManager.default.removeItem(at: input)
        XCTAssertEqual(try Data(contentsOf: url), thumb)
        XCTAssertNotNil(model.projectIcons.custom[path])

        let newPath = folder.appendingPathComponent("moved").path
        guard case let .image(relocated)? = try cache.relocated(.image(name), from: path, to: newPath) else {
            return XCTFail("relocated icon missing")
        }
        let relocatedURL = try XCTUnwrap(cache.customImage(relocated, path: newPath))
        XCTAssertEqual(try Data(contentsOf: relocatedURL), thumb)
        XCTAssertTrue(model.setProjectIcon(.emoji("🚀"), path: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(model.setProjectIcon(nil, path: path))
        XCTAssertNil(try store.load().projects.first?.customIcon)
        model.setProjectImage(thumb, path: path)
        try cache.write(thumb, to: cache.autoImage(path))
        try cache.write(Data("{}".utf8), to: cache.metadata(path))
        XCTAssertTrue(model.forgetProject(path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.autoImage(path).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.metadata(path).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), [relocated])
    }

    private func makePNG(_ width: Int, _ height: Int) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        image.bitmapData?.initialize(repeating: 255, count: image.bytesPerRow * height)
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }
}
