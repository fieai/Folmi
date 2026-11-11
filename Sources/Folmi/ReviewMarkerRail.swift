import SwiftUI

struct ReviewMarker: Identifiable {
    enum Destination: Hashable {
        case file(String, hunkID: String?, comment: UUID?)
        case match(Int)
    }

    let id: Destination
    let position: Double
    let token: ThemeToken
    let title: String
}

/// The ticks follow the order of the review. Neighbouring ticks share one hit target when the window is short.
struct ReviewMarkerRail: View {
    let markers: [ReviewMarker]
    let onSelect: (ReviewMarker.Destination) -> Void
    @State private var last: ReviewMarker.Destination?

    var body: some View {
        GeometryReader { geometry in
            let slotCount = max(1, Int(geometry.size.height / 14))
            let groups = Dictionary(grouping: markers) {
                min(slotCount - 1, Int($0.position * Double(slotCount)))
            }
            ForEach(groups.keys.sorted(), id: \.self) { slot in
                if let group = groups[slot], let first = group.first {
                    tick(first, group: group)
                        .position(x: geometry.size.width / 2, y: (CGFloat(slot) + 0.5) * geometry.size.height / CGFloat(slotCount))
                }
            }
        }
        .frame(width: 16)
        .padding(.vertical, 5)
        .background(ThemeColor(token: .secondaryText, opacity: 0.055))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("改动定位刻度")
    }

    private func tick(_ first: ReviewMarker, group: [ReviewMarker]) -> some View {
        let selected = group.firstIndex { $0.id == last }.map { ($0 + 1) % group.count } ?? 0
        return Button {
            let next = group[selected]
            last = next.id
            onSelect(next.id)
        } label: {
            Capsule().fill(ThemeColor(token: first.token, opacity: 0.8))
                .frame(width: 8, height: group.count == 1 ? 3 : 5)
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(group.count == 1 ? first.title : "\(group[selected].title) · 此处有 \(group.count) 项，连点切换")
        .accessibilityLabel(group[selected].title)
    }
}
