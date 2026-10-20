import SwiftUI

// MARK: - The Folmi mark as vector parts

/// A minimal SVG path reader for the mascot rig: absolute M, L, H, V, C, Q and Z, which is all the rig uses.
enum SVGPathData {
    static func path(_ data: String) -> Path {
        var path = Path()
        var numbers: [CGFloat] = []
        var command: Character?
        var current = CGPoint.zero
        var start = CGPoint.zero

        func flush() {
            guard let command else { return }
            var i = 0
            func take(_ n: Int) -> [CGFloat]? {
                guard i + n <= numbers.count else { return nil }
                defer { i += n }
                return Array(numbers[i..<i + n])
            }
            repeat {
                switch command {
                case "M":
                    guard let v = take(2) else { return }
                    // Pairs after the first are implicit line-tos.
                    if i == 2 { path.move(to: CGPoint(x: v[0], y: v[1])); start = CGPoint(x: v[0], y: v[1]) }
                    else { path.addLine(to: CGPoint(x: v[0], y: v[1])) }
                    current = CGPoint(x: v[0], y: v[1])
                case "L":
                    guard let v = take(2) else { return }
                    current = CGPoint(x: v[0], y: v[1]); path.addLine(to: current)
                case "H":
                    guard let v = take(1) else { return }
                    current.x = v[0]; path.addLine(to: current)
                case "V":
                    guard let v = take(1) else { return }
                    current.y = v[0]; path.addLine(to: current)
                case "C":
                    guard let v = take(6) else { return }
                    current = CGPoint(x: v[4], y: v[5])
                    path.addCurve(to: current, control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
                case "Q":
                    guard let v = take(4) else { return }
                    current = CGPoint(x: v[2], y: v[3])
                    path.addQuadCurve(to: current, control: CGPoint(x: v[0], y: v[1]))
                case "Z":
                    path.closeSubpath(); current = start
                    return
                default:
                    return
                }
            } while i < numbers.count
        }

        var token = ""
        func endNumber() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }
        for character in data {
            if character.isLetter, character != "e" {
                endNumber(); flush()
                command = character; numbers = []
            } else if character == " " || character == "," || character == "\n" {
                endNumber()
            } else if character == "-", !token.isEmpty, token.last != "e" {
                endNumber(); token = "-"
            } else if character == ".", token.contains(".") {
                endNumber(); token = "."
            } else {
                token.append(character)
            }
        }
        endNumber(); flush()
        return path
    }
}

/// The parts of `Brand/Mascot/folmi-mascot.svg` (512 × 512 view box), copied here so the marks draw without
/// reading files at launch. `WelcomeMarkTests` checks every string still appears in the bundled rig.
enum FolmiMark {
    static let bodyData = "M238 205V169C238 100 278 61 338 61C385 61 408 91 408 119C408 151 390 164 355 165C322 164 312 173 311 204V210H356C377 210 386 219 386 234C386 251 377 260 357 260H311V351H237V271C237 263 234 260 226 260H204C182 260 175 251 175 235C175 218 183 210 205 210H230C236 210 238 208 238 205Z"
    static let tailData = "M237 333H311V355C311 416 278 449 224 449C180 449 147 429 138 395C132 373 140 353 155 351C171 349 177 363 184 375C194 392 204 397 216 393C233 387 237 375 237 355Z"
    static let earData = "M295 77C281 87 263 104 253 123C246 136 236 143 228 138C218 131 223 117 231 105C247 84 269 75 295 77Z"
    static let earCreaseData = "M290 82C280 102 269 123 253 132"
    static let highlightData = "M264 146C271 106 300 83 337 81"
    static let accentData = "M419 65V49M434 72L445 61M426 89H442"

    static let body = SVGPathData.path(bodyData)
    static let tail = SVGPathData.path(tailData)
    static let ear = SVGPathData.path(earData)
    static let earCrease = SVGPathData.path(earCreaseData)
    static let highlight = SVGPathData.path(highlightData)
    static let accent = SVGPathData.path(accentData)
    /// Body, tail and ear as one outline, for tracing and for hit tests.
    static let silhouette: Path = {
        var path = body
        path.addPath(tail)
        path.addPath(ear)
        return path
    }()

    struct Eye { let center: CGPoint; let radii: CGSize }
    static let eyes = [Eye(center: CGPoint(x: 351, y: 119), radii: CGSize(width: 9, height: 14)),
                       Eye(center: CGPoint(x: 386, y: 109), radii: CGSize(width: 8, height: 13))]
    static let eyeTilt = Angle.degrees(-12)

    /// Rotation anchors from docs/brand/folmi-motion.md, in view-box units.
    static let bodyAnchor = CGPoint(x: 274, y: 450)
    static let tailAnchor = CGPoint(x: 274, y: 345)
    static let earAnchor = CGPoint(x: 290, y: 83)
    static let eyesAnchor = CGPoint(x: 368, y: 114)

    /// The part of the view box the marks show: the mascot plus room for the accent lines.
    static let frame = CGRect(x: 120, y: 30, width: 350, height: 430)
    static let amber = ThemeRGB(0xE9AA47)
    static let charcoal = ThemeRGB(0x222429)

    /// View box → view, fitted and centered.
    static func fit(_ size: CGSize) -> CGAffineTransform {
        let scale = min(size.width / frame.width, size.height / frame.height)
        let x = (size.width - frame.width * scale) / 2 - frame.minX * scale
        let y = (size.height - frame.height * scale) / 2 - frame.minY * scale
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y)
    }

    static func eyePath(_ eye: Eye, scaleY: CGFloat = 1) -> Path {
        Path(ellipseIn: CGRect(x: -eye.radii.width, y: -eye.radii.height * scaleY,
                               width: eye.radii.width * 2, height: eye.radii.height * 2 * scaleY))
            .applying(CGAffineTransform(rotationAngle: eyeTilt.radians))
            .applying(CGAffineTransform(translationX: eye.center.x, y: eye.center.y))
    }
}

/// Piecewise keyframes with ease-in-out between keys; before the first key and after the last the value holds.
struct Keyframes {
    let keys: [(time: Double, value: Double)]
    init(_ keys: [(Double, Double)]) { self.keys = keys.map { (time: $0.0, value: $0.1) } }
    func callAsFunction(_ t: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.time {
            let u = (t - a.time) / max(0.0001, b.time - a.time)
            let eased = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            return a.value + (b.value - a.value) * eased
        }
        return last.value
    }
}

private func rotate(_ context: inout GraphicsContext, _ degrees: Double, around anchor: CGPoint) {
    guard degrees != 0 else { return }
    context.translateBy(x: anchor.x, y: anchor.y)
    context.rotate(by: .degrees(degrees))
    context.translateBy(x: -anchor.x, y: -anchor.y)
}

// MARK: - Shared clock

/// Plays an introduction once per appearance and then stops redrawing. `elapsed` is 0 before the first frame,
/// `.infinity` once the intro is over or under Reduce Motion, so each mark only needs a pure `pose(at:)`.
private struct IntroClock<Content: View>: View {
    let duration: Double
    /// Keeps frames coming after the intro, for a short hover reaction.
    var extraActive = false
    @ViewBuilder let content: (_ elapsed: Double, _ now: Date) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var start: Date?
    @State private var running = false

    private var animated: Bool { !reduceMotion && scenePhase == .active }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || !(running || extraActive))) { timeline in
            content(elapsed(at: timeline.date), timeline.date)
        }
        .task(id: animated) {
            guard animated else { running = false; return }
            guard start == nil else { return }
            start = .now
            running = true
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            running = false
        }
    }

    private func elapsed(at date: Date) -> Double {
        guard animated else { return .infinity }
        guard let start else { return 0 }
        guard running else { return .infinity }
        return max(0, date.timeIntervalSince(start))
    }
}

// MARK: - 琥珀: the mascot says hello

/// The greeting from `motion.json`, played once: a squashy rise, an ear flick, a blink, a tail wave, a spark.
enum FolmiGreeting {
    static let duration = 2.2

    /// The faces from `motion.json`: where the eyes look, or closed as arcs.
    enum Eyes: Equatable { case open, down, up, happy, closed, narrow }

    struct Pose: Equatable {
        var lift: Double, scaleX: Double, scaleY: Double, opacity: Double
        var ear: Double, blink: Double, tail: Double, accent: Double
        var eyes: Eyes = .open
        static let rest = Pose(lift: 0, scaleX: 1, scaleY: 1, opacity: 1, ear: 0, blink: 1, tail: 0, accent: 0)
    }

    private static let lift = Keyframes([(0, 70), (0.38, -14), (0.56, 0)])
    private static let scaleX = Keyframes([(0, 1), (0.38, 0.96), (0.56, 1.04), (0.7, 1)])
    private static let scaleY = Keyframes([(0, 0.6), (0.38, 1.05), (0.56, 0.95), (0.7, 1)])
    private static let opacity = Keyframes([(0, 0), (0.25, 1)])
    private static let ear = Keyframes([(0.65, 0), (0.76, -14), (0.92, 6), (1.1, 0)])
    private static let blink = Keyframes([(1.0, 1), (1.1, 0.12), (1.2, 1)])
    private static let tail = Keyframes([(1.15, 0), (1.31, 9), (1.51, -6), (1.71, 3), (1.95, 0)])
    private static let accent = Keyframes([(1.5, 0), (1.71, 1), (2.2, 0)])

    static func pose(at t: Double) -> Pose {
        guard t.isFinite else { return .rest }
        return Pose(lift: lift(t), scaleX: scaleX(t), scaleY: scaleY(t), opacity: opacity(t),
                    ear: ear(t), blink: blink(t), tail: tail(t), accent: accent(t))
    }

    /// How far the eyes look toward the pointer, in view-box units (at most 7).
    static func gaze(toward pointer: CGPoint?) -> CGSize {
        guard let pointer else { return .zero }
        let dx = pointer.x - FolmiMark.eyesAnchor.x, dy = pointer.y - FolmiMark.eyesAnchor.y
        let distance = max(1, hypot(dx, dy)), reach = min(7, distance / 20)
        return CGSize(width: dx / distance * reach, height: dy / distance * reach)
    }

    static func draw(_ context: GraphicsContext, size: CGSize, pose: Pose, gaze: CGSize) {
        var c = context
        c.concatenate(FolmiMark.fit(size))
        c.opacity = pose.opacity
        let amber = GraphicsContext.Shading.color(FolmiMark.amber.color)
        if pose.accent > 0 {
            var spark = c
            spark.opacity = pose.accent
            spark.stroke(FolmiMark.accent, with: amber, style: StrokeStyle(lineWidth: 7, lineCap: .round))
        }
        c.translateBy(x: 0, y: pose.lift)
        c.translateBy(x: FolmiMark.bodyAnchor.x, y: FolmiMark.bodyAnchor.y)
        c.scaleBy(x: pose.scaleX, y: pose.scaleY)
        c.translateBy(x: -FolmiMark.bodyAnchor.x, y: -FolmiMark.bodyAnchor.y)

        var tail = c
        rotate(&tail, pose.tail, around: FolmiMark.tailAnchor)
        tail.fill(FolmiMark.tail, with: amber)
        c.fill(FolmiMark.body, with: amber)
        c.stroke(FolmiMark.highlight, with: .color(ThemeRGB(0xFFD58D, 0.4).color), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        var ear = c
        rotate(&ear, pose.ear, around: FolmiMark.earAnchor)
        ear.fill(FolmiMark.ear, with: amber)
        ear.stroke(FolmiMark.earCrease, with: .color(ThemeRGB(0xBA7A29, 0.55).color), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        drawEyes(c, pose: pose, gaze: gaze)
    }

    private static func drawEyes(_ context: GraphicsContext, pose: Pose, gaze: CGSize) {
        let ink = GraphicsContext.Shading.color(FolmiMark.charcoal.color)
        switch pose.eyes {
        case .happy, .closed:
            // Closed eyes as short arcs: smiling (happy) or resting (closed).
            var arcs = Path()
            for eye in FolmiMark.eyes {
                let c = eye.center, w: CGFloat = 9, lift: CGFloat = pose.eyes == .happy ? -10 : 6
                arcs.move(to: CGPoint(x: c.x - w, y: c.y + 2))
                arcs.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x, y: c.y + lift))
            }
            context.stroke(arcs, with: ink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
        case .open, .down, .up, .narrow:
            var eyes = context
            let look: CGSize = pose.eyes == .down ? CGSize(width: -2, height: 6) : pose.eyes == .up ? CGSize(width: 3, height: -6) : .zero
            eyes.translateBy(x: gaze.width + look.width, y: gaze.height + look.height)
            eyes.translateBy(x: 0, y: FolmiMark.eyesAnchor.y)
            eyes.scaleBy(x: 1, y: pose.blink * (pose.eyes == .narrow ? 0.5 : 1))
            eyes.translateBy(x: 0, y: -FolmiMark.eyesAnchor.y)
            for eye in FolmiMark.eyes {
                eyes.fill(FolmiMark.eyePath(eye), with: ink)
                if pose.blink > 0.5, pose.eyes != .narrow {
                    let glint = CGRect(x: eye.center.x, y: eye.center.y - 8, width: 4, height: 6)
                    eyes.fill(Path(ellipseIn: glint), with: .color(ThemeRGB(0xFFF4DC, 0.9).color))
                }
            }
        }
    }
}

struct FolmiGreetingMark: View {
    @State private var pointer: CGPoint?
    var body: some View {
        IntroClock(duration: FolmiGreeting.duration) { elapsed, _ in
            Canvas { context, size in
                let local = pointer.map { $0.applying(FolmiMark.fit(size).inverted()) }
                FolmiGreeting.draw(context, size: size, pose: FolmiGreeting.pose(at: elapsed), gaze: FolmiGreeting.gaze(toward: local))
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location): pointer = location
            case .ended: pointer = nil
            }
        }
    }
}

// MARK: - 锌莓: a plotter traces the outline

enum ZincTrace {
    static let duration = 2.1

    struct Frame: Equatable {
        /// How much of the outline is drawn, 0…1.
        var trace: Double, fill: Double, eyes: Double, guides: Double, grid: Double, pen: Double
        static let rest = Frame(trace: 1, fill: 1, eyes: 1, guides: 0, grid: 0, pen: 0)
    }

    private static let trace = Keyframes([(0, 0), (1.5, 1)])
    private static let eyes = Keyframes([(1.7, 0), (1.85, 1)])
    private static let guides = Keyframes([(0, 1), (1.7, 1), (2.1, 0)])
    private static let grid = Keyframes([(1.7, 1), (2.1, 0)])
    private static let pen = Keyframes([(0, 1), (1.5, 1), (1.7, 0)])

    static func frame(at t: Double) -> Frame {
        guard t.isFinite else { return .rest }
        // The ink lands in three hard steps rather than a fade.
        let fill = t < 1.5 ? 0 : min(1, (((t - 1.5) / 0.26) * 3).rounded(.down) / 3)
        return Frame(trace: trace(t), fill: fill, eyes: eyes(t), guides: guides(t), grid: grid(t), pen: pen(t))
    }

    static let guideLines: [CGFloat] = [61, 210, 260, 449]

    static func draw(_ context: GraphicsContext, size: CGSize, frame: Frame, colors: ThemeColors, pointer: CGPoint?) {
        var c = context
        let fit = FolmiMark.fit(size)
        c.concatenate(fit)
        let box = FolmiMark.frame
        let ink = colors.foreground.color, berry = colors.accent.color
        let unit = 1 / fit.a

        if frame.grid > 0 {
            var grid = Path()
            for x in stride(from: box.minX, through: box.maxX, by: 20) { grid.move(to: CGPoint(x: x, y: box.minY)); grid.addLine(to: CGPoint(x: x, y: box.maxY)) }
            for y in stride(from: box.minY, through: box.maxY, by: 20) { grid.move(to: CGPoint(x: box.minX, y: y)); grid.addLine(to: CGPoint(x: box.maxX, y: y)) }
            c.stroke(grid, with: .color(ink.opacity(0.07 * frame.grid)), lineWidth: unit)
        }
        if frame.guides > 0 {
            var guides = Path()
            for y in guideLines { guides.move(to: CGPoint(x: box.minX, y: y)); guides.addLine(to: CGPoint(x: box.maxX, y: y)) }
            guides.addEllipse(in: CGRect(x: 280, y: 61, width: 116, height: 116))
            c.stroke(guides, with: .color(berry.opacity(0.45 * frame.guides)),
                     style: StrokeStyle(lineWidth: unit * 1.2, dash: [unit * 4, unit * 4]))
        }
        if frame.fill > 0 { c.fill(FolmiMark.silhouette, with: .color(ink.opacity(frame.fill))) }
        if frame.trace > 0 {
            c.stroke(FolmiMark.silhouette.trimmedPath(from: 0, to: frame.trace), with: .color(ink),
                     style: StrokeStyle(lineWidth: unit * 1.5, lineJoin: .round))
        }
        if frame.eyes > 0 {
            for eye in FolmiMark.eyes { c.fill(FolmiMark.eyePath(eye), with: .color(berry.opacity(frame.eyes))) }
        }
        if frame.pen > 0, let tip = FolmiMark.silhouette.trimmedPath(from: 0, to: max(0.0005, frame.trace)).currentPoint {
            c.fill(Path(ellipseIn: CGRect(x: tip.x - 7, y: tip.y - 7, width: 14, height: 14)), with: .color(berry.opacity(frame.pen)))
        }
        if let pointer {
            // A measuring crosshair with the view-box coordinate under the pointer.
            let p = pointer.applying(fit.inverted())
            var cross = Path()
            cross.move(to: CGPoint(x: p.x, y: box.minY)); cross.addLine(to: CGPoint(x: p.x, y: box.maxY))
            cross.move(to: CGPoint(x: box.minX, y: p.y)); cross.addLine(to: CGPoint(x: box.maxX, y: p.y))
            c.stroke(cross, with: .color(berry.opacity(0.8)), lineWidth: unit)
            let label = Text("\(Int(p.x.rounded())), \(Int(p.y.rounded()))")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(berry)
            context.draw(label, at: CGPoint(x: pointer.x + 6, y: pointer.y - 6), anchor: .bottomLeading)
        }
    }
}

struct ZincTraceMark: View {
    @Environment(\.folmiTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var pointer: CGPoint?
    var body: some View {
        let colors = theme.definition.colors(dark: colorScheme == .dark)
        IntroClock(duration: ZincTrace.duration) { elapsed, _ in
            Canvas { context, size in
                ZincTrace.draw(context, size: size, frame: ZincTrace.frame(at: elapsed), colors: colors, pointer: pointer)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case let .active(location): pointer = location
            case .ended: pointer = nil
            }
        }
    }
}

// MARK: - 像素: bricks stack into the mark

enum PixelBricks {
    static let cell: CGFloat = 7
    static let fall = 0.35
    static let duration = 1.4
    static let bump = 0.16

    struct Brick: Equatable { let column: Int; let row: Int; let ink: Bool }

    /// The cells whose centers fall inside the mascot, on a whole-point grid for `size`; the eye cells are ink.
    static func bricks(in size: CGSize) -> [Brick] {
        let fit = FolmiMark.fit(size), back = fit.inverted()
        let columns = Int(size.width / cell), rows = Int(size.height / cell)
        let eyeCells = Set(FolmiMark.eyes.map { eye -> Int in
            let p = eye.center.applying(fit)
            return Int(p.y / cell) * 1000 + Int(p.x / cell)
        })
        var result: [Brick] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let center = CGPoint(x: (CGFloat(column) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell)
                let ink = eyeCells.contains(row * 1000 + column)
                if ink || FolmiMark.silhouette.contains(center.applying(back)) {
                    result.append(Brick(column: column, row: row, ink: ink))
                }
            }
        }
        return result
    }

    /// `WelcomeMark` always draws at this size, so its bricks are worked out once.
    static let standardSize = CGSize(width: 160, height: 140)
    private static let standard = bricks(in: standardSize)
    static func cachedBricks(in size: CGSize) -> [Brick] { size == standardSize ? standard : bricks(in: size) }

    /// Bottom rows land first; neighbouring columns stagger a little.
    static func delay(_ brick: Brick, rows: Int) -> Double {
        (1 - Double(brick.row) / Double(max(1, rows))) * 0.9 + Double(brick.column % 3) * 0.04
    }

    /// Whole cells above the resting place, or nil before the brick enters. No easing between cells.
    static func lift(_ brick: Brick, rows: Int, at t: Double) -> Int? {
        guard t.isFinite else { return 0 }
        let k = min(1, max(0, (t - delay(brick, rows: rows)) / fall))
        guard k > 0 else { return nil }
        return Int(((1 - k * k) * Double(brick.row + 3)).rounded())
    }
}

struct PixelBrickMark: View {
    @Environment(\.folmiTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var bumps: [Int: Date] = [:]
    @State private var bumping = false
    @State private var bumpToken = 0
    @State private var size: CGSize = .zero

    var body: some View {
        let colors = theme.definition.colors(dark: colorScheme == .dark)
        let gold = colors.markFill(.modified)
        IntroClock(duration: PixelBricks.duration, extraActive: bumping) { elapsed, now in
            Canvas { context, size in
                let bricks = PixelBricks.cachedBricks(in: size)
                let rows = Int(size.height / PixelBricks.cell), s = PixelBricks.cell
                for (index, brick) in bricks.enumerated() {
                    guard var lift = PixelBricks.lift(brick, rows: rows, at: elapsed) else { continue }
                    if let hit = bumps[index], now.timeIntervalSince(hit) < PixelBricks.bump { lift += 1 }
                    let rect = CGRect(x: CGFloat(brick.column) * s, y: CGFloat(brick.row - lift) * s, width: s, height: s)
                    if brick.ink {
                        context.fill(Path(rect), with: .color(ThemeRGB(0x1A1F2E).color))
                    } else {
                        context.fill(Path(rect), with: .color(gold.color))
                        context.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: s - 2, height: 1.5)), with: .color(ThemeRGB(0xFFE08A).color))
                        context.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 1.5, width: s, height: 1.5)), with: .color(ThemeRGB(0xC98A00).color))
                    }
                }
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard case let .active(location) = phase else { return }
            let column = Int(location.x / PixelBricks.cell), row = Int(location.y / PixelBricks.cell)
            guard let index = PixelBricks.cachedBricks(in: size).firstIndex(where: { $0.column == column && $0.row == row }) else { return }
            let now = Date()
            if let last = bumps[index], now.timeIntervalSince(last) < 0.4 { return }
            bumps[index] = now
            bumping = true
            bumpToken += 1
        }
        .task(id: bumpToken) {
            guard bumpToken > 0 else { return }
            do { try await Task.sleep(for: .seconds(PixelBricks.bump + 0.05)) } catch { return }
            bumping = false
        }
    }
}

// MARK: - Per theme

/// The launch page's mark: each theme enters with its own signature. 琥珀 greets, 锌莓 traces, 石墨 gathers
/// mineral grains, 像素 stacks bricks. All play once, then stay still; Reduce Motion shows the last frame.
struct WelcomeMark: View {
    @Environment(\.folmiTheme) private var theme
    var body: some View {
        Group {
            switch theme {
            case .zinc: ZincTraceMark()
            case .terrazzo: TerrazzoWelcomeMark()
            case .pixel: PixelBrickMark()
            default: FolmiGreetingMark()
            }
        }
        .frame(width: PixelBricks.standardSize.width, height: PixelBricks.standardSize.height)
        .id(theme)
        .accessibilityHidden(true)
    }
}
