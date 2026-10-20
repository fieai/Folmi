import Foundation
import FolmiCore

/// A local filter over the commits already loaded. Ref matches name the labelled commits, not branch ancestry.
enum HistoryFilter {
    static func matches(_ commits: [CommitNode], query: String) -> [CommitNode] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return commits }
        return commits.filter { commit in
            let fields = [commit.id, commit.shortID, commit.subject, commit.author, commit.email] + commit.refs
            return words.allSatisfy { word in fields.contains { $0.localizedCaseInsensitiveContains(word) } }
        }
    }
}
