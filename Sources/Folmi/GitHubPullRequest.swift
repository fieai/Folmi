import Foundation

struct GitHubPullRequest: Decodable, Sendable {
    let number: Int
    let title: String
    let url: URL
    let state: String
    let isDraft: Bool
    let reviewDecision: String?
    let statusCheckRollup: [GitHubCheck]?
    let headRefOid: String

    var failedChecks: [GitHubCheck] { (statusCheckRollup ?? []).filter(\.failed) }
    var statusTitle: String {
        if isDraft { return "草稿" }
        switch reviewDecision {
        case "APPROVED": return "评审已通过"
        case "CHANGES_REQUESTED": return "评审要求修改"
        case "REVIEW_REQUIRED": return "等待评审"
        default: return "已打开"
        }
    }

    func capsuleTitle(comments: [GitHubComment]?) -> String {
        let count = failedChecks.count
        var parts = ["PR #\(number)", "\(count) 项检查失败"]
        if let comments { parts.append("\(comments.count) 条评论没解决") }
        return parts.joined(separator: " · ")
    }
}

struct GitHubCheck: Decodable, Sendable {
    let name: String?
    let context: String?
    let conclusion: String?
    let state: String?
    let detailsUrl: URL?
    let targetUrl: URL?

    var title: String { name ?? context ?? "检查" }
    var url: URL? {
        guard let url = detailsUrl ?? targetUrl, url.scheme == "https" || url.scheme == "http", url.host != nil else { return nil }
        return url
    }
    var failed: Bool {
        switch conclusion ?? state {
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE": return true
        default: return false
        }
    }
}

struct GitHubActionsRun: Equatable, Sendable {
    let repository: GitHubRepository
    let id: String

    init?(check: GitHubCheck, on host: String) {
        guard let url = check.url, url.host?.lowercased() == host else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 5, parts[2] == "actions", parts[3] == "runs",
              parts[4].wholeMatch(of: /[0-9]+/) != nil,
              let repository = GitHubRepository(host: host, owner: String(parts[0]), name: String(parts[1])) else { return nil }
        self.repository = repository
        id = String(parts[4])
    }
}

struct GitHubComment: Identifiable, Equatable, Sendable {
    let id: String
    let path: String
    let line: Int?
    let originalLine: Int?
    let outdated: Bool
    let author: String
    let body: String

    var jumpLine: Int? { line ?? originalLine }
    var location: String { jumpLine.map { "\(path):\($0)" } ?? path }

    func locationMayHaveChanged(localHead: String?, pullRequestHead: String) -> Bool {
        localHead != pullRequestHead || outdated
    }

    var attachment: AgentContext {
        AgentContext(title: "GitHub 评审 · \(location)", text: "文件：\(location)\n评论人：\(author)\n\n\(body)")
    }
}

extension GitHubCLI {
    struct Connection<Node: Decodable>: Decodable {
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        let nodes: [Node?]
        let pageInfo: PageInfo

        func next(after current: String?) throws -> String? {
            guard pageInfo.hasNextPage else { return nil }
            guard let cursor = pageInfo.endCursor, cursor != current else {
                throw FolmiFailure(message: "GitHub 没有返回下一页的位置。")
            }
            return cursor
        }
    }

    struct Thread: Decodable {
        struct Comment: Decodable {
            struct Author: Decodable { let login: String }
            let id: String
            let author: Author?
            let body: String
        }
        let id: String
        let isResolved: Bool
        let isOutdated: Bool
        let path: String
        let line: Int?
        let originalLine: Int?
        let comments: Connection<Comment>

        func reviewComments(_ nodes: [Comment?]) -> [GitHubComment] {
            nodes.compactMap { $0 }.map {
                GitHubComment(id: $0.id, path: path, line: line, originalLine: originalLine, outdated: isOutdated,
                              author: $0.author?.login ?? "未知用户", body: $0.body)
            }
        }
    }

    struct Threads: Decodable {
        struct Data: Decodable {
            struct Repository: Decodable {
                struct PullRequest: Decodable { let reviewThreads: Connection<Thread> }
                let pullRequest: PullRequest
            }
            let repository: Repository
        }
        let data: Data
    }

    private struct ThreadReplies: Decodable {
        struct Data: Decodable {
            struct Node: Decodable { let comments: Connection<Thread.Comment> }
            let node: Node
        }
        let data: Data
    }

    // Read the per-thread flag because the connection has no resolution filter.
    private static let threadsQuery = """
        query FolmiThreads($owner: String!, $repo: String!, $number: Int!, $cursor: String) {
          repository(owner: $owner, name: $repo) {
            pullRequest(number: $number) {
              reviewThreads(first: 20, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id isResolved isOutdated path line originalLine
                  comments(first: 20) {
                    pageInfo { hasNextPage endCursor }
                    nodes { id author { login } body }
                  }
                }
              }
            }
          }
        }
        """

    private static let repliesQuery = """
        query FolmiReplies($id: ID!, $cursor: String!) {
          node(id: $id) {
            ... on PullRequestReviewThread {
              comments(first: 50, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes { id author { login } body }
              }
            }
          }
        }
        """

    func unresolvedComments(number: Int) async throws -> [GitHubComment] {
        var result: [GitHubComment] = []
        var cursor: String?
        repeat {
            var fields = ["-f", "owner=\(repository.owner)", "-f", "repo=\(repository.name)", "-F", "number=\(number)"]
            if let cursor { fields += ["-f", "cursor=\(cursor)"] }
            let page = try await graphql(Threads.self, query: Self.threadsQuery, fields: fields).data.repository.pullRequest.reviewThreads
            for case let thread? in page.nodes where !thread.isResolved {
                result += try await comments(in: thread)
            }
            cursor = try page.next(after: cursor)
        } while cursor != nil
        return result
    }

    private func comments(in thread: Thread) async throws -> [GitHubComment] {
        var page = thread.comments
        var cursor: String?
        var result = thread.reviewComments(page.nodes)
        while let next = try page.next(after: cursor) {
            cursor = next
            page = try await graphql(ThreadReplies.self, query: Self.repliesQuery,
                                     fields: ["-f", "id=\(thread.id)", "-f", "cursor=\(next)"]).data.node.comments
            result += thread.reviewComments(page.nodes)
        }
        return result
    }

    private func graphql<Response: Decodable>(_ type: Response.Type, query: String, fields: [String]) async throws -> Response {
        let output = try await checked(["api", "graphql", "--hostname", repository.host, "-f", "query=\(query)"] + fields)
        return try Self.decode(type, output)
    }
}
