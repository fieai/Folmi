import AppKit
import SwiftUI

enum TerrazzoParticleKind: Sendable {
    case activation, completion
    var duration: Double { self == .activation ? 0.46 : 0.64 }
}

/// Deterministic, bounded particles: no random changes while drawing and no perpetual simulation.
enum TerrazzoParticleGeometry {
    struct Grain {
        let center: CGPoint
        let radius: CGFloat
        let opacity: Double
        let colorIndex: Int
    }

    static func grains(size: CGSize, progress: Double, kind: TerrazzoParticleKind) -> [Grain] {
        guard progress > 0, progress < 1, size.width > 0, size.height > 0 else { return [] }
        let count = kind == .activation ? 18 : 28
        let p = CGFloat(progress)
        return (0..<count).map { index in
            let unit = CGFloat((index * 37 + 11) % 101) / 100
            let top = index.isMultiple(of: 2)
            let distance: CGFloat = kind == .activation ? 8 : 17
            // Activation draws in again; completion settles outward. Neither crosses the label's rectangle.
            let travel = kind == .activation ? sin(p * .pi) * distance : (1 - pow(1 - p, 2)) * distance
            let x = 4 + unit * max(0, size.width - 8) + (unit - 0.5) * travel * 0.6
            let y = top ? -3 - travel : size.height + 3 + travel
            return Grain(center: CGPoint(x: x, y: y), radius: 1.1 + CGFloat(index % 4) * 0.35,
                         opacity: min(1, progress * 10) * pow(1 - progress, 0.65), colorIndex: index)
        }
    }

    static func shard(center: CGPoint, radius: CGFloat, seed: Int) -> Path {
        let r = radius
        var path = Path()
        path.move(to: CGPoint(x: center.x - r, y: center.y - r * 0.45))
        path.addLine(to: CGPoint(x: center.x + r * 0.25, y: center.y - r))
        path.addLine(to: CGPoint(x: center.x + r, y: center.y + r * (seed.isMultiple(of: 2) ? 0.25 : 0.6)))
        path.addLine(to: CGPoint(x: center.x - r * 0.35, y: center.y + r * 0.8))
        path.closeSubpath()
        return path
    }
}

private struct TerrazzoBurstCanvas: View, Animatable {
    nonisolated var progress: Double
    let kind: TerrazzoParticleKind
    let colors: [ThemeRGB]
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                guard !colors.isEmpty else { return }
                context.translateBy(x: 24, y: 24)
                for grain in TerrazzoParticleGeometry.grains(size: geometry.size, progress: progress, kind: kind) {
                    context.fill(TerrazzoParticleGeometry.shard(center: grain.center, radius: grain.radius, seed: grain.colorIndex),
                                 with: .color(colors[grain.colorIndex % colors.count].color.opacity(grain.opacity)))
                }
            }
            .frame(width: geometry.size.width + 48, height: geometry.size.height + 48)
            .offset(x: -24, y: -24)
        }
    }
}

/// 像素's version: square blocks in the four status colors that jump outward on whole-point steps, like an 8-bit
/// sprite, instead of mineral shards drifting.
private struct PixelBurstCanvas: View, Animatable {
    nonisolated var progress: Double
    let kind: TerrazzoParticleKind
    let colors: [ThemeRGB]
    let edge: ThemeRGB
    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                guard !colors.isEmpty, progress > 0, progress < 1 else { return }
                context.translateBy(x: 24, y: 24)
                // Seven frames, not a smooth glide.
                let frame = (progress * 7).rounded(.down) / 7
                let size = geometry.size
                let count = kind == .activation ? 10 : 16
                let reach: CGFloat = kind == .activation ? 10 : 20
                let travel = (1 - pow(1 - CGFloat(frame), 2)) * reach
                for index in 0..<count {
                    let unit = CGFloat((index * 37 + 11) % 101) / 100
                    let top = index.isMultiple(of: 2)
                    let x = 2 + unit * max(0, size.width - 4) + (unit - 0.5) * travel
                    let y = top ? -4 - travel : size.height + 4 + travel
                    let side: CGFloat = index % 3 == 0 ? 5 : 4
                    let rect = CGRect(x: (x / 2).rounded() * 2 - side / 2, y: (y / 2).rounded() * 2 - side / 2, width: side, height: side)
                    let fade = frame < 0.72 ? 1 : 1 - (frame - 0.72) / 0.28
                    context.fill(Path(rect), with: .color(colors[index % colors.count].color.opacity(fade)))
                    context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(edge.color.opacity(fade * 0.6)), lineWidth: 1)
                }
            }
            .frame(width: geometry.size.width + 48, height: geometry.size.height + 48)
            .offset(x: -24, y: -24)
        }
    }
}

private struct TerrazzoBurstPlayback: View {
    let kind: TerrazzoParticleKind
    let colors: [ThemeRGB]
    /// Set for 像素: draw square blocks with this edge instead of shards.
    var pixelEdge: ThemeRGB? = nil
    let finished: () -> Void
    @State private var progress = 0.0

    var body: some View {
        Group {
            if let pixelEdge {
                PixelBurstCanvas(progress: progress, kind: kind, colors: colors, edge: pixelEdge)
            } else {
                TerrazzoBurstCanvas(progress: progress, kind: kind, colors: colors)
            }
        }
            .task {
                withAnimation(Motion.resolved(.linear(duration: kind.duration), reduceMotion: Motion.systemReducesMotion)) { progress = 1 }
                do { try await Task.sleep(for: .seconds(kind.duration)) }
                catch { return }
                finished()
            }
    }
}

private struct TerrazzoParticleFeedback: ViewModifier {
    let trigger: Int
    let kind: TerrazzoParticleKind
    @State private var playback: UUID?
    @Environment(\.folmiTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var enabled: Bool { (theme == .terrazzo || theme == .pixel) && !reduceMotion && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .overlay {
                if enabled, let current = playback {
                    let palette = theme.definition.colors(dark: colorScheme == .dark)
                    let pixel = theme == .pixel
                    let colors = pixel ? [palette.removed, palette.markFill(.modified), palette.accent, palette.added]
                        : palette.primaryMaterial?.speckles ?? [palette.accent]
                    TerrazzoBurstPlayback(kind: kind, colors: colors, pixelEdge: pixel ? palette.border : nil) {
                        if playback == current { playback = nil }
                    }
                    .id(current)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onChange(of: trigger) { _, _ in playback = enabled ? UUID() : nil }
            .onChange(of: enabled) { _, _ in playback = nil }
            .onDisappear { playback = nil }
    }
}

extension View {
    /// A short burst when something finishes (review done, commit landed): mineral grains under 石墨, pixel blocks
    /// under 像素, nothing elsewhere or under Reduce Motion.
    func terrazzoParticles(trigger: Int, kind: TerrazzoParticleKind = .completion) -> some View {
        modifier(TerrazzoParticleFeedback(trigger: trigger, kind: kind))
    }
}

/// Sample the shipped mascot once. The particle silhouette is the actual Folmi mark, not a substitute drawing.
enum TerrazzoMarkGeometry {
    struct Dot: Sendable {
        let point: CGPoint
        let ink: Bool
    }

    @MainActor static let dots: [Dot] = {
        guard let url = AppResources.folder("Brand")?.appendingPathComponent("UI/folmi-mascot-128.png"),
              let data = try? Data(contentsOf: url), let bitmap = NSBitmapImageRep(data: data) else { return [] }
        var result: [Dot] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.55 else { continue }
                result.append(Dot(point: CGPoint(x: CGFloat(x) / CGFloat(bitmap.pixelsWide), y: CGFloat(y) / CGFloat(bitmap.pixelsHigh)),
                                  ink: color.redComponent < 0.4))
            }
        }
        return result
    }()
}

private struct TerrazzoMarkCanvas: View, Animatable {
    nonisolated var scatter: Double
    nonisolated var hover: Double
    let pointer: CGPoint
    let dots: [TerrazzoMarkGeometry.Dot]
    let colors: ThemeColors
    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(scatter, hover) }
        set { scatter = newValue.first; hover = newValue.second }
    }

    var body: some View {
        Canvas { context, size in
            // The PNG shares the rig's 512 view box, so the grains land where the other themes' marks draw.
            let fit = FolmiMark.fit(size)
            // Grains were tuned for a 116 pt mark; they grow with it so the stone stays as dense.
            let grain = fit.a / (116 / 512)
            let minerals = colors.primaryMaterial?.speckles ?? [colors.accent]
            for (index, dot) in dots.enumerated() {
                let target = CGPoint(x: dot.point.x * 512, y: dot.point.y * 512).applying(fit)
                let angle = Double(index) * 2.399963
                let spread = CGFloat(scatter) * (18 + CGFloat(index % 31))
                let dx = target.x - pointer.x, dy = target.y - pointer.y
                let distance = max(1, hypot(dx, dy))
                let repulsion = CGFloat(hover) * max(0, 1 - distance / 48) * 15
                let center = CGPoint(x: target.x + cos(angle) * spread + dx / distance * repulsion,
                                     y: target.y + sin(angle) * spread + dy / distance * repulsion)
                let color = dot.ink ? colors.foreground : (index.isMultiple(of: 7) ? minerals[index % minerals.count] : colors.accent)
                context.fill(TerrazzoParticleGeometry.shard(center: center, radius: (1.65 + CGFloat(index % 3) * 0.15) * grain, seed: index),
                             with: .color(color.color.opacity(1 - scatter * 0.5)))
            }
        }
    }
}

/// Intro assembles once and then becomes still. Hover affects only the mark; no display link runs while idle.
struct TerrazzoWelcomeMark: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var introduced = false
    @State private var scatter = 1.0
    @State private var hover = 0.0
    @State private var pointer = CGPoint(x: 80, y: 70)

    private var animated: Bool { !reduceMotion && scenePhase == .active }

    var body: some View {
        let colors = ThemeCatalog.terrazzo.colors(dark: colorScheme == .dark)
        TerrazzoMarkCanvas(scatter: animated ? scatter : 0, hover: animated ? hover : 0,
                           pointer: pointer, dots: TerrazzoMarkGeometry.dots, colors: colors)
            .frame(width: 160, height: 140)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard animated else { return }
                switch phase {
                case let .active(location):
                    pointer = location
                    withAnimation(Motion.resolved(.easeOut(duration: 0.18), reduceMotion: reduceMotion)) { hover = 1 }
                case .ended:
                    withAnimation(Motion.resolved(.easeOut(duration: 0.4), reduceMotion: reduceMotion)) { hover = 0 }
                }
            }
            .task(id: animated) {
                guard animated else { scatter = 0; hover = 0; return }
                guard !introduced else { return }
                introduced = true
                scatter = 1
                do { try await Task.sleep(for: .milliseconds(40)) }
                catch { return }
                withAnimation(Motion.resolved(.easeOut(duration: 1.05), reduceMotion: reduceMotion)) { scatter = 0 }
            }
            .accessibilityHidden(true)
    }
}
