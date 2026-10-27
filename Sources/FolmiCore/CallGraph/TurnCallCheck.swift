import Foundation

/// At the end of an agent's turn: calls the turn left pointing at nothing (a function it deleted or renamed that
/// other files still call by the old name) and calls that no longer fit (a function whose parameters it changed).
/// Measured against the turn's own snapshot of the files before it touched them, so what was already broken
/// before the turn is not put on the agent. Only certain calls count: a guess must not send the agent off editing.
public enum TurnCallCheck {
    public struct Problem: Sendable, Equatable {
        /// `删了 getOrder（src/api.ts）`, `loadInvoice 的参数 (id) → (id, currency)`.
        public let summary: String
        /// `src/page.ts:12（OrderPage）`, with why the call no longer fits when it is about parameters.
        public let sites: [String]
    }

    /// Larger projects take too long to read while the agent waits; the check stays out of their way.
    static let sourceFileLimit = 5_000
    /// Each file the turn changed links the project once more; past this the rest is left unchecked.
    static let budget: TimeInterval = 20
    static let fileLimit = 20

    /// The message for the agent, or nil when the turn broke no call (or the check could not run).
    public static func run(root: URL, gitDir: URL, batch: String) -> String? {
        let pre = AIEventStore.batch(batch, gitDir: gitDir).appendingPathComponent("pre", isDirectory: true)
        guard AIEventStore.keptPaths(pre).contains(where: { SourceLanguage.of(path: $0) != nil }),
              let output = try? GitProcess(directory: root, environment: [:])
                .run(["ls-files", "-co", "--exclude-standard", "-z"], timeout: 10, stdoutLimit: 64 * 1_024 * 1_024) else { return nil }
        let files = output.text.split(separator: "\0").map(String.init)
        return message(problems(root: root, files: files, pre: pre))
    }

    static func problems(root: URL, files: [String], pre: URL, now: () -> Date = Date.init) -> [Problem] {
        let touched = AIEventStore.keptPaths(pre).filter { SourceLanguage.of(path: $0) != nil && !AIEventStore.isAbsent($0, in: pre) }.sorted()
        guard !touched.isEmpty, files.filter({ SourceLanguage.of(path: $0) != nil }).count <= sourceFileLimit else { return [] }
        let start = now()
        let graph = CallGraph.build(root: root, files: files, cache: CallGraphCache()).0
        var problems: [Problem] = []
        func site(_ path: String, _ line: Int, _ caller: String, _ problem: String? = nil) -> String {
            "\(path):\(line)（\(caller)）" + (problem.map { "：" + $0 } ?? "")
        }
        for path in touched.prefix(fileLimit) {
            guard now().timeIntervalSince(start) < budget,
                  let old = try? Data(contentsOf: pre.appendingPathComponent(path)), CallGraph.shouldRead(old) else { continue }
            let exists = FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
            // A file still there but not read (too large, minified) would look as if every function in it were gone.
            if exists, graph.outlines[path] == nil { continue }
            for item in graph.removedImpacts(path: exists ? path : nil, oldPath: path, oldData: old) {
                let sites = item.sites.filter(\.certain)
                guard !sites.isEmpty else { continue }
                let name = item.symbol.qualifiedName
                let summary = item.renamedTo.map { "\(name) 改名为 \($0)（\(path)），旧名字还有 \(sites.count) 处在调用" }
                    ?? "删了 \(name)（\(path)），旧名字还有 \(sites.count) 处在调用"
                problems.append(Problem(summary: summary, sites: sites.map { site($0.path, $0.line, $0.caller) }))
            }
            guard exists else { continue }
            for item in graph.signatureImpacts(path: path, oldData: old) {
                let broken = item.broken.filter(\.certain)
                guard !broken.isEmpty else { continue }
                problems.append(Problem(summary: "\(item.symbol.qualifiedName)（\(path)）的参数 \(item.before) → \(item.after)，\(broken.count) 处调用没跟着改",
                                        sites: broken.map { site($0.path, $0.line, $0.caller, $0.problem) }))
            }
        }
        return problems
    }

    /// Written for the agent, in the user's language: the user reads it in the agent's transcript too.
    static func message(_ problems: [Problem]) -> String? {
        guard !problems.isEmpty else { return nil }
        var lines = ["Folmi 在这一轮结束时检查了调用关系：这一轮的改动让下面这些调用对不上了。"]
        for problem in problems.prefix(10) {
            lines.append("- " + problem.summary)
            for site in problem.sites.prefix(8) { lines.append("  - " + site) }
            if problem.sites.count > 8 { lines.append("  - 还有 \(problem.sites.count - 8) 处") }
        }
        if problems.count > 10 { lines.append("- 还有 \(problems.count - 10) 项没列出") }
        lines.append("")
        lines.append("请把这些调用改好再结束。如果是有意的（比如这些调用方也要删），或者认错了（这是按代码静态分析的），不用改，在回复里说一句原因就行。")
        return lines.joined(separator: "\n")
    }
}
