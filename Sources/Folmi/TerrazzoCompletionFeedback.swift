import Foundation

/// A transient view policy: only a new, successful acceptance can arm review-completion feedback.
/// Opening a finished review, switching projects and partial diff loads establish state without celebrating.
struct TerrazzoCompletionFeedback {
    struct Snapshot: Equatable {
        let project: String?
        let enabled: Bool
        let acceptance: UUID?
        let reviewedKeys: Set<String>
        let total: Int
        let remaining: Int
        let loading: Bool
        let busy: Bool
        let completeList: Bool

        var settled: Bool { !loading && !busy }
    }

    private var previous: Snapshot?
    private var lastSettledRemaining: Int?
    private var lastSettledKeys: Set<String> = []
    private var pendingKeys: Set<String>?

    mutating func observe(_ snapshot: Snapshot) -> Bool {
        defer { previous = snapshot }
        guard let previous, snapshot.project != nil, snapshot.enabled,
              previous.project == snapshot.project, previous.enabled == snapshot.enabled else {
            pendingKeys = nil
            lastSettledRemaining = snapshot.settled && snapshot.completeList ? snapshot.remaining : nil
            lastSettledKeys = snapshot.reviewedKeys
            return false
        }

        if let acceptance = snapshot.acceptance, acceptance != previous.acceptance,
           (lastSettledRemaining ?? 0) > 0 {
            // Empty/binary files acquire their staged key after reload. Remember the pre-action ledger,
            // rather than requiring the new acceptance and its final key to arrive in the same view update.
            pendingKeys = lastSettledKeys
        }

        guard snapshot.settled else { return false }
        let addedKeys = pendingKeys.map { !snapshot.reviewedKeys.subtracting($0).isEmpty } ?? false
        let completed = addedKeys && snapshot.completeList && snapshot.total > 0 && snapshot.remaining == 0
        pendingKeys = nil
        lastSettledRemaining = snapshot.completeList ? snapshot.remaining : nil
        lastSettledKeys = snapshot.reviewedKeys
        return completed
    }
}
