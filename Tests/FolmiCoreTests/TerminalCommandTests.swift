import XCTest
@testable import FolmiCore

final class TerminalCommandTests: XCTestCase {
    func testCommandResolvesProjectAndExactFilePosition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        try files.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("有 空格", isDirectory: true)
        try files.createDirectory(at: nested, withIntermediateDirectories: true)
        let name = "a..b & c.swift"
        let file = nested.appendingPathComponent(name)
        try "alpha\nbeta\n".write(to: file, atomically: true, encoding: .utf8)

        let folder = try TerminalCommand.link(for: ".", from: nested)
        XCTAssertEqual(MCPServer.parse(folder), .init(repository: root.path, path: nil, line: nil))
        let position = try TerminalCommand.link(for: name + ":2:3", from: nested)
        XCTAssertEqual(MCPServer.parse(position), .init(repository: root.path, path: "有 空格/" + name, line: 2,
                                                       column: 3, openInEditor: true))
        let literal = file.appendingPathExtension("txt:2")
        try "".write(to: literal, atomically: true, encoding: .utf8)
        let literalLink = try TerminalCommand.link(for: literal.path, from: nested)
        XCTAssertEqual(MCPServer.parse(literalLink)?.path, "有 空格/" + literal.lastPathComponent)
        XCTAssertNil(MCPServer.parse(literalLink)?.line)
        XCTAssertThrowsError(try TerminalCommand.link(for: name + ":0", from: nested))
        XCTAssertThrowsError(try TerminalCommand.link(for: ".:2", from: nested))
        XCTAssertThrowsError(try TerminalCommand.link(for: "missing.swift:2", from: nested))
        XCTAssertThrowsError(try TerminalCommand.link(for: "/", from: nested))
        let symlink = nested.appendingPathComponent("alias.swift")
        try files.createSymbolicLink(at: symlink, withDestinationURL: file)
        XCTAssertThrowsError(try TerminalCommand.link(for: symlink.lastPathComponent, from: nested))
    }
}
