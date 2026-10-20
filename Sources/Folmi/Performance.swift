import Foundation
import Darwin
import os

/// Signposts for Instruments (Points of Interest / os_signpost). They cost almost nothing when nobody records, and
/// show where a frame went: Markdown parse vs. apply, syntax highlight, Git status, a card drag.
/// Record with: xcrun xctrace record --template 'Time Profiler' --attach Folmi
enum Perf {
    static let signposter = OSSignposter(subsystem: "local.folmi", category: .pointsOfInterest)

    @discardableResult
    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try work()
    }
}

/// Wall-clock timings for `--perf-log <file>` runs (scripts/perf.sh): launch milestones in ms since the process
/// started, and switch intervals in ms. One tab-separated line per event. Does nothing without the flag.
@MainActor
enum PerfLog {
    private static let handle: FileHandle? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--perf-log"), arguments.indices.contains(index + 1) else { return nil }
        let path = arguments[index + 1]
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static var enabled: Bool { handle != nil }
    /// Whether the run drives itself through switches and quits (scripts/perf.sh).
    static let scripted = CommandLine.arguments.contains("--perf-run")
    private static var seen: Set<String> = []

    /// Kernel start time of this process, so a milestone includes dyld and Swift runtime start-up.
    static var launched: Date { processStart }
    private static let processStart: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    /// Set when `--perf-run` starts clicking: a launch milestone first reached after that (a reader the script opened
    /// 10 s in) measures the script's pace, not launch, so it is not logged.
    static var launchOver = false

    /// A launch milestone; only its first occurrence is logged.
    static func mark(_ name: String) {
        guard enabled, !(launchOver && name.hasPrefix("launch.")), seen.insert(name).inserted else { return }
        write(name, Date().timeIntervalSince(processStart) * 1000)
    }
    /// The same milestone once the frame that shows it has been committed.
    static func markAfterFrame(_ name: String) {
        guard enabled else { return }
        afterFrame { mark(name) }
    }
    static func interval(_ name: String, since start: ContinuousClock.Instant, detail: String = "") {
        guard enabled else { return }
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        write(name, ms, detail: detail)
        if ["reader.swift", "switch.diffFrame", "switch.refreshFrame"].contains(name) { flushBodies(name) }
    }
    /// Roughly "on screen": two main-loop turns later, after SwiftUI has applied the change and Core Animation has
    /// committed the transaction that holds it.
    static func afterFrame(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
    }
    private static var bodies: [String: Int] = [:]
    /// Counts a view body (or representable update) evaluation; each switch line is followed by a `bodies` line with
    /// the views that re-rendered for it, so a change that re-renders too much of the window shows up.
    static func body(_ name: StaticString) {
        guard enabled else { return }
        bodies["\(name)", default: 0] += 1
    }
    private static var spent: [String: Double] = [:]
    /// Main-thread time spent in one named piece of an update (a representable's update, say), summed per switch.
    static func spend(_ name: StaticString, since start: ContinuousClock.Instant) {
        guard enabled else { return }
        let elapsed = ContinuousClock.now - start
        spent["\(name)", default: 0] += Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
    static func resetBodies() { bodies = [:]; spent = [:] }
    private static func flushBodies(_ name: String) {
        let list = bodies.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "\($0.key)×\($0.value)" }
        write("bodies", Double(bodies.values.reduce(0, +)), detail: "\(name) " + list.joined(separator: " "))
        if !spent.isEmpty {
            let times = spent.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.1f", $0.value))ms" }
            write("spent", spent.values.reduce(0, +), detail: "\(name) " + times.joined(separator: " "))
        }
        bodies = [:]; spent = [:]
    }
    private static var readerSwitch: (path: String, label: String, start: ContinuousClock.Instant)?
    /// A Markdown open the perf script is about to make; `readerPainted` closes it.
    static func beginReaderSwitch(_ path: String, label: String) {
        guard enabled else { return }
        readerSwitch = (path, label, .now); resetBodies()
    }
    /// A step of the pending Markdown open, in ms since it began (for example when the reader's update ran).
    static func readerStep(_ name: String) {
        guard enabled, let pending = readerSwitch else { return }
        interval(name, since: pending.start, detail: pending.label)
    }
    static func readerPainted(_ path: String, bytes: Int, renderStart: ContinuousClock.Instant) {
        guard enabled else { return }
        mark("launch.readerPainted")
        interval("reader.render", since: renderStart, detail: "\(path) \(bytes)B")
        if let pending = readerSwitch, pending.path == path {
            readerSwitch = nil
            interval("switch.reader", since: pending.start, detail: "\(pending.label) \(path) \(bytes)B")
        }
    }
    static func note(_ name: String, _ detail: String) {
        guard enabled else { return }
        write(name, 0, detail: detail.replacingOccurrences(of: "\n", with: " "))
    }
    private static func write(_ name: String, _ ms: Double, detail: String = "") {
        handle?.write(Data("\(name)\t\(String(format: "%.1f", ms))\t\(detail)\n".utf8))
    }
}
