import Foundation
import WebKit

/// Serves the reader's bundled scripts, styles and fonts (KaTeX, Mermaid) as `folmi-asset://local/<path>`.
/// Only files inside the bundled ReaderAssets folder and only these types; nothing comes from the network.
final class ReaderAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "folmi-asset"
    nonisolated static let types = ["js": "text/javascript", "css": "text/css", "woff2": "font/woff2"]

    /// The ReaderAssets folder: inside the app's resources when packaged, SwiftPM's resource bundle otherwise.
    nonisolated static let root: URL? = AppResources.folder("ReaderAssets")

    nonisolated static func data(for url: URL) -> (Data, String)? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let root, !parts.isEmpty, parts.allSatisfy({ $0 != ".." && $0 != "." && !$0.hasPrefix(".") }),
              let type = types[(parts.last! as NSString).pathExtension.lowercased()] else { return nil }
        let file = parts.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else { return nil }
        return (data, type)
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let (data, type) = Self.data(for: url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             // Fonts are loaded from another origin than the page, which needs CORS.
                                             headerFields: ["Content-Type": type, "Content-Length": String(data.count),
                                                            "Access-Control-Allow-Origin": "*", "Cache-Control": "max-age=31536000"]) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
