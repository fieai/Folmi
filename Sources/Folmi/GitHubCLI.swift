import Foundation

struct GitHubRepository: Equatable, Sendable {
    let host: String
    let owner: String
    let name: String

    var argument: String { "\(host)/\(owner)/\(name)" }
    var loginCommand: String { host == "github.com" ? "gh auth login" : "gh auth login --hostname \(host)" }

    init?(remote: String) {
        let host: String, path: String
        if let url = URLComponents(string: remote), let scheme = url.scheme, ["https", "http", "ssh", "git"].contains(scheme),
           let urlHost = url.host {
            host = urlHost
            path = url.path
        } else {
            let parts = remote.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, !parts[0].contains("/"), let scpHost = parts[0].split(separator: "@").last else { return nil }
            host = String(scpHost)
            path = String(parts[1])
        }
        let names = path.split(separator: "/").map(String.init)
        guard names.count == 2 else { return nil }
        let name = names[1].hasSuffix(".git") ? String(names[1].dropLast(4)) : names[1]
        self.init(host: host, owner: names[0], name: name)
    }

    init?(host: String, owner: String, name: String) {
        guard host.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9.-]*/) != nil,
              owner.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]*/) != nil,
              name.wholeMatch(of: /[A-Za-z0-9_.-]+/) != nil, name != ".", name != ".." else { return nil }
        self.host = host.lowercased() == "ssh.github.com" ? "github.com" : host.lowercased()
        self.owner = owner
        self.name = name
    }

    func pullRequestLink(_ url: URL) -> GitHubPRLink? {
        let parts = url.path.split(separator: "/")
        guard url.scheme == "https" || url.scheme == "http", url.host?.lowercased() == host,
              parts.count == 4, parts[0].lowercased() == owner.lowercased(), parts[1].lowercased() == name.lowercased(),
              parts[2] == "pull", let number = Int(parts[3]), number > 0 else { return nil }
        return GitHubPRLink(number: number, url: url)
    }
}

struct GitHubPRLink: Equatable, Sendable {
    let number: Int
    let url: URL
}

enum GitHubAccess {
    case otherRemote
    case unavailable(reason: String, command: String)
    case ready(GitHubCLI)
}

actor GitHubExecutable {
    static let shared = GitHubExecutable()
    private var lookup: Task<URL?, Never>?

    func path() async -> URL? {
        if let lookup { return await lookup.value }
        let lookup = Task<URL?, Never> {
            for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            let command = DeliveryCommand(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v gh"])
            guard let result = try? await CommandRunner.run(command, at: FileManager.default.temporaryDirectory, timeout: 5),
                  result.exitCode == 0 else { return nil }
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        self.lookup = lookup
        return await lookup.value
    }
}

struct GitHubCLI: Sendable {
    typealias Locate = @Sendable () async -> URL?

    let repository: GitHubRepository
    let executable: URL
    let root: URL

    static func access(remote: String, at root: URL, locate: Locate) async throws -> GitHubAccess {
        guard let repository = GitHubRepository(remote: remote) else { return .otherRemote }
        let knownHost = repository.host == "github.com" || repository.host.hasSuffix(".ghe.com")
        guard let executable = await locate() else {
            return knownHost ? .unavailable(reason: "还没有安装 GitHub CLI。安装后重开 Folmi。", command: "brew install gh") : .otherRemote
        }
        let cli = GitHubCLI(repository: repository, executable: executable, root: root)
        let status = try await cli.run(["auth", "status", "--hostname", repository.host])
        if status.exitCode == 0 { return .ready(cli) }
        // Without a configured account a private host cannot be distinguished from another Git service.
        guard knownHost || status.combined.contains("account ") else { return .otherRemote }
        return .unavailable(reason: "请先用 GitHub CLI 登录 \(repository.host)。", command: repository.loginCommand)
    }

    func defaultBranch() async throws -> String? {
        struct Repository: Decodable {
            struct Branch: Decodable { let name: String }
            let defaultBranchRef: Branch?
        }
        let output = try await checked(["repo", "view", repository.argument, "--json", "defaultBranchRef"])
        return try Self.decode(Repository.self, output).defaultBranchRef?.name
    }

    func branchCommit(_ branch: String) async throws -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%"))
        guard let ref = branch.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw FolmiFailure(message: "默认分支名称无效。")
        }
        let output = try await checked(["api", "repos/\(repository.owner)/\(repository.name)/git/ref/heads/\(ref)",
                                        "--hostname", repository.host, "--jq", ".object.sha"])
        let commit = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.wholeMatch(of: /[0-9a-f]{40}|[0-9a-f]{64}/) != nil else {
            throw FolmiFailure(message: "GitHub 未返回默认分支的提交。")
        }
        return commit
    }

    func openPullRequest(branch: String, number: Int? = nil) async throws -> GitHubPullRequest? {
        let selector: String
        if let number { selector = String(number) }
        else if (branch.hasPrefix("#") ? branch.dropFirst() : branch[...]).wholeMatch(of: /[+-]?[0-9]+/) != nil {
            // gh treats a numeric selector as a PR number, even if the branch has that name.
            struct Match: Decodable { let number: Int; let isCrossRepository: Bool }
            let output = try await checked(["pr", "list", "--repo", repository.argument, "--state", "open",
                                            "--head", branch, "--json", "number,isCrossRepository"])
            guard let match = try Self.decode([Match].self, output).first(where: { !$0.isCrossRepository }) else { return nil }
            selector = String(match.number)
        } else { selector = branch }
        let result = try await run(["pr", "view", "--repo", repository.argument, "--json",
                                    "number,title,url,state,isDraft,reviewDecision,statusCheckRollup,headRefOid", "--", selector])
        if result.exitCode == 1, result.error.hasPrefix("no pull requests found for branch ") { return nil }
        let pr = try Self.decode(GitHubPullRequest.self, validate(result))
        guard repository.pullRequestLink(pr.url)?.number == pr.number else {
            throw FolmiFailure(message: "GitHub 返回的 PR 链接与当前仓库不匹配。")
        }
        return pr.state == "OPEN" ? pr : nil
    }

    func createPullRequest(branch: String, base: String, title: String, body: String, draft: Bool) async throws -> GitHubPRLink {
        var arguments = ["pr", "create", "--repo", repository.argument, "--head", branch,
                         "--base", base, "--title", title, "--body-file", "-"]
        if draft { arguments.append("--draft") }
        let output = try await checked(arguments, input: Data(body.utf8))
        guard let url = URL(string: output.trimmingCharacters(in: .whitespacesAndNewlines)),
              let link = repository.pullRequestLink(url) else {
            throw FolmiFailure(message: "GitHub CLI 未返回可识别的 PR 链接。请刷新确认创建结果。")
        }
        return link
    }

    func failedLog(for run: GitHubActionsRun) async throws -> String {
        let output = try await checked(["run", "view", run.id, "--repo", run.repository.argument, "--log-failed"],
                                       timeout: 60, keepStdoutTail: true)
        return Self.lastLogLines(output)
    }

    static func lastLogLines(_ output: String) -> String {
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(200).joined(separator: "\n")
    }

    func checked(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 20,
                 keepStdoutTail: Bool = false) async throws -> String {
        try validate(await run(arguments, input: input, timeout: timeout, keepStdoutTail: keepStdoutTail))
    }

    private func validate(_ result: CommandResult) throws -> String {
        guard result.exitCode == 0 else {
            let details = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            throw FolmiFailure(message: details.isEmpty ? "GitHub CLI 退出码 \(result.exitCode)。" : details)
        }
        return result.output
    }

    private func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 20,
                     keepStdoutTail: Bool = false) async throws -> CommandResult {
        try await CommandRunner.run(DeliveryCommand(executable: executable, arguments: arguments), at: root,
                                    environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
                                                  "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1", "NO_COLOR": "1", "GH_PAGER": "cat",
                                                  "GH_DEBUG": ""],
                                    input: input, timeout: timeout, keepStdoutTail: keepStdoutTail)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ output: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: Data(output.utf8)) }
        catch { throw FolmiFailure(message: "无法读取 GitHub CLI 返回的数据。") }
    }
}
