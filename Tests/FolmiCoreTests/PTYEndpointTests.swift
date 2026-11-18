import Darwin
import Foundation
import XCTest
@testable import FolmiCore

final class PTYEndpointTests: XCTestCase {
    func testCurrentProcessHasResourceCoalition() throws {
        XCTAssertNotEqual(try XCTUnwrap(PTYProcess.resourceCoalition(of: getpid())), 0)
    }

    func testInstallUsesBundleContentsAndDropsQuarantine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("FolmiTerminal.app", isDirectory: true)
        let executable = source.appendingPathComponent("Contents/MacOS/folmi-pty")
        let plist = source.appendingPathComponent("Contents/Info.plist")
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try writePlist(version: "1", to: plist)

        let name = "com.apple.quarantine"
        let value = Array("0081;00000000;FolmiTest;".utf8)
        for url in [source, executable, plist] {
            XCTAssertEqual(value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, 0) }, 0)
            XCTAssertGreaterThan(getxattr(url.path, name, nil, 0, 0, 0), 0)
        }

        let endpoint = PTYEndpoint(settingsDirectory: root.appendingPathComponent("settings"))
        let installed = try endpoint.install(source)
        let copy = installed.appendingPathComponent("Contents/MacOS/folmi-pty")
        let copiedPlist = installed.appendingPathComponent("Contents/Info.plist")
        XCTAssertNotNil(installed.lastPathComponent.range(of: #"^FolmiTerminal-[0-9a-f]{12}\.app$"#, options: .regularExpression))
        XCTAssertTrue(manager.isExecutableFile(atPath: copy.path))
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: executable))
        XCTAssertEqual(try Data(contentsOf: copiedPlist), try Data(contentsOf: plist))
        for url in [installed, copy, copiedPlist] {
            let length = getxattr(url.path, name, nil, 0, 0, 0)
            let error = errno
            XCTAssertEqual(length, -1)
            XCTAssertEqual(error, ENOATTR)
        }
        try manager.removeItem(at: installed)
        XCTAssertEqual(try endpoint.install(source), installed)
        try writePlist(version: "2", to: plist)
        let revised = try endpoint.install(source)
        XCTAssertNotEqual(revised, installed)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: executable)
        XCTAssertNotEqual(try endpoint.install(source), revised)
    }

    private func writePlist(version: String, to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "folmi-pty",
            "CFBundleVersion": version,
            "LSBackgroundOnly": true
        ], format: .xml, options: 0)
        try data.write(to: url)
    }
}
