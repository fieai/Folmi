import AppKit
import SwiftUI
import FolmiCore

/// Where an open task goes on the 待办 page, by its dates (TaskDates). Pure, so the rules are tested apart from the view.
enum TaskBucket: String, CaseIterable, Identifiable {
    case overdue = "过期", today = "今天", week = "这周", later = "以后", undated = "没日期"
    var id: String { rawValue }

    /// Past its deadline → 过期; due today, or planned for today or earlier → 今天; then the rest of this week, later,
    /// and no date at all. A planned day never makes a task 过期: only a missed deadline does.
    static func of(_ dates: TaskDates, today: String, weekEnd: String) -> TaskBucket {
        if let due = dates.due, due < today { return .overdue }
        guard let day = dates.day else { return .undated }
        if day <= today { return .today }
        return day <= weekEnd ? .week : .later
    }

    /// The last day of the week `now` is in, by the user's calendar (its first weekday included).
    static func weekEnd(_ now: Date = Date(), calendar: Calendar = .current) -> String { TaskWeek(now, calendar: calendar).end }
}

/// Today and the first and last day of this week, as `yyyy-MM-dd`.
struct TaskWeek: Equatable {
    let today: String
    let start: String
    let end: String
    init(_ now: Date = Date(), calendar: Calendar = .current) {
        today = TaskDates.key(now, calendar: calendar)
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            start = TaskDates.key(week.start, calendar: calendar)
            end = TaskDates.key(week.end.addingTimeInterval(-1), calendar: calendar)
        } else { start = today; end = today }
    }
    init(today: String, start: String, end: String) { self.today = today; self.start = start; self.end = end }
}

/// The four numbers on top of the page, each also a filter on the list. 这周做完的 lists done tasks; the rest open ones.
enum TaskFilter: String, CaseIterable, Identifiable {
    case all = "没做完的", dueNow = "今天和过期的", thisWeek = "这周到期的", doneThisWeek = "这周做完的"
    var id: String { rawValue }

    func includes(_ task: MarkdownIndex.Entry, week: TaskWeek) -> Bool {
        guard self == .doneThisWeek || task.status.isOpen else { return false }
        switch self {
        case .all: return true
        case .dueNow: return [.overdue, .today].contains(TaskBucket.of(task.dates, today: week.today, weekEnd: week.end))
        case .thisWeek: return task.dates.due.map { $0 >= week.today && $0 <= week.end } ?? false
        case .doneThisWeek: return task.status == .done && task.dates.done.map { $0 >= week.start && $0 <= week.today } ?? false
        }
    }
}

/// Where the 待办 page reads its tasks: the notes of every project (default), or this project's own Markdown.
enum TaskSource: String {
    case ideas, project
}

/// 待办: the open tasks in every project's 随手记, by date or by note; the open project's other Markdown is one quiet
/// menu away. Everything here is read from the files, and every change (完成, 设日期) is an edit of that one line,
/// through an editor so drafts and disk conflicts are kept.
struct TasksPage: View {
    let model: FolmiModel
    @Environment(\.folmiTheme) private var theme
    @FocusState private var focused: Bool
    @State private var source: TaskSource = .ideas
    @State private var query = ""
    @State private var filter: TaskFilter = .all
    @State private var byFile = false
    @State private var selectedID: String?
    @State private var notice: String?
    @State private var undo: (root: String, edit: TaskLineEdit)?
    @State private var failure: String?
    @State private var datePicking: String?
    @State private var revision = 0
    @State private var pickedDay: String?
    @State private var showCalendar = true

    var body: some View {
        let _ = PerfLog.body("TasksPage")
        let _ = revision
        let week = TaskWeek(), today = week.today
        let all = items
        let open = all.filter(\.entry.status.isOpen)
        // A day picked on the calendar shows that day's tasks: to do on it, or done on it.
        let shown = all.filter { task in
            guard matches(task) else { return false }
            guard let day = pickedDay else { return filter.includes(task.entry, week: week) }
            let dates = task.entry.dates
            return task.entry.status.isOpen ? dates.due == day || dates.scheduled == day : task.entry.status == .done && dates.done == day
        }
        let showProject = Set(all.map(\.root)).count > 1
        let sections = sections(shown, week: week, showProject: showProject)
        let ordered = sections.flatMap(\.tasks)
        let notes = dayNotes
        VStack(spacing: 0) {
            header(count: open.count, shown: filter == .doneThisWeek || pickedDay != nil ? nil : shown.count, today: today)
            numbers(all, week: week).padding(.horizontal, 12).padding(.bottom, 10)
            if let notice { noticeRow(notice) }
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Group {
                        if ordered.isEmpty && notes.isEmpty { empty(all.isEmpty) }
                        else { list(sections, notes: notes, today: today, showProject: showProject) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The calendar only beside a list wide enough to read; the header button brings it back.
                    if showCalendar, geometry.size.width >= 680 {
                        Divider()
                        ScrollView {
                            TaskCalendar(marks: TaskDayMarks.build(all.map(\.entry), noteDays: source == .ideas ? (model.ideaNotes ?? []).map(\.day) : [], today: today),
                                         today: today,
                                         picked: $pickedDay, onDrop: { id, day in drop(id, on: day, in: all) })
                        }
                        .frame(width: 272)
                    }
                }
            }
        }
        .background(Color.theme(theme, \.card))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in key(press, ordered: ordered) }
        .onAppear { focused = true; model.loadIdeaTasks() }
        // Notes change outside this page: the 随手记 panel, another app, the files of other projects.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.loadIdeaTasks() }
        .onChange(of: model.markdownIndex?.revision) { _, _ in if source == .ideas { model.loadIdeaTasks() } }
        .alert("待办没有改成", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("好") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    /// The notes written on the day picked on the calendar, oldest first, as they were written.
    private var dayNotes: [IdeaNote] {
        guard source == .ideas, let pickedDay else { return [] }
        let needle = query.trimmingCharacters(in: .whitespaces)
        return (model.ideaNotes ?? []).filter { note in
            note.day == pickedDay && (needle.isEmpty || [note.title, note.project].contains { $0.localizedCaseInsensitiveContains(needle) })
        }.sorted { ($0.time, $0.root, $0.path) < ($1.time, $1.root, $1.path) }
    }

    private var loading: Bool { source == .ideas ? model.ideaTasks == nil : model.markdownIndex == nil }

    private var items: [ProjectTask] {
        switch source {
        case .ideas: return model.currentIdeaTasks ?? []
        case .project:
            guard let root = model.repositoryURL?.path else { return [] }
            return (model.currentMarkdownTasks + model.currentMarkdownDoneTasks).map { ProjectTask(root: root, project: model.repositoryTitle, entry: $0) }
        }
    }

    // MARK: Parts

    private func header(count: Int, shown: Int?, today: String) -> some View {
        HStack(spacing: 8) {
            // Project documents stay reachable without competing with the notes: a menu, not a second tab.
            Menu {
                Button("随手记（所有项目）") { switchSource(.ideas) }
                Button("这个项目里的 Markdown（\(model.currentMarkdownTasks.count) 条）") { switchSource(.project) }
            } label: {
                Text(source == .ideas ? "随手记里的待办" : "\(model.repositoryTitle) 的 Markdown 待办").themedFont(.caption.weight(.medium), points: 10)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("默认只看随手记（各项目 ideas/ 里的笔记）；也可以看这个项目所有 Markdown 里的待办，比如 AI 写的计划")
            Text(loading ? "正在读取…" : "\(count) 项没做完").themedFont(.caption, points: 10).foregroundStyle(.secondary)
            if let shown, shown != count { Text("显示 \(shown) 项").themedFont(.caption, points: 10).foregroundStyle(.tertiary) }
            if let pickedDay {
                Button { self.pickedDay = nil } label: {
                    Label("只看 \(Self.short(pickedDay, today: today))", systemImage: "xmark.circle.fill").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.pressable).themedFont(.caption, points: 11).foregroundStyle(.themed(.accent))
                .help("取消，回到全部")
            }
            Spacer()
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(source == .ideas ? "筛选待办或项目" : "筛选待办或文件", text: $query).textFieldStyle(.plain).frame(maxWidth: 220)
                .accessibilityIdentifier("tasks-filter")
            Picker("分组", selection: $byFile) {
                Text("按日期").tag(false)
                Text(source == .ideas ? "按笔记" : "按文件").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            PaneIconButton(symbol: showCalendar ? "calendar.badge.minus" : "calendar", help: showCalendar ? "收起日历" : "显示日历（窗口够宽时在右边）") {
                showCalendar.toggle()
            }
        }
        .themedFont(.system(size: 12), points: 12)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func numbers(_ tasks: [ProjectTask], week: TaskWeek) -> some View {
        let open = tasks.filter(\.entry.status.isOpen)
        let buckets = open.map { TaskBucket.of($0.entry.dates, today: week.today, weekEnd: week.end) }
        let overdue = buckets.filter { $0 == .overdue }.count, dueToday = buckets.filter { $0 == .today }.count
        let places = source == .ideas ? "\(Set(open.map(\.root)).count) 个项目" : "\(Set(open.map(\.entry.path)).count) 个文件"
        let doing = open.filter { $0.entry.status == .inProgress }.count
        let doneToday = tasks.filter { $0.entry.status == .done && $0.entry.dates.done == week.today }.count
        let feet: [TaskFilter: String] = [
            .all: places + (doing > 0 ? " · 进行中 \(doing)" : ""),
            .dueNow: "过期 \(overdue) · 今天 \(dueToday)",
            .thisWeek: "到 \(Self.short(week.end, today: week.today)) 为止",
            .doneThisWeek: doneToday > 0 ? "今天 \(doneToday) · 按 ✅ 日期算" : "按 ✅ 日期算",
        ]
        return HStack(spacing: 8) {
            ForEach(TaskFilter.allCases) { item in
                let count = tasks.filter { item.includes($0.entry, week: week) }.count
                let selected = filter == item && item != .all && pickedDay == nil
                Button { filter = selected ? .all : item; pickedDay = nil; focused = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.rawValue).themedFont(.caption, points: 11).foregroundStyle(.secondary)
                        Text("\(count)").themedFont(.system(size: 22, weight: .semibold).monospacedDigit(), points: 20)
                            .foregroundStyle(item == .dueNow && overdue > 0 ? AnyShapeStyle(.themed(.removed))
                                             : item == .doneThisWeek && count > 0 ? AnyShapeStyle(.themed(.added)) : AnyShapeStyle(.primary))
                        Text(feet[item] ?? "").themedFont(.caption2, points: 10).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .themedBackground(selected ? AnyShapeStyle(.themed(.accent, opacity: 0.14)) : AnyShapeStyle(.primary.opacity(0.045)), .control)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help(item == .all ? "显示全部没做完的待办" : selected ? "取消筛选"
                      : item == .doneThisWeek ? "看这周做完的：带 ✅ 日期的待办（在这里勾选会自动写上）" : "只看\(item.rawValue)")
                .accessibilityLabel("\(item.rawValue) \(count)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "checkmark.circle").foregroundStyle(.secondary).lineLimit(1)
            if undo != nil { Button("撤销", action: undoLast).buttonStyle(.link).disabled(model.busy) }
            Spacer()
        }
        .themedFont(.caption, points: 11).padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func empty(_ none: Bool) -> some View {
        Group {
            if loading {
                panePlaceholder(symbol: "checklist", title: "正在读取…", detail: "")
            } else if none, source == .ideas {
                panePlaceholder(symbol: "checklist.checked", title: "随手记里没有没做完的待办",
                                detail: "在任何 App 里按 \(model.ideaHotKey.title) 记一条，写 - [ ] 就是待办；输入 / 选「截止日期」可以加日期。")
            } else if none {
                panePlaceholder(symbol: "checklist.checked", title: "这个项目的 Markdown 里没有没做完的待办", detail: "")
            } else if filter == .doneThisWeek {
                panePlaceholder(symbol: "checkmark.circle", title: "这周还没有做完的",
                                detail: "按 ✅ 日期算：在这里勾选会自动写上；在别处勾的，写了 ✅ 日期才算。")
            } else {
                panePlaceholder(symbol: "line.3.horizontal.decrease", title: "没有符合筛选的待办", detail: "换个筛选，或点上面的数字取消。")
            }
        }
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        var detail: String?
        var warning = false
        let tasks: [ProjectTask]
    }

    /// Where a task is, for its row or its 按笔记 group: 「Folmi · 10月25日的随手记」.
    private func place(_ task: ProjectTask, showProject: Bool) -> String {
        let file = source == .ideas ? IdeaTasks.noteTitle(task.entry.path) : task.entry.path
        return showProject ? "\(task.project) · \(file)" : file
    }

    private func sections(_ tasks: [ProjectTask], week: TaskWeek, showProject: Bool) -> [Section] {
        if filter == .doneThisWeek, !byFile {
            // Newest day first; the day's tasks in note order.
            return Dictionary(grouping: tasks) { $0.entry.dates.done ?? "" }.sorted { $0.key > $1.key }.map { day, items in
                Section(id: day, title: Self.short(day, today: week.today), detail: "\(items.count)",
                        tasks: items.sorted { ($0.root, $0.entry.path, $0.entry.line) < ($1.root, $1.entry.path, $1.entry.line) })
            }
        }
        if byFile {
            return Dictionary(grouping: tasks) { $0.root + "\0" + $0.entry.path }.sorted { $0.key < $1.key }.compactMap { key, items in
                guard let first = items.first else { return nil }
                return Section(id: key, title: place(first, showProject: showProject), detail: "\(items.count)", tasks: items)
            }
        }
        let grouped = Dictionary(grouping: tasks.filter(\.entry.status.isOpen)) { TaskBucket.of($0.entry.dates, today: week.today, weekEnd: week.end) }
        let done = tasks.filter { !$0.entry.status.isOpen }
        return TaskBucket.allCases.compactMap { bucket -> Section? in
            guard let items = grouped[bucket] else { return nil }
            // Dated groups by day; within a day, and in 没日期, newest note first, then line order.
            let sorted = items.sorted { a, b in
                let (x, y) = (a.entry.dates.day ?? "", b.entry.dates.day ?? "")
                if x != y { return x < y }
                if a.root != b.root || a.entry.path != b.entry.path { return (a.entry.path, a.root) > (b.entry.path, b.root) }
                return a.entry.line < b.entry.line
            }
            return Section(id: bucket.rawValue, title: bucket.rawValue, detail: "\(items.count)", warning: bucket == .overdue, tasks: sorted)
        } + (done.isEmpty ? [] : [Section(id: "done", title: "做完的", detail: "\(done.count)", tasks: done)])
    }

    private func list(_ sections: [Section], notes: [IdeaNote], today: String, showProject: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !notes.isEmpty {
                        SwiftUI.Section {
                            ForEach(notes) { note in noteRow(note, showProject: showProject) }
                        } header: { sectionHeader("随手记", detail: "\(notes.count)", warning: false, mono: false) }
                    }
                    ForEach(sections) { section in
                        SwiftUI.Section {
                            ForEach(section.tasks) { task in
                                row(task, today: today, place: byFile ? nil : place(task, showProject: showProject)).id(task.id)
                            }
                        } header: { sectionHeader(section.title, detail: section.detail, warning: section.warning, mono: byFile) }
                    }
                }
                .padding(.bottom, 10)
            }
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
                model.selectedTask = sections.lazy.flatMap(\.tasks).first { $0.id == id }
            }
        }
    }

    private func sectionHeader(_ title: String, detail: String?, warning: Bool, mono: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).themedFont(mono ? .caption : .caption.weight(.semibold), points: 10)
                .foregroundStyle(warning ? AnyShapeStyle(.themed(.removed)) : AnyShapeStyle(.secondary))
            if let detail { Text(detail).themedFont(.caption2, points: 10).foregroundStyle(.tertiary) }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        .background(Color.theme(theme, \.card))
    }

    /// A note written on the picked day; a click opens it in the reading view.
    private func noteRow(_ note: IdeaNote, showProject: Bool) -> some View {
        Button { model.openNote(note) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "note.text").foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title).lineLimit(2)
                    Text(showProject ? "\(note.time) · \(note.project)" : note.time)
                        .themedFont(.caption2.monospacedDigit(), points: 10).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressableRow)
        .padding(.horizontal, 4)
        .contextMenu {
            Button("打开") { model.openNote(note) }
            Button("交给 \(model.agentTitle)") { model.handNoteToAgent(note) }
        }
        .help("打开这条随手记（阅读视图）" + (note.root == model.repositoryURL?.path ? "" : "，会切换到 \(note.project)"))
    }

    private func row(_ task: ProjectTask, today: String, place: String?) -> some View {
        let selected = task.id == selectedID
        let entry = task.entry
        let done = entry.status == .done
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { toggle(task) } label: {
                Image(systemName: done ? "checkmark.square.fill" : entry.status == .inProgress ? "square.lefthalf.filled" : "square")
                    .foregroundStyle(done ? AnyShapeStyle(.themed(.added)) : entry.status == .inProgress ? AnyShapeStyle(.themed(.accent)) : AnyShapeStyle(.secondary))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.pressable).disabled(model.busy)
            .help(done ? "改回没做完（空格），✅ 日期一起去掉" : entry.status == .inProgress ? "进行中；点一下标为完成（空格）" : "完成（空格）；文件有没保存的改动时，勾选留在草稿里")
            .accessibilityLabel((done ? "改回没做完：" : "完成待办：") + entry.text)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.text).lineLimit(2).strikethrough(done).foregroundStyle(done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let place {
                    Text(place).themedFont(.caption2, points: 10).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if done, let day = entry.dates.done {
                Text("✅ " + Self.short(day, today: today)).themedFont(.caption.monospacedDigit(), points: 11).foregroundStyle(.secondary)
            } else {
                dateButton(task, today: today)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .themedBackground(selected ? AnyShapeStyle(.primary.opacity(0.07)) : AnyShapeStyle(.clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .draggable(task.id) {
            Text(entry.text).lineLimit(1).padding(.horizontal, 8).padding(.vertical, 4)
                .themedBackground(.themed(.accent, opacity: 0.18), .control)
        }
        .onTapGesture(count: 2) { model.openTask(task) }
        .onTapGesture { selectedID = task.id; focused = true }
        .contextMenu {
            Button("打开到这一行") { model.openTask(task) }
            Button("交给 \(model.agentTitle)") { model.handTaskToAgent(task) }
        }
        .help("双击或按 ⏎ 打开到这一行" + (task.root == model.repositoryURL?.path ? "" : "（会切换到 \(task.project)）"))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dateButton(_ task: ProjectTask, today: String) -> some View {
        let dates = task.entry.dates
        let day = dates.day
        let overdue = dates.due.map { $0 < today } ?? false
        let label = day.map { (dates.due == nil ? "⏳ " : "📅 ") + Self.short($0, today: today) } ?? "设日期"
        return Button { datePicking = task.id } label: {
            Text(label).themedFont(.caption.monospacedDigit(), points: 11)
                .foregroundStyle(overdue ? AnyShapeStyle(.themed(.removed)) : day == today ? AnyShapeStyle(.themed(.accent)) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .themedBackground(day == nil ? AnyShapeStyle(.clear) : AnyShapeStyle(.primary.opacity(0.06)), .control)
                .opacity(day == nil && task.id != selectedID ? 0.5 : 1)
        }
        .buttonStyle(.pressable).disabled(model.busy)
        .help("设截止日期或哪天做（D）；写进这一行，比如 📅 2026-10-30")
        .popover(isPresented: Binding(get: { datePicking == task.id }, set: { if !$0 { datePicking = nil } }), arrowEdge: .trailing) {
            TaskDatePopover(task: task.entry) { kind, value in
                datePicking = nil
                setDate(task, kind, value)
            }
        }
    }

    /// 今天, 明天, 10/30 (with the year when it is another year).
    static func short(_ key: String, today: String) -> String {
        if key == today { return "今天" }
        if let date = TaskDates.date(key), let now = TaskDates.date(today),
           Calendar.current.dateComponents([.day], from: now, to: date).day == 1 { return "明天" }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        return (key.prefix(4) == today.prefix(4) ? "" : "\(parts[0])/") + "\(parts[1])/\(parts[2])"
    }

    // MARK: Actions

    private func switchSource(_ next: TaskSource) {
        guard next != source else { return }
        source = next; filter = .all; pickedDay = nil; selectedID = nil; notice = nil; undo = nil
        if next == .ideas { model.loadIdeaTasks() } else { model.scheduleMarkdownIndex() }
        focused = true
    }

    private func matches(_ task: ProjectTask) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return [task.entry.text, task.entry.path, task.project].contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func key(_ press: KeyPress, ordered: [ProjectTask]) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        let index = ordered.firstIndex { $0.id == selectedID }
        let current = index.map { ordered[$0] }
        switch press.key {
        case .downArrow, .upArrow:
            guard !ordered.isEmpty else { return .ignored }
            let step = press.key == .downArrow ? 1 : -1
            selectedID = ordered[max(0, min(ordered.count - 1, (index ?? (step > 0 ? -1 : ordered.count)) + step))].id
            return .handled
        case .space:
            guard let current, let index else { return .ignored }
            // The next row takes the selection, so space can go on down the list.
            let next = ordered.indices.contains(index + 1) ? ordered[index + 1] : index > 0 ? ordered[index - 1] : nil
            toggle(current)
            selectedID = next?.id
            return .handled
        case .return:
            guard let current else { return .ignored }
            model.openTask(current); return .handled
        default: break
        }
        if press.characters.lowercased() == "d", let current { datePicking = current.id; return .handled }
        return .ignored
    }

    /// A row dropped on a calendar day: that day becomes its deadline.
    private func drop(_ id: String, on day: String, in tasks: [ProjectTask]) -> Bool {
        guard let task = tasks.first(where: { $0.id == id }), task.entry.status.isOpen, task.entry.dates.due != day else { return false }
        setDate(task, .due, day)
        return true
    }

    private func toggle(_ task: ProjectTask) {
        guard task.entry.status == .done else { complete(task); return }
        apply(task) { workspace in
            _ = try workspace.reopenIndexedTask(task.entry)
            return "「\(task.entry.text)」改回没做完"
        }
    }

    private func complete(_ task: ProjectTask) {
        apply(task) { workspace in
            // Notes may be kept out of Git (只留在本机), so the day it was done is written on the line itself.
            let saved = try workspace.completeIndexedTask(task.entry, datesDone: IdeaTasks.isNote(task.entry.path))
            return saved ? "完成了「\(task.entry.text)」" : "勾上了「\(task.entry.text)」，留在 \(task.entry.path) 没保存的草稿里"
        }
    }

    private func setDate(_ task: ProjectTask, _ kind: TaskDates.Kind, _ value: String?) {
        apply(task) { workspace in
            _ = try workspace.setIndexedTaskDate(task.entry, kind, to: value)
            let what = kind == .due ? "截止日期" : "哪天做"
            return value.map { "「\(task.entry.text)」\(what)改成 \($0)" } ?? "去掉了「\(task.entry.text)」的\(what)"
        }
    }

    /// The open project's editor, so its drafts and tabs stay in step; a passing one for another project's notes.
    private func workspace(for root: String) -> EditorWorkspace? {
        if root == model.repositoryURL?.path { return model.editorWorkspace }
        return EditorWorkspace(root: URL(fileURLWithPath: root))
    }

    private func apply(_ task: ProjectTask, _ change: (EditorWorkspace) throws -> String) {
        guard let workspace = workspace(for: task.root), !model.busy else { return }
        workspace.lastTaskLineEdit = nil
        do {
            notice = try change(workspace)
            undo = workspace.lastTaskLineEdit.map { (task.root, $0) }
        } catch {
            failure = error.localizedDescription
            undo = nil
        }
        refresh()
    }

    private func undoLast() {
        guard let undo, let workspace = workspace(for: undo.root) else { return }
        do {
            _ = try workspace.restoreTaskLine(path: undo.edit.path, line: undo.edit.line, from: undo.edit.after, to: undo.edit.before)
            notice = "撤销了上一步"
        } catch { failure = error.localizedDescription }
        self.undo = nil
        refresh()
    }

    private func refresh() {
        revision &+= 1
        model.scheduleMarkdownIndex()
        model.loadIdeaTasks()
        model.scheduleSave()
        focused = true
    }
}

/// Picks a due or planned day for one task: a calendar plus the usual quick days.
private struct TaskDatePopover: View {
    let task: MarkdownIndex.Entry
    let onPick: (TaskDates.Kind, String?) -> Void
    @State private var kind: TaskDates.Kind = .due
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                Text("📅 截止").tag(TaskDates.Kind.due)
                Text("⏳ 哪天做").tag(TaskDates.Kind.scheduled)
            }
            .pickerStyle(.segmented).labelsHidden()
            DatePicker("", selection: $date, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
            HStack {
                ForEach(Array(quickDays.enumerated()), id: \.offset) { _, item in
                    Button(item.0) { onPick(kind, TaskDates.key(item.1)) }
                }
            }
            .controlSize(.small)
            HStack {
                if task.dates[kind] != nil { Button("去掉", role: .destructive) { onPick(kind, nil) } }
                Spacer()
                Button("设为 \(TaskDates.key(date))") { onPick(kind, TaskDates.key(date)) }.keyboardShortcut(.defaultAction)
            }
            Text("写进这一行，比如 \(kind.marker) \(TaskDates.key(date))；Obsidian 里也认。")
                .themedFont(.caption2, points: 10).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: 260)
        .onAppear {
            if task.dates.due == nil, task.dates.scheduled != nil { kind = .scheduled }
            date = task.dates[kind].flatMap { TaskDates.date($0) } ?? Date()
        }
        .onChange(of: kind) { _, kind in date = task.dates[kind].flatMap { TaskDates.date($0) } ?? date }
    }

    private var quickDays: [(String, Date)] {
        let calendar = Calendar.current, now = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let nextWeek = calendar.nextDate(after: now, matching: DateComponents(weekday: calendar.firstWeekday), matchingPolicy: .nextTime) ?? now
        return [("今天", now), ("明天", tomorrow), ("下周", nextWeek)]
    }
}

/// What one day of the month calendar marks: open tasks due or planned that day, tasks done that day, and notes
/// written that day.
struct TaskDayMarks: Equatable {
    var open = 0
    var overdue = false
    var done = 0
    var notes = 0

    static func build(_ tasks: [MarkdownIndex.Entry], noteDays: [String] = [], today: String) -> [String: TaskDayMarks] {
        var marks: [String: TaskDayMarks] = [:]
        for day in noteDays { marks[day, default: TaskDayMarks()].notes += 1 }
        for task in tasks {
            if task.status.isOpen, let day = task.dates.day {
                marks[day, default: TaskDayMarks()].open += 1
                if let due = task.dates.due, due < today { marks[due, default: TaskDayMarks()].overdue = true }
            } else if task.status == .done, let day = task.dates.done {
                marks[day, default: TaskDayMarks()].done += 1
            }
        }
        return marks
    }
}

/// A month beside the task list: dots for what is due and what got done, a click to see one day, and a drop target
/// that moves a task's deadline to the day it lands on.
struct TaskCalendar: View {
    let marks: [String: TaskDayMarks]
    let today: String
    @Binding var picked: String?
    let onDrop: (String, String) -> Bool
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var target: String?

    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    var body: some View {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month], from: month)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(verbatim: "\(parts.year ?? 0)年\(parts.month ?? 0)月").themedFont(.caption.weight(.semibold), points: 11)
                Spacer()
                PaneIconButton(symbol: "chevron.left", help: "上个月") { shift(-1) }
                Button("今天") { month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? month }
                    .buttonStyle(.pressable).themedFont(.caption, points: 11)
                PaneIconButton(symbol: "chevron.right", help: "下个月") { shift(1) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<7, id: \.self) { index in
                    Text(Self.weekdays[(index + calendar.firstWeekday - 1) % 7]).themedFont(.caption2, points: 10).foregroundStyle(.tertiary)
                }
                ForEach(days(calendar), id: \.self) { day in cell(day, calendar: calendar) }
            }
            Text("下划线是那天记过随手记，点一天看那天的随手记和待办；把左边的待办拖到某天，改它的截止日期。")
                .themedFont(.caption2, points: 10).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    /// Whole weeks covering the month, as `yyyy-MM-dd`.
    private func days(_ calendar: Calendar) -> [String] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let count = Int((Double(lead + range.count) / 7).rounded(.up)) * 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0 - lead, to: month).map { TaskDates.key($0, calendar: calendar) } }
    }

    private func cell(_ day: String, calendar: Calendar) -> some View {
        let mark = marks[day] ?? TaskDayMarks()
        let inMonth = day.prefix(7) == TaskDates.key(month, calendar: calendar).prefix(7)
        let selected = day == picked
        return VStack(spacing: 2) {
            Text(String(Int(day.suffix(2)) ?? 0)).themedFont(.caption.monospacedDigit().weight(day == today ? .bold : .regular), points: 11)
                .foregroundStyle(day == today ? AnyShapeStyle(.themed(.accent)) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            Capsule().fill(mark.notes > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear)).frame(width: 12, height: 2)
            HStack(spacing: 2) {
                ForEach(0..<min(mark.open, 3), id: \.self) { _ in
                    Circle().fill(mark.overdue ? AnyShapeStyle(.themed(.removed)) : AnyShapeStyle(.themed(.accent))).frame(width: 4, height: 4)
                }
                ForEach(0..<min(mark.done, 3), id: \.self) { _ in
                    Circle().fill(.themed(.added)).frame(width: 4, height: 4)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .themedBackground(target == day ? AnyShapeStyle(.themed(.accent, opacity: 0.25))
                          : selected ? AnyShapeStyle(.themed(.accent, opacity: 0.14)) : AnyShapeStyle(.clear), .control)
        .overlay {
            if day == today { RoundedRectangle(cornerRadius: 6).strokeBorder(.themed(.accent, opacity: 0.6), lineWidth: 1) }
        }
        .contentShape(Rectangle())
        .onTapGesture { picked = selected ? nil : day }
        .dropDestination(for: String.self) { ids, _ in ids.first.map { onDrop($0, day) } ?? false } isTargeted: { inside in
            if inside { target = day } else if target == day { target = nil }
        }
        .help(help(day, mark))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help(day, mark))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func help(_ day: String, _ mark: TaskDayMarks) -> String {
        let parts = [mark.notes > 0 ? "记了 \(mark.notes) 条随手记" : nil,
                     mark.open > 0 ? "\(mark.open) 条要做" + (mark.overdue ? "（有过期的）" : "") : nil,
                     mark.done > 0 ? "做完 \(mark.done) 条" : nil].compactMap { $0 }
        return TasksPage.short(day, today: today) + (parts.isEmpty ? "" : "：" + parts.joined(separator: "，"))
    }

    private func shift(_ months: Int) { month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month }
}
