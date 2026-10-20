import Foundation

/// What was done each day across projects, for the wrap-up card: hunks accepted / rejected and Claude turns taken
/// back. Commits come from the repository itself. Kept for 60 days in daily-stats.json next to the settings.
struct DailyStats: Codable, Equatable {
    struct Day: Codable, Equatable {
        var accepted = 0
        var rejected = 0
        var aiUndone = 0
    }
    enum Kind { case accepted, rejected, aiUndone }

    var days: [String: Day] = [:]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func today(_ now: Date = Date()) -> Day { days[Self.dayKey(now)] ?? Day() }

    mutating func record(_ kind: Kind, count: Int = 1, now: Date = Date(), calendar: Calendar = .current) {
        let key = Self.dayKey(now, calendar: calendar)
        var day = days[key] ?? Day()
        switch kind {
        case .accepted: day.accepted += count
        case .rejected: day.rejected += count
        case .aiUndone: day.aiUndone += count
        }
        days[key] = day
        if days.count > 60 { for old in days.keys.sorted().prefix(days.count - 60) { days.removeValue(forKey: old) } }
    }

    /// Days in a row with something reviewed, ending today (or yesterday, while today has nothing yet).
    func streak(now: Date = Date(), calendar: Calendar = .current) -> Int {
        var date = now
        if days[Self.dayKey(date, calendar: calendar)] == nil { date = calendar.date(byAdding: .day, value: -1, to: date) ?? date }
        var count = 0
        while days[Self.dayKey(date, calendar: calendar)] != nil {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    private static var url: URL { AppFiles.directory.appendingPathComponent("daily-stats.json") }
    static func load() -> DailyStats {
        guard let data = try? Data(contentsOf: url), let stats = try? JSONDecoder().decode(DailyStats.self, from: data) else { return DailyStats() }
        return stats
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let url = Self.url
        DispatchQueue.global(qos: .utility).async { AppLog.attempt("每日计数写入失败") { try data.write(to: url, options: .atomic) } }
    }
}

extension FolmiModel {
    func recordDaily(_ kind: DailyStats.Kind, count: Int = 1) {
        dailyStats.record(kind, count: count)
        dailyStats.save()
    }

    /// One line for the wrap-up card, e.g. 「今天验收 42 处 · 撤回 3 处 · 提交 5 次」; nil on a day with nothing done.
    var daySummaryLine: String? {
        let day = dailyStats.today()
        var parts: [String] = []
        if day.accepted > 0 { parts.append("验收 \(day.accepted) 处") }
        if day.rejected > 0 { parts.append("撤回 \(day.rejected) 处") }
        if day.aiUndone > 0 { parts.append("撤销 Claude \(day.aiUndone) 轮") }
        if let commits = daySummary?.commitsToday, commits > 0 { parts.append("提交 \(commits) 次") }
        return parts.isEmpty ? nil : "今天" + parts.joined(separator: " · ")
    }
}
