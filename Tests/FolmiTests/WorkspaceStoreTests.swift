import XCTest
@testable import Folmi
import FolmiCore

final class WorkspaceStoreTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Folmi-StoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if let temporary { try FileManager.default.removeItem(at: temporary) }
    }

    private var configuration: URL { temporary.appendingPathComponent("Folmi-Config/workspace.json") }

    func testDefaultWorkspaceUsesFolmiDirectory() {
        XCTAssertEqual(WorkspaceStore.defaultURL.deletingLastPathComponent().lastPathComponent, "Folmi")
    }

    func testMissingFileReturnsDefaultsWithoutCreatingDirectories() throws {
        let store = WorkspaceStore(url: configuration)
        XCTAssertEqual(try store.load(), WorkspacePreferences())
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.deletingLastPathComponent().path))
    }

    func testRoundTripAndFreshStoreKeepProjectsIsolated() throws {
        let firstProfile = DeliveryProfile(name: "评审", kind: .gerrit, remote: "origin", branch: "main")
        let secondProfile = DeliveryProfile(name: "本地脚本", kind: .script, scriptPath: "/tmp/tool with spaces", scriptArguments: "one argument\ntwo words")
        let first = ProjectPreferences(rootPath: temporary.appendingPathComponent("first").path, name: "一号项目", draftMessage: "完整提交说明\n\nChange-Id: I123", amendLast: true, deliveryProfiles: [firstProfile], selectedProfileID: firstProfile.id, lastArea: "staged")
        let second = ProjectPreferences(rootPath: temporary.appendingPathComponent("second").path, name: "二号项目", draftMessage: "另一个草稿", deliveryProfiles: [secondProfile], selectedProfileID: secondProfile.id)
        let preferences = WorkspacePreferences(projects: [first, second], selectedProjectPath: second.rootPath, showTerminal: true, editorFontSize: 15)
        try WorkspaceStore(url: configuration).save(preferences)
        let restored = try WorkspaceStore(url: configuration).load()
        XCTAssertEqual(restored, preferences)
        XCTAssertEqual(restored.projects[0].draftMessage, first.draftMessage)
        XCTAssertEqual(restored.projects[1].deliveryProfiles, [secondProfile])
        XCTAssertNotEqual(restored.projects[0].deliveryProfiles, restored.projects[1].deliveryProfiles)
    }

    func testAtomicReplacementLeavesPrivateFileAndDirectory() throws {
        let store = WorkspaceStore(url: configuration)
        try store.save(WorkspacePreferences())
        var preferences = WorkspacePreferences()
        preferences.showTerminal = true
        try store.save(preferences)
        let manager = FileManager.default
        let fileMode = try manager.attributesOfItem(atPath: configuration.path)[.posixPermissions] as? NSNumber
        let directoryMode = try manager.attributesOfItem(atPath: configuration.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((fileMode?.intValue ?? 0) & 0o777, 0o600)
        XCTAssertEqual((directoryMode?.intValue ?? 0) & 0o777, 0o700)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: configuration.deletingLastPathComponent().path), ["workspace.json"])
        XCTAssertEqual(try store.load(), preferences)
    }

    func testMissingFieldsUseCompatibleDefaults() throws {
        try FileManager.default.createDirectory(at: configuration.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let old = Data("{\"projects\":[{\"rootPath\":\"/tmp/legacy-project\",\"deliveryProfiles\":[{\"name\":\"old push\"}]}],\"unrecognizedFutureHint\":true}".utf8)
        try old.write(to: configuration)
        let restored = try WorkspaceStore(url: configuration).load()
        XCTAssertEqual(restored.version, 1)
        XCTAssertEqual(restored.editorFontSize, 13)
        XCTAssertFalse(restored.showTerminal)
        XCTAssertEqual(restored.projects[0].name, "legacy-project")
        XCTAssertEqual(restored.projects[0].lastArea, "working")
        XCTAssertEqual(restored.projects[0].draftMessage, "")
        XCTAssertEqual(restored.projects[0].deliveryProfiles[0].kind, .push)
        XCTAssertEqual(restored.projects[0].deliveryProfiles[0].remote, "")
    }

    func testCorruptFileIsNotOverwrittenAfterLoadFailure() throws {
        let store = WorkspaceStore(url: configuration)
        try store.save(WorkspacePreferences())
        let corrupt = Data("{ broken personal draft".utf8)
        try corrupt.write(to: configuration)
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0.localizedDescription.contains("原文件未改动")) }
        XCTAssertThrowsError(try store.save(WorkspacePreferences()))
        XCTAssertEqual(try Data(contentsOf: configuration), corrupt)
    }

    func testUnknownVersionIsNotOverwritten() throws {
        let store = WorkspaceStore(url: configuration)
        try store.save(WorkspacePreferences())
        let future = Data("{\"version\":27,\"projects\":[]}".utf8)
        try future.write(to: configuration)
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0.localizedDescription.contains("版本 27")) }
        XCTAssertThrowsError(try store.save(WorkspacePreferences()))
        XCTAssertEqual(try Data(contentsOf: configuration), future)
        var invalid = WorkspacePreferences()
        invalid.version = 0
        XCTAssertThrowsError(try store.save(invalid))
    }

    func testOnlyIsolatedDemoEnvironmentCanBePersisted() throws {
        let root = temporary.appendingPathComponent("repository").path
        let safeEnvironment = ["HOME": temporary.appendingPathComponent("home").path,
                               "ZDOTDIR": temporary.appendingPathComponent("home").path,
                               "HISTFILE": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
                               "GIT_AUTHOR_NAME": "Demo User", "GIT_AUTHOR_EMAIL": "demo@example.invalid"]
        var preferences = WorkspacePreferences(projects: [ProjectPreferences(rootPath: root, name: "演示", isDemo: true, environment: safeEnvironment)])
        let store = WorkspaceStore(url: configuration)
        try store.save(preferences)
        XCTAssertEqual(try store.load(), preferences)
        let saved = try Data(contentsOf: configuration)
        preferences.projects[0].isDemo = false
        XCTAssertThrowsError(try store.save(preferences))
        preferences.projects[0].isDemo = true
        preferences.projects[0].environment["ACCESS_TOKEN"] = "never-persist-me"
        XCTAssertThrowsError(try store.save(preferences)) { XCTAssertFalse($0.localizedDescription.contains("never-persist-me")) }
        XCTAssertEqual(try Data(contentsOf: configuration), saved)
    }

    func testDemoCannotPersistRealHomeOrGitConfigPaths() throws {
        let root = temporary.appendingPathComponent("repository").path
        var project = ProjectPreferences(rootPath: root, name: "演示", isDemo: true, environment: ["HOME": "/Users/placeholder"])
        let store = WorkspaceStore(url: configuration)
        XCTAssertThrowsError(try store.save(WorkspacePreferences(projects: [project])))
        project.environment = ["GIT_CONFIG_GLOBAL": "/tmp/another-config"]
        XCTAssertThrowsError(try store.save(WorkspacePreferences(projects: [project])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.path))
    }

    func testGitAndSmartGitDestinationsAreRejectedWithoutCreatingThem() throws {
        for relative in ["repository/.git/config", "home/.gitconfig", "etc/gitconfig", "home/.git-credentials", "home/.config/git/credentials", "Library/Application Support/SmartGit/25.1/settings.xml", "home/.smartgit/settings"] {
            let unsafe = temporary.appendingPathComponent(relative)
            let store = WorkspaceStore(url: unsafe)
            XCTAssertThrowsError(try store.load(), relative)
            XCTAssertThrowsError(try store.save(WorkspacePreferences()), relative)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unsafe.deletingLastPathComponent().path), relative)
        }
    }

    func testSymlinkConfigurationDoesNotReadOrReplaceTarget() throws {
        let sentinel = temporary.appendingPathComponent("private-original")
        let bytes = Data("do not change".utf8)
        try bytes.write(to: sentinel)
        let link = temporary.appendingPathComponent("workspace.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        let store = WorkspaceStore(url: link)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(WorkspacePreferences()))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), sentinel.path)
    }

    func testSymlinkParentCannotRedirectSaveIntoProtectedDirectory() throws {
        let protected = temporary.appendingPathComponent("pretend/SmartGit", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let link = temporary.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: protected)
        let store = WorkspaceStore(url: link.appendingPathComponent("workspace.json"))
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(WorkspacePreferences()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: protected.path).isEmpty)
        let deeper = WorkspaceStore(url: link.appendingPathComponent("not-created/workspace.json"))
        XCTAssertThrowsError(try deeper.load())
        XCTAssertThrowsError(try deeper.save(WorkspacePreferences()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: protected.path).isEmpty)
        let missingProtected = temporary.appendingPathComponent("not-created/SmartGit", isDirectory: true)
        let broken = temporary.appendingPathComponent("broken-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: missingProtected)
        let throughBroken = WorkspaceStore(url: broken.appendingPathComponent("nested/workspace.json"))
        XCTAssertThrowsError(try throughBroken.load())
        XCTAssertThrowsError(try throughBroken.save(WorkspacePreferences()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingProtected.path))
    }

    func testDuplicatePathsAndIdentifiersAreRejected() throws {
        let root = temporary.appendingPathComponent("repository").path
        let first = ProjectPreferences(rootPath: root, name: "one")
        let duplicate = ProjectPreferences(rootPath: root + "/../repository", name: "two")
        let store = WorkspaceStore(url: configuration)
        XCTAssertThrowsError(try store.save(WorkspacePreferences(projects: [first, duplicate])))
        let profile = DeliveryProfile(name: "push", kind: .push)
        var invalid = first
        invalid.deliveryProfiles = [profile, profile]
        XCTAssertThrowsError(try store.save(WorkspacePreferences(projects: [invalid])))
    }

    func testDoesNotChangePermissionsOfGeneralParentDirectory() throws {
        let general = temporary.appendingPathComponent("general", isDirectory: true)
        try FileManager.default.createDirectory(at: general, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = WorkspaceStore(url: general.appendingPathComponent("workspace.json"))
        XCTAssertThrowsError(try store.save(WorkspacePreferences()))
        let mode = try FileManager.default.attributesOfItem(atPath: general.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testDiffDisplayChoicesPersistAndDefault() throws {
        var preferences = WorkspacePreferences()
        XCTAssertTrue(preferences.markdownDiffRendered)
        XCTAssertFalse(preferences.unifiedDiff)
        preferences.markdownDiffRendered = false; preferences.unifiedDiff = true
        let decoded = try JSONDecoder().decode(WorkspacePreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertFalse(decoded.markdownDiffRendered)
        XCTAssertTrue(decoded.unifiedDiff)
        let old = try JSONDecoder().decode(WorkspacePreferences.self, from: Data(#"{"version":1}"#.utf8))
        XCTAssertTrue(old.markdownDiffRendered, "files from before this setting show Markdown rendered")
        XCTAssertFalse(old.unifiedDiff)
    }

    func testStartCommandsAndTheirCountsRoundTripAndOldFilesReadEmpty() throws {
        var project = ProjectPreferences(rootPath: temporary.appendingPathComponent("web").path, name: "web")
        let command = LaunchCommand(directory: "api", name: "dev", command: "pnpm dev", source: LaunchCommand.customSource, port: 3000)
        project.launchCommands = [command]
        project.launchCounts = [command.id: 3]
        try WorkspaceStore(url: configuration).save(WorkspacePreferences(projects: [project]))
        let restored = try WorkspaceStore(url: configuration).load().projects[0]
        XCTAssertEqual(restored.launchCommands, [command])
        XCTAssertEqual(restored.launchCounts, [command.id: 3])
        let old = try JSONDecoder().decode(ProjectPreferences.self, from: Data(#"{"rootPath":"/tmp/x"}"#.utf8))
        XCTAssertEqual(old.launchCommands, [])
        XCTAssertEqual(old.launchCounts, [:])
    }

    @MainActor func testStartCommandsUsedMostComeFirstAndTiesKeepTheirOrder() {
        let commands = ["dev", "start", "serve", "preview"].map { LaunchCommand(directory: "", name: $0, command: "npm run \($0)", source: "package.json") }
        let counts = [commands[2].id: 5, commands[3].id: 1]
        XCTAssertEqual(FolmiModel.byUse(commands, counts: counts).map(\.name), ["serve", "preview", "dev", "start"])
    }
}
