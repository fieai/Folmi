import Foundation

/// One column of a split card: its tabs in order and the one it shows.
struct PaneColumn: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Editor: document ids (project paths). Terminal: session ids. Empty for the 差异 column.
    var tabs: [String] = []
    var selected: String?
    /// The editor's 差异 column: it shows the changes selected on the left and holds no tabs.
    var isDiff = false

    init(tabs: [String] = [], selected: String? = nil, isDiff: Bool = false) {
        self.tabs = tabs; self.selected = selected ?? tabs.first; self.isDiff = isDiff
    }
}

/// The columns a card is split into, side by side (向左拆分 / 向右拆分). Pure state so it can be tested and saved.
/// Always at least one tab column; `active` is the tab column the keyboard works on, never the 差异 column.
struct PaneColumns: Codable, Equatable {
    static let limit = 3

    private(set) var columns: [PaneColumn] = [PaneColumn()]
    /// Each column's share of the card's width; they add up to 1.
    private(set) var fractions: [Double] = [1]
    private(set) var activeID: UUID

    init() { activeID = columns[0].id }
    init(tabs: [String], selected: String?) {
        columns = [PaneColumn(tabs: tabs, selected: selected.flatMap { tabs.contains($0) ? $0 : nil })]
        activeID = columns[0].id
    }

    var isSplit: Bool { columns.count > 1 }
    var canSplit: Bool { columns.count < Self.limit }
    var hasDiff: Bool { columns.contains(where: \.isDiff) }
    var activeIndex: Int { columns.firstIndex { $0.id == activeID } ?? 0 }
    var active: PaneColumn { columns[activeIndex] }
    var selected: String? { active.selected }
    /// Every tab once, in column order.
    var allTabs: [String] {
        var seen = Set<String>()
        return columns.flatMap(\.tabs).filter { seen.insert($0).inserted }
    }
    func index(of id: UUID) -> Int? { columns.firstIndex { $0.id == id } }
    func column(containing tab: String) -> Int? { columns.firstIndex { $0.tabs.contains(tab) } }

    mutating func activate(_ id: UUID) {
        guard let index = index(of: id), !columns[index].isDiff else { return }
        activeID = id
    }

    /// Shows `tab`: in the active column if it is there, else in the column that has it, else added to the active column.
    mutating func select(_ tab: String?) {
        guard let tab else { columns[activeIndex].selected = nil; return }
        if !active.tabs.contains(tab), let other = column(containing: tab) { activeID = columns[other].id }
        let index = activeIndex
        if !columns[index].tabs.contains(tab) { columns[index].tabs.append(tab) }
        columns[index].selected = tab
    }
    /// Shows `tab` in one column, adding it there when that column does not have it.
    mutating func select(_ tab: String, in id: UUID) {
        guard let index = index(of: id), !columns[index].isDiff else { return }
        if !columns[index].tabs.contains(tab) { columns[index].tabs.append(tab) }
        columns[index].selected = tab
        activeID = id
    }

    /// Takes the tab out of one column (or every column). A split column left empty goes away.
    mutating func remove(_ tab: String, from id: UUID? = nil) {
        for index in columns.indices.reversed() where id == nil || columns[index].id == id {
            guard let position = columns[index].tabs.firstIndex(of: tab) else { continue }
            columns[index].tabs.remove(at: position)
            if columns[index].selected == tab {
                let tabs = columns[index].tabs
                columns[index].selected = tabs.isEmpty ? nil : tabs[min(position, tabs.count - 1)]
            }
            if columns[index].tabs.isEmpty && tabColumnCount > 1 { dropColumn(at: index) }
        }
        dropLoneDiff()
    }

    /// Keeps only these tabs, in the given order within each column (used when tabs close or the session is restored).
    mutating func keep(_ tabs: [String]) {
        let valid = Set(tabs)
        for index in columns.indices {
            columns[index].tabs = columns[index].tabs.filter(valid.contains)
            if let selected = columns[index].selected, !valid.contains(selected) { columns[index].selected = columns[index].tabs.first }
            if columns[index].selected == nil { columns[index].selected = columns[index].tabs.first }
        }
        for index in columns.indices.reversed() where !columns[index].isDiff && columns[index].tabs.isEmpty && tabColumnCount > 1 {
            dropColumn(at: index)
        }
        // Tabs no column holds join the active one.
        let held = Set(columns.flatMap(\.tabs))
        let missing = tabs.filter { !held.contains($0) }
        if !missing.isEmpty { columns[activeIndex].tabs += missing }
        if columns[activeIndex].selected == nil { columns[activeIndex].selected = columns[activeIndex].tabs.first }
        dropLoneDiff()
    }

    /// A new column beside `id` showing `tab`. With `move` the tab leaves its column (unless it is the only one there).
    /// Returns the new column's id; nil when the card already has the most columns.
    @discardableResult
    mutating func split(_ tab: String?, from id: UUID, toRight: Bool, move: Bool) -> UUID? {
        guard canSplit, let source = index(of: id) else { return nil }
        var column = PaneColumn(tabs: tab.map { [$0] } ?? [])
        column.selected = tab
        if move, let tab, columns[source].tabs.count > 1, columns[source].tabs.contains(tab) {
            columns[source].tabs.removeAll { $0 == tab }
            if columns[source].selected == tab { columns[source].selected = columns[source].tabs.first }
        }
        insert(column, beside: source, toRight: toRight)
        activeID = column.id
        return column.id
    }

    /// Adds the editor's 差异 column at the card's left or right edge; the tab columns keep their order.
    mutating func addDiff(atRight: Bool) {
        guard !hasDiff, canSplit else { return }
        insert(PaneColumn(isDiff: true), beside: atRight ? columns.count - 1 : 0, toRight: atRight)
    }

    /// Moves the tab to the nearest tab column on that side. Returns false when there is none.
    @discardableResult
    mutating func move(_ tab: String, from id: UUID, toRight: Bool) -> Bool {
        guard let source = index(of: id), let target = neighbour(of: source, toRight: toRight) else { return false }
        let targetID = columns[target].id
        if !columns[target].tabs.contains(tab) { columns[target].tabs.append(tab) }
        columns[target].selected = tab
        activeID = targetID
        remove(tab, from: id)
        return true
    }
    func neighbour(of index: Int, toRight: Bool) -> Int? {
        let candidates = toRight ? Array(columns.indices.dropFirst(index + 1)) : Array(columns.indices.prefix(index).reversed())
        return candidates.first { !columns[$0].isDiff }
    }

    /// Closes a column without closing anything in it: its tabs join the tab column on its left (else on its right).
    /// The last tab column cannot close; closing it beside 差异 closes the 差异 column instead.
    mutating func merge(_ id: UUID) {
        guard isSplit, let index = index(of: id) else { return }
        if columns[index].isDiff { dropColumn(at: index); return }
        guard let target = neighbour(of: index, toRight: false) ?? neighbour(of: index, toRight: true) else {
            if let diff = columns.firstIndex(where: \.isDiff) { dropColumn(at: diff) }
            return
        }
        let moving = columns[index]
        for tab in moving.tabs where !columns[target].tabs.contains(tab) { columns[target].tabs.append(tab) }
        if let selected = moving.selected { columns[target].selected = selected }
        let targetID = columns[target].id
        dropColumn(at: index)
        activeID = targetID
    }
    /// Puts `new` wherever `old` was (a terminal tab whose shell was restarted).
    mutating func replace(_ old: String, with new: String) {
        for index in columns.indices {
            columns[index].tabs = columns[index].tabs.map { $0 == old ? new : $0 }
            if columns[index].selected == old { columns[index].selected = new }
        }
    }
    /// The same columns with each tab renamed; tabs mapped to nil are dropped. Run `keep` afterwards.
    func mapTabs(_ transform: (String) -> String?) -> PaneColumns {
        var copy = self
        for index in copy.columns.indices {
            copy.columns[index].tabs = copy.columns[index].tabs.compactMap(transform)
            copy.columns[index].selected = copy.columns[index].selected.flatMap(transform)
        }
        return copy
    }
    mutating func removeDiff() {
        if let diff = columns.firstIndex(where: \.isDiff) { dropColumn(at: diff) }
    }

    /// Sets the width of column `index` and its right neighbour together, as the handle between them is dragged.
    mutating func resize(_ index: Int, to fraction: Double, minimum: Double) {
        guard columns.indices.contains(index + 1) else { return }
        let pair = fractions[index] + fractions[index + 1]
        let low = min(minimum, pair / 2)
        let value = Swift.max(low, Swift.min(pair - low, fraction))
        fractions[index] = value
        fractions[index + 1] = pair - value
    }
    mutating func equalize() { fractions = Array(repeating: 1 / Double(columns.count), count: columns.count) }

    private var tabColumnCount: Int { columns.filter { !$0.isDiff }.count }

    private mutating func insert(_ column: PaneColumn, beside index: Int, toRight: Bool) {
        // The new column takes half of the one it splits from, so the others keep their widths.
        let half = fractions[index] / 2
        fractions[index] = half
        let position = toRight ? index + 1 : index
        columns.insert(column, at: position)
        fractions.insert(half, at: position)
    }
    private mutating func dropColumn(at position: Int) {
        let share = fractions[position]
        columns.remove(at: position)
        fractions.remove(at: position)
        if columns.isEmpty { columns = [PaneColumn()]; fractions = [1]; activeID = columns[0].id; return }
        // The width goes to the column on its left, else to the one that took its place.
        fractions[position > 0 ? position - 1 : 0] += share
        if index(of: activeID) == nil || columns[activeIndex].isDiff,
           let next = columns.firstIndex(where: { !$0.isDiff }) { activeID = columns[next].id }
    }
    /// 差异 never stands alone: with one tab column left beside nothing else, the card is not split any more.
    private mutating func dropLoneDiff() {
        if columns.count == 1, columns[0].isDiff { columns = [PaneColumn()]; fractions = [1]; activeID = columns[0].id }
    }

    private enum CodingKeys: String, CodingKey { case columns, fractions, activeID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        var columns = Array(((try? values.decodeIfPresent([PaneColumn].self, forKey: .columns)) ?? []).prefix(Self.limit))
        // A saved diff column needs a tab column beside it, and only one diff column counts.
        var seenDiff = false
        columns = columns.filter { column in
            guard column.isDiff else { return true }
            defer { seenDiff = true }
            return !seenDiff
        }
        if !columns.contains(where: { !$0.isDiff }) { columns = [PaneColumn()] }
        self.columns = columns
        let saved = (try? values.decodeIfPresent([Double].self, forKey: .fractions)) ?? []
        let total = saved.reduce(0, +)
        if saved.count == columns.count, saved.allSatisfy({ $0.isFinite && $0 > 0 }), total > 0 {
            fractions = saved.map { $0 / total }
        } else {
            fractions = Array(repeating: 1 / Double(columns.count), count: columns.count)
        }
        let saveActive = try? values.decodeIfPresent(UUID.self, forKey: .activeID)
        activeID = columns.first { $0.id == saveActive && !$0.isDiff }?.id ?? columns.first { !$0.isDiff }!.id
    }
}
