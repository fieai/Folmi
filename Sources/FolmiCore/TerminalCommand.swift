import Foundation

public enum TerminalCommand {
    public static func link(for argument: String, from directory: URL) throws -> URL {
        let files = FileManager.default
        func fileURL(_ path: String) -> URL {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: directory)
                .absoluteURL.standardizedFileURL
        }

        var target = fileURL(argument)
        var isDirectory: ObjCBool = false
        var line: Int?, column: Int?
        // A literal file named "a:10" takes precedence over a reference to line 10 in "a".
        if !files.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            var parts = argument.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count > 1, let last = Int(parts.last!) {
                parts.removeLast()
                if parts.count > 1, let previous = Int(parts.last!) {
                    parts.removeLast()
                    line = previous
                    column = last
                } else { line = last }
                guard line.map({ $0 > 0 }) == true, column.map({ $0 > 0 }) != false else {
                    throw Failure(message: "行号和列号必须从 1 开始。")
                }
                target = fileURL(parts.joined(separator: ":"))
            }
            guard files.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                throw Failure(message: "找不到路径：\(argument)")
            }
        }
        guard let root = AIEventStore.locate(from: target)?.root else {
            throw Failure(message: "路径不在 Git 仓库里：\(argument)")
        }
        let relative: String?
        if isDirectory.boolValue {
            guard line == nil else { throw Failure(message: "文件夹不能指定行号：\(argument)") }
            relative = nil
        } else {
            guard let path = AIEventStore.safeRelativePath(target.path, cwd: directory, root: root) else {
                throw Failure(message: "无法打开这个项目文件：\(argument)")
            }
            relative = path
        }
        guard let link = MCPServer.link(repository: root.resolvingSymlinksInPath().path, path: relative,
                                        line: line, column: column, openInEditor: line != nil) else {
            throw Failure(message: "无法打开这个路径：\(argument)")
        }
        return link
    }

    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
