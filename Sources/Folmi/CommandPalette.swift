import AppKit
import SwiftUI

/// One row of ⌘K: a file, a change, a Markdown heading or task, a commit, or a command.
struct PaletteItem: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case command, change, file, heading, task, commit
        var label: String {
            switch self {
            case .command: return "命令"
            case .change: return "改动"
            case .file: return "文件"
            case .heading: return "标题"
            case .task: return "待办"
            case .commit: return "提交"
            }
        }
        var symbol: String {
            switch self {
            case .command: return "command"
            case .change: return "plusminus"
            case .file: return "doc.text"
            case .heading: return "number"
            case .task: return "checklist.unchecked"
            case .commit: return "clock.arrow.circlepath"
            }
        }
    }
    enum Action: Sendable {
        case openFile(String)
        case openLine(String, Int)
        case showChange(String)
        case showCommit(String)
        case command(String)
        /// The last row for any free text: hands it to the agent in the AI tab.
        case askAgent(String)
    }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let action: Action
    /// Lower-cased, diacritic-folded UTF-8 of the title (with keywords) and of title + subtitle, made once: matching
    /// bytes is what keeps ⌘K at a few milliseconds per keystroke on 30 000 files.
    let titleBytes: [UInt8]
    let allBytes: [UInt8]

    init(id: String, kind: Kind, title: String, subtitle: String, action: Action, keywords: String = "") {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.action = action
        titleBytes = Array(PaletteRanking.fold(title + (keywords.isEmpty ? "" : " " + keywords)).utf8)
        allBytes = titleBytes + [32] + Array(PaletteRanking.fold(subtitle).utf8)
    }
}

/// How often and how recently each item was picked, so what you use comes first ("frecency").
struct PaletteUsage: Codable, Sendable {
    struct Record: Codable, Sendable { var count: Int; var last: Date }
    var records: [String: Record] = [:]

    mutating func note(_ id: String) {
        var record = records[id] ?? Record(count: 0, last: Date())
        record.count += 1; record.last = Date()
        records[id] = record
        if records.count > 600 {
            for key in records.sorted(by: { $0.value.last < $1.value.last }).prefix(records.count - 500).map(\.key) { records[key] = nil }
        }
    }
    func boost(_ id: String, now: Date = Date()) -> Int {
        guard let record = records[id] else { return 0 }
        let age = now.timeIntervalSince(record.last)
        let recency = age < 3_600 ? 260 : age < 86_400 ? 180 : age < 7 * 86_400 ? 90 : 20
        return min(400, record.count * 45) + recency
    }

    private static var url: URL { AppFiles.directory.appendingPathComponent("palette-usage.json") }
    static func load() -> PaletteUsage {
        guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(PaletteUsage.self, from: data) else { return PaletteUsage() }
        return value
    }
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppLog.attempt("⌘K 使用记录写入失败") { try data.write(to: Self.url, options: .atomic) }
    }
}

enum PaletteRanking {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Best first. An empty query lists recently used items, then commands and changes.
    static func rank(_ items: [PaletteItem], query raw: String, usage: PaletteUsage, limit: Int = 60) -> [PaletteItem] {
        rankKeepingMatches(items, query: raw, usage: usage, limit: limit).top
    }
    /// Also returns every item that matched, so the next keystroke (a longer query) only searches those.
    static func rankKeepingMatches(_ items: [PaletteItem], query raw: String, usage: PaletteUsage, limit: Int = 60) -> (top: [PaletteItem], matched: [PaletteItem]) {
        var query = raw.trimmingCharacters(in: .whitespaces)
        var only: PaletteItem.Kind?
        if let first = query.first, let kind = ["›": PaletteItem.Kind.command, ">": .command, "#": .heading, "@": .commit, "[": .task][first] {
            only = kind; query = String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let words = fold(query).split(separator: " ").map { Array($0.utf8) }
        let now = Date()
        var best = TopScores(limit: limit)
        var matched: [PaletteItem] = []
        for (index, item) in items.enumerated() where only == nil || item.kind == only {
            if words.isEmpty {
                let boost = usage.boost(item.id, now: now)
                let base = boost > 0 ? 1_000 + boost : (item.kind == .command ? 300 : item.kind == .change ? 250 : 0)
                if base > 0 || only != nil { best.offer(base, index, item.title.count) }
                continue
            }
            guard let score = match(words, item) else { continue }
            matched.append(item)
            best.offer(score + usage.boost(item.id, now: now), index, item.title.count)
        }
        return (best.sorted.map { items[$0] }, words.isEmpty ? items : matched)
    }

    /// Words of the query must all appear; the title is worth more than the path, a word start more than the middle.
    static func match(_ words: [[UInt8]], _ item: PaletteItem) -> Int? {
        var total = 0
        for word in words {
            if let at = find(word, in: item.titleBytes) {
                total += at == 0 ? 900 : (" /-_.".utf8.contains(item.titleBytes[at - 1]) ? 700 : 500)
            } else if find(word, in: item.allBytes) != nil { total += 250 }
            else if let fuzzy = subsequence(word, in: item.titleBytes) { total += 100 + fuzzy }
            else { return nil }
        }
        let kindWeight: Int
        switch item.kind {
        case .command: kindWeight = 60
        case .change: kindWeight = 50
        case .file, .heading: kindWeight = 30
        case .task: kindWeight = 20
        case .commit: kindWeight = 0
        }
        return total + kindWeight - min(item.titleBytes.count, 80)
    }

    @inline(__always) private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        let n = needle.count, h = haystack.count
        guard n > 0, n <= h, let first = needle.first else { return n == 0 ? 0 : nil }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { pin in
                var i = 0
                while i <= h - n {
                    if hay[i] == first {
                        var j = 1
                        while j < n && hay[i + j] == pin[j] { j += 1 }
                        if j == n { return i }
                    }
                    i += 1
                }
                return nil
            }
        }
    }

    private static func subsequence(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        var position = 0, run = 0, best = 0
        for byte in needle {
            var found = false
            while position < haystack.count {
                let next = haystack[position]; position += 1
                if next == byte { found = true; run += 1; best = max(best, run); break }
                run = 0
            }
            if !found { return nil }
        }
        return min(99, best * 10)
    }
}

/// The best `limit` scores without sorting every match.
private struct TopScores {
    let limit: Int
    private var entries: [(score: Int, index: Int, length: Int)] = []
    init(limit: Int) { self.limit = limit; entries.reserveCapacity(limit + 1) }
    private static func better(_ a: (score: Int, index: Int, length: Int), _ b: (score: Int, index: Int, length: Int)) -> Bool {
        a.score != b.score ? a.score > b.score : a.length < b.length
    }
    mutating func offer(_ score: Int, _ index: Int, _ length: Int) {
        let entry = (score: score, index: index, length: length)
        if entries.count == limit, let last = entries.last, !Self.better(entry, last) { return }
        let position = entries.firstIndex { Self.better(entry, $0) } ?? entries.count
        entries.insert(entry, at: position)
        if entries.count > limit { entries.removeLast() }
    }
    var sorted: [Int] { entries.map(\.index) }
}

struct CommandPaletteSheet: View {
    let items: [PaletteItem]
    let usage: PaletteUsage
    let onPick: (PaletteItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = 0
    @State private var results: [PaletteItem] = []
    /// The items that matched the previous query; typing more only narrows them.
    @State private var narrowed: (query: String, items: [PaletteItem])?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("文件、标题、待办、提交、命令……（> 命令 · # 标题 · [ 待办 · @ 提交）", text: $query)
                    .textFieldStyle(.plain).themedFont(.system(size: 16), points: 16).focused($focused)
                    .onSubmit { pick(selected) }
                    .accessibilityIdentifier("palette-query")
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if results.isEmpty {
                            Text(query.isEmpty ? "输入几个字开始找" : "没有找到").themedFont(.callout, points: 12).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                        // One identity per row, the item's own: a second `.id(index)` here let the lazy stack keep
                        // showing an earlier query's row at that position while Return ran the new one.
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            row(item, selected: index == selected)
                                .onTapGesture { pick(index) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(index == selected ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { pick(index) }
                        }
                    }.padding(6)
                }
                .onChange(of: selected) { _, index in if results.indices.contains(index) { proxy.scrollTo(results[index].id) } }
            }
            .frame(height: 380)
        }
        .frame(width: 680)
        .onAppear { focused = true; refresh() }
        .onChange(of: query) { _, _ in selected = 0; refresh() }
        .onKeyPress(.downArrow) { selected = min(results.count - 1, selected + 1); return .handled }
        .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func refresh() {
        // A query that only grows (no prefix filter change) can only match a subset of what matched before.
        let source: [PaletteItem]
        if let narrowed, !narrowed.query.isEmpty, query.hasPrefix(narrowed.query), narrowed.query.first == query.first { source = narrowed.items }
        else { source = items }
        let ranked = PaletteRanking.rankKeepingMatches(source, query: query, usage: usage)
        results = ranked.top
        narrowed = (query, ranked.matched)
        // Free text (not a > # [ @ filter): the last row asks the agent instead.
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.count >= 2, let first = text.first, !">#[@".contains(first) {
            results.append(PaletteItem(id: "ask-agent", kind: .command, title: "问 agent：\(text)", subtitle: "在 AI 标签里交给 Claude / Codex",
                                       action: .askAgent(text)))
        }
    }
    private func pick(_ index: Int) {
        guard results.indices.contains(index) else { return }
        let item = results[index]
        dismiss()
        onPick(item)
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).themedFont(.system(size: 13, weight: .medium), points: 13).lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).themedFont(.system(size: 11), points: 11).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            Text(item.kind.label).themedFont(.caption2, points: 10).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2).themedCapsule(Color.primary.opacity(0.06))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .themedBackground(ThemeColor(token: .selectedFill, opacity: selected ? 1 : 0))
    }
}
