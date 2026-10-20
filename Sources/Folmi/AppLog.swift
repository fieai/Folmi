import Foundation
import os

/// Failures that do not stop anything but should not vanish either: caches and small state files that could not be
/// written. They go to the unified log (Console.app, subsystem local.folmi), never to a dialog.
enum AppLog {
    static let logger = Logger(subsystem: "local.folmi", category: "app")

    static func failure(_ what: String, _ error: Error) {
        logger.error("\(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }

    /// Runs a write whose failure is only worth a log line.
    static func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch { failure(what, error) }
    }
}
