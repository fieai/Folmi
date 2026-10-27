import Foundation
import XCTest
@testable import Folmi

final class TaskDatesTests: XCTestCase {
    func testParsesStatusesAndTakesDatesOutOfTheTitle() {
        let text = """
        - [ ] 写说明 📅 2026-10-30
        - [/] 改设置页 ⏳ 2026-10-27 📅 2026-11-02
        - [x] 发版 ✅ 2026-10-25
        - [-] 不做的
        - [?] 不认的标记
        """
        let tasks = MarkdownIndex.parse(text, path: "a.md")
        XCTAssertEqual(tasks.map(\.text), ["写说明", "改设置页", "发版", "不做的"])
        XCTAssertEqual(tasks.map(\.status), [.open, .inProgress, .done, .cancelled])
        XCTAssertEqual(tasks.map(\.kind), [.task(done: false), .task(done: false), .task(done: true), .task(done: true)])
        XCTAssertEqual(tasks[0].dates, TaskDates(due: "2026-10-30"))
        XCTAssertEqual(tasks[1].dates, TaskDates(due: "2026-11-02", scheduled: "2026-10-27"))
        XCTAssertEqual(tasks[1].dates.day, "2026-11-02")
        XCTAssertEqual(tasks[2].dates.done, "2026-10-25")
        XCTAssertEqual(MarkdownIndex.parse("- [ ] 只有日期 📅 2026-10-30", path: "a.md").first?.text, "只有日期")
        XCTAssertEqual(MarkdownIndex.parse("- [ ] 📅 2026-10-30", path: "a.md").first?.text, "（空任务）")
    }

    func testOpenTasksIncludeInProgressOnly() {
        let index = MarkdownIndex.parse("- [ ] a\n- [/] b\n- [x] c\n- [-] d\n", path: "a.md")
        XCTAssertEqual(index.filter { $0.status.isOpen }.map(\.text), ["a", "b"])
    }

    func testSettingADateReplacesAddsOrRemovesIt() {
        XCTAssertEqual(TaskDates.setting(.due, to: "2026-11-01", in: "- [ ] a 📅 2026-10-30 #tag"), "- [ ] a 📅 2026-11-01 #tag")
        XCTAssertEqual(TaskDates.setting(.due, to: "2026-11-01", in: "- [ ] a  "), "- [ ] a 📅 2026-11-01")
        XCTAssertEqual(TaskDates.setting(.due, to: nil, in: "- [ ] a 📅 2026-10-30 #tag"), "- [ ] a #tag")
        XCTAssertEqual(TaskDates.setting(.scheduled, to: nil, in: "- [ ] a 📅 2026-10-30"), "- [ ] a 📅 2026-10-30")
        XCTAssertEqual(TaskDates.setting(.scheduled, to: "2026-10-28", in: "- [ ] a 📅 2026-10-30"), "- [ ] a 📅 2026-10-30 ⏳ 2026-10-28")
    }

    func testBucketsByDeadlineThenPlannedDay() {
        let today = "2026-10-26", weekEnd = "2026-11-01"
        func bucket(_ dates: TaskDates) -> TaskBucket { TaskBucket.of(dates, today: today, weekEnd: weekEnd) }
        XCTAssertEqual(bucket(TaskDates(due: "2026-10-25")), .overdue)
        XCTAssertEqual(bucket(TaskDates(due: "2026-10-26")), .today)
        XCTAssertEqual(bucket(TaskDates(scheduled: "2026-10-20")), .today, "a planned day in the past is still today's, not overdue")
        XCTAssertEqual(bucket(TaskDates(due: "2026-11-01")), .week)
        XCTAssertEqual(bucket(TaskDates(due: "2026-11-02")), .later)
        XCTAssertEqual(bucket(TaskDates()), .undated)
        let week = TaskWeek(today: today, start: "2026-10-26", end: weekEnd)
        XCTAssertTrue(TaskFilter.thisWeek.includes(MarkdownIndex.Entry(path: "a", line: 0, kind: .task(done: false), text: "a", dates: TaskDates(due: today)), week: week))
        let done = MarkdownIndex.Entry(path: "a", line: 0, kind: .task(done: true), text: "a", status: .done, dates: TaskDates(due: today, done: today))
        XCTAssertTrue(TaskFilter.doneThisWeek.includes(done, week: week))
        XCTAssertFalse(TaskFilter.thisWeek.includes(done, week: week), "done tasks only count as done")
        var lastWeek = done; lastWeek.dates.done = "2026-10-25"
        XCTAssertFalse(TaskFilter.doneThisWeek.includes(lastWeek, week: week))
    }

    func testWeekEndFollowsTheCalendarsFirstWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.firstWeekday = 2
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 9))!
        XCTAssertEqual(TaskBucket.weekEnd(monday, calendar: calendar), "2026-11-01")
        calendar.firstWeekday = 1
        XCTAssertEqual(TaskBucket.weekEnd(monday, calendar: calendar), "2026-10-31")
    }

    func testShortDayNames() {
        XCTAssertEqual(TasksPage.short("2026-10-26", today: "2026-10-26"), "今天")
        XCTAssertEqual(TasksPage.short("2026-10-27", today: "2026-10-26"), "明天")
        XCTAssertEqual(TasksPage.short("2026-11-03", today: "2026-10-26"), "11/3")
        XCTAssertEqual(TasksPage.short("2027-01-03", today: "2026-10-26"), "2027/1/3")
    }

    @MainActor
    func testSlashDateInsertsTheMarkerWithTheDateSelected() throws {
        let text = "- [ ] 写说明 /jz"
        let trigger = try XCTUnwrap(MarkdownCommands.slashTrigger(text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        XCTAssertEqual(MarkdownCommands.slashMatches(trigger.query).first?.id, "due")
        let edit = try XCTUnwrap(MarkdownCommands.slashEdit(.date(.due), text: text, trigger: trigger.range, today: "2026-10-26"))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(result, "- [ ] 写说明 📅 2026-10-26")
        XCTAssertEqual((result as NSString).substring(with: edit.selection), "2026-10-26")
        XCTAssertEqual(MarkdownCommands.strippedBlockPrefix("- [/] 进行中").text, "进行中")
    }
}

final class TaskViewsTests: XCTestCase {
    func testCalendarMarksCountOpenByDayAndDoneByDoneDay() {
        let tasks = MarkdownIndex.parse("""
        - [ ] a 📅 2026-10-24
        - [ ] b ⏳ 2026-10-28
        - [/] c 📅 2026-10-28
        - [x] d ✅ 2026-10-26
        - [x] e
        """, path: "n.md")
        let marks = TaskDayMarks.build(tasks, today: "2026-10-26")
        XCTAssertEqual(marks["2026-10-24"], TaskDayMarks(open: 1, overdue: true, done: 0))
        XCTAssertEqual(marks["2026-10-28"], TaskDayMarks(open: 2, overdue: false, done: 0))
        XCTAssertEqual(marks["2026-10-26"], TaskDayMarks(open: 0, overdue: false, done: 1))
        XCTAssertEqual(marks.count, 3)
        let withNotes = TaskDayMarks.build(tasks, noteDays: ["2026-10-26", "2026-10-26", "2026-10-20"], today: "2026-10-26")
        XCTAssertEqual(withNotes["2026-10-26"], TaskDayMarks(open: 0, overdue: false, done: 1, notes: 2))
        XCTAssertEqual(withNotes["2026-10-20"]?.notes, 1)
    }

    func testReaderShowsInProgressDroppedAndDateChips() {
        let html = MarkdownHTML.render("- [/] 进行中 📅 2026-10-30\n- [-] 不做了\n- [ ] 普通\n")
        XCTAssertTrue(html.contains("class=\"task doing\""), html)
        XCTAssertTrue(html.contains("class=\"task dropped\" data-offset") && html.contains(" checked>"), html)
        XCTAssertTrue(html.contains("<span class=\"task-date\">📅 2026-10-30</span>"), html)
        XCTAssertFalse(MarkdownHTML.render("没有待办 📅 2026-10-30\n").contains("task-date"), "only inside task items")
    }

    func testListedTasksKeepDoneOnesWithADay() {
        XCTAssertEqual(IdeaTasks.listedTasks("## 标题\n- [ ] a\n- [x] b ✅ 2026-10-26\n- [x] c\n- [-] d ✅ 2026-10-26\n", path: "ideas/n.md").map(\.text), ["a", "b"])
    }
}

final class TaskLineEditTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-task-lines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ text: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent("tasks.md")) }
    private func read() throws -> String { try String(contentsOf: root.appendingPathComponent("tasks.md"), encoding: .utf8) }
    private func task(_ text: String) throws -> MarkdownIndex.Entry {
        try XCTUnwrap(MarkdownIndex.parse(try read(), path: "tasks.md").first { $0.text == text })
    }

    @MainActor
    func testCompletingAddsADoneDateOnlyWhereTheFileAlreadyWritesThem() throws {
        try write("- [ ] a 📅 2026-10-30\n- [x] old ✅ 2026-10-01\n")
        let editor = EditorWorkspace(root: root)
        XCTAssertTrue(try editor.completeIndexedTask(try task("a"), today: "2026-10-26"))
        XCTAssertEqual(try read(), "- [x] a 📅 2026-10-30 ✅ 2026-10-26\n- [x] old ✅ 2026-10-01\n")

        try write("- [/] b\n")
        let plain = EditorWorkspace(root: root)
        XCTAssertTrue(try plain.completeIndexedTask(try task("b"), today: "2026-10-26"))
        XCTAssertEqual(try read(), "- [x] b\n")
    }

    @MainActor
    func testSettingADateAndUndoingItRestoresTheLineAndKeepsCRLF() throws {
        try write("# 计划\r\n- [ ] a\r\n")
        let editor = EditorWorkspace(root: root)
        XCTAssertTrue(try editor.setIndexedTaskDate(try task("a"), .due, to: "2026-10-30"))
        XCTAssertEqual(try read(), "# 计划\r\n- [ ] a 📅 2026-10-30\r\n")
        let edit = try XCTUnwrap(editor.lastTaskLineEdit)
        XCTAssertEqual(edit, TaskLineEdit(path: "tasks.md", line: 1, before: "- [ ] a", after: "- [ ] a 📅 2026-10-30"))
        XCTAssertTrue(try editor.restoreTaskLine(path: edit.path, line: edit.line, from: edit.after, to: edit.before))
        XCTAssertEqual(try read(), "# 计划\r\n- [ ] a\r\n")
        XCTAssertThrowsError(try editor.restoreTaskLine(path: edit.path, line: edit.line, from: edit.after, to: edit.before))
    }

    @MainActor
    func testReopeningTakesTheDoneDateOut() throws {
        try write("- [x] a 📅 2026-10-30 ✅ 2026-10-26\n")
        let editor = EditorWorkspace(root: root)
        XCTAssertTrue(try editor.reopenIndexedTask(try task("a")))
        XCTAssertEqual(try read(), "- [ ] a 📅 2026-10-30\n")
    }

    @MainActor
    func testReaderClickCompletesAnInProgressTask() throws {
        try write("- [/] a\n- [-] b\n")
        let editor = EditorWorkspace(root: root)
        try editor.open(path: "tasks.md")
        let offsets = MarkdownHTML.render(try read()).components(separatedBy: "data-offset=\"").dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
        try editor.toggleTask(at: offsets[0], in: "tasks.md")
        try editor.toggleTask(at: offsets[1], in: "tasks.md")
        XCTAssertEqual(try read(), "- [x] a\n- [ ] b\n")
    }

    @MainActor
    func testAStaleTaskIsNeverRewritten() throws {
        try write("- [ ] a\n")
        let stale = try task("a")
        try write("- [x] a\n")
        let editor = EditorWorkspace(root: root)
        XCTAssertThrowsError(try editor.setIndexedTaskDate(stale, .due, to: "2026-10-30"))
        XCTAssertEqual(try read(), "- [x] a\n")
    }
}

final class IdeaTasksTests: XCTestCase {
    private var base: URL!
    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-idea-tasks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: base) }
    private func write(_ text: String, _ path: String) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testReadsOpenTasksFromEveryProjectsNotesOnly() throws {
        try write("- [ ] 买咖啡豆 📅 2026-10-27\n- [x] 做完的\n- [/] 进行中的\n", "a/ideas/20261025-180300.md")
        try write("- [ ] 计划里的步骤\n", "a/docs/plan.md")
        try write("\u{FEFF}- [ ] 另一个项目的\n", "b/ideas/sub/note.md")
        try write("- [ ] worktree 里的\n", "c/ideas/x.md")
        try write("gitdir: /elsewhere\n", "c/.git")
        let tasks = IdeaTasks.read(projects: ["a", "b", "c", "missing"].map { (root: base.appendingPathComponent($0).path, name: $0) })
        XCTAssertEqual(tasks.map(\.entry.text), ["买咖啡豆", "进行中的", "另一个项目的"])
        XCTAssertEqual(tasks.map(\.project), ["a", "a", "b"])
        XCTAssertEqual(tasks.last?.entry.path, "ideas/sub/note.md")
        XCTAssertEqual(tasks.first?.entry.dates.due, "2026-10-27")
    }

    func testNotesCarryTheirDayTimeAndFirstLine() throws {
        try write("\n## 周会要说的\n- [ ] 发版 📅 2026-10-30\n", "a/ideas/20261025-180300.md")
        try write("- [ ] 只有一条待办 📅 2026-10-30\n", "a/ideas/20261026-090501-2.md")
        try write("", "a/ideas/20261026-100000.md")
        let notes = IdeaTasks.readAll(projects: [(root: base.appendingPathComponent("a").path, name: "a")]).notes
        XCTAssertEqual(notes.map(\.day), ["2026-10-25", "2026-10-26", "2026-10-26"])
        XCTAssertEqual(notes.map(\.time), ["18:03", "09:05", "10:00"])
        XCTAssertEqual(notes.map(\.title), ["周会要说的", "只有一条待办", "（空白）"])
    }

    func testNotesNotNamedByDateUseTheirCreationDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let created = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 7, minute: 5))!
        XCTAssertEqual(IdeaTasks.written("ideas/购物.md", created: created, calendar: calendar)?.day, "2026-10-20")
        XCTAssertEqual(IdeaTasks.written("ideas/购物.md", created: created, calendar: calendar)?.time, "07:05")
        XCTAssertNil(IdeaTasks.written("ideas/购物.md", created: nil))
        XCTAssertEqual(IdeaTasks.written("ideas/2026x025-180300.md", created: nil)?.day, nil)
    }

    func testNoteTitles() {
        XCTAssertEqual(IdeaTasks.noteTitle("ideas/20261025-180300.md"), "10月25日的随手记")
        XCTAssertEqual(IdeaTasks.noteTitle("ideas/20261025-180300-2.md"), "10月25日的随手记")
        XCTAssertEqual(IdeaTasks.noteTitle("ideas/购物.md"), "购物.md")
        XCTAssertEqual(IdeaTasks.noteTitle("docs/20261025.md"), "20261025.md")
    }

    @MainActor
    func testCompletingANoteTaskAlwaysWritesTheDay() throws {
        try write("- [ ] 买咖啡豆\n", "ideas/n.md")
        let editor = EditorWorkspace(root: base)
        let task = try XCTUnwrap(IdeaTasks.openTasks("- [ ] 买咖啡豆\n", path: "ideas/n.md").first)
        XCTAssertTrue(try editor.completeIndexedTask(task, today: "2026-10-26", datesDone: true))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("ideas/n.md"), encoding: .utf8), "- [x] 买咖啡豆 ✅ 2026-10-26\n")
    }
}
