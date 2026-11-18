import AppKit
import SwiftUI

struct ProjectRailIcon: View {
    let project: ProjectPreferences
    let model: FolmiModel
    let help: String
    @State private var targeted = false

    var body: some View {
        content
            .frame(width: 28, height: 30)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(ThemeColor(token: .accent), lineWidth: 1.5)
                    .opacity(targeted ? 1 : 0)
                    .padding(1)
            }
            .overlay {
                ProjectIconDropTarget(targeted: $targeted, help: help) { png in model.setProjectImage(png, path: project.rootPath) }
                    .accessibilityHidden(true)
            }
            .task { model.projectIcons.load(project) }
    }

    @ViewBuilder private var content: some View {
        if case .emoji(let emoji) = project.customIcon {
            Text(emoji).font(.system(size: 17))
        } else if let image = image {
            Image(nsImage: image).resizable().frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        } else {
            let theme = model.theme.definition
            let fill = theme.projectBadges[ProjectIconCache.paletteIndex(project.rootPath)]
            Text(ProjectIconCache.abbreviation(project.name))
                .themedFont(.system(size: 11, weight: .semibold), points: 11)
                .minimumScaleFactor(0.75).lineLimit(1)
                .frame(width: 22, height: 22)
                .foregroundStyle(theme.light.foreground.color)
                .background(fill.color, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var image: NSImage? {
        if case .image = project.customIcon, let custom = model.projectIcons.custom[project.rootPath] { return custom }
        return model.projectIcons.automatic[project.rootPath]
    }
}

/// The pasteboard supplies the Finder URL synchronously, so a corrupt image can be refused before dropping it.
private struct ProjectIconDropTarget: NSViewRepresentable {
    @Binding var targeted: Bool
    let help: String
    let onDrop: (Data) -> Void

    func makeNSView(context: Context) -> ProjectIconDropView { ProjectIconDropView() }

    func updateNSView(_ view: ProjectIconDropView, context: Context) {
        view.onTarget = { targeted = $0 }
        view.onDrop = onDrop
        view.toolTip = help
    }
}

final class ProjectIconDropView: NSView {
    private var pending: Data?
    var onTarget: ((Bool) -> Void)?
    var onDrop: ((Data) -> Void)?

    init() {
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    // The SwiftUI button underneath still owns ordinary clicks and its context menu.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        pending = sender.draggingSourceOperationMask.contains(.copy) ? Self.thumbnail(sender.draggingPasteboard) : nil
        onTarget?(pending != nil)
        return pending == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { clear() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clear() }
        guard let pending else { return false }
        onDrop?(pending)
        return true
    }

    private func clear() { pending = nil; onTarget?(false) }

    static func thumbnail(_ pasteboard: NSPasteboard) -> Data? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let urls, urls.count == 1, let url = urls.first else { return nil }
        return ProjectIconCache.thumbnail(from: url)
    }
}
