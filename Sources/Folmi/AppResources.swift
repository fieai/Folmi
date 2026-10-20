import AppKit

/// Folders from the target's SwiftPM resources (Fonts, ReaderAssets, Brand).
enum AppResources {
    static let bundleName = "Folmi_Folmi.bundle"

    /// The folder `name` inside the resource bundle: the copy in the packaged app first, SwiftPM's own otherwise.
    /// The bundle is flat from `swift build` but has Contents/Resources from the newer build system, so its
    /// resource folder comes from `Bundle` rather than from a fixed path.
    static func folder(_ name: String) -> URL? {
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0?.appendingPathComponent(bundleName) }
        for candidate in candidates {
            guard let resources = Bundle(url: candidate)?.resourceURL else { continue }
            let url = resources.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return Bundle.module.url(forResource: name, withExtension: nil)
    }

    /// The Folmi mark as a one-color menu bar template (18 pt, with its @2x), tinted by the system like any status item.
    @MainActor static let menuBarMark: NSImage? = {
        guard let folder = folder("Brand")?.appendingPathComponent("MenuBar") else { return nil }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for file in ["folmi-18Template.png", "folmi-18Template@2x.png"] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)), let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        return image
    }()

    /// The Folmi mascot in color, for places that introduce the app.
    @MainActor static let mascot: NSImage? = folder("Brand").flatMap { NSImage(contentsOf: $0.appendingPathComponent("UI/folmi-mascot-64.png")) }
}
