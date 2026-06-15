import Foundation
import OSLog

/// stderr-bound logging.
///
/// ARIA_MCP_SPEC_v0.2 §5 reserves stdout for JSON-RPC frames; any
/// human-readable log line must go to stderr instead. OSLog on macOS
/// routes through the unified logging system (not stdout) by default,
/// so the Logger we expose is safe for diagnostics. The stderr handle
/// is also surfaced as a backup channel for the rare case where a
/// caller needs to print directly (e.g. write-side I/O failures
/// inside the stdio loop).
public enum Logging {

    /// Apple OSLog channel. Fleet-standard subsystem and a category
    /// scoped to this kit per CLAUDE.md. Exported for library
    /// consumers that want the unified-logging path; the server's own
    /// banners and stdio-loop diagnostics use `stderr` so they are
    /// visible to clients scraping the child process's stderr stream.
    public static let osLog = Logger(subsystem: "com.mootx01.kit", category: "AriaMCP")

    /// The stderr writer. Use this when a message must appear in the
    /// process's stderr stream specifically (e.g. tools that scrape
    /// child-process output). All routine diagnostics should go to
    /// `osLog`, which is filterable and structured.
    public static let stderr = StderrLogger()
}

/// A tiny writer that prints a single line to stderr per call. Wraps
/// `FileHandle.standardError` so callers do not have to construct one
/// themselves and the writes go through one place.
public struct StderrLogger: Sendable {

    public init() {}

    /// Write `message` to stderr terminated by a newline. Failures
    /// are intentionally swallowed: there is no logging-of-logger
    /// recursion to chase here, and a failed stderr write is the rare
    /// case where doing nothing is the right move.
    public func log(_ message: String) {
        var line = message
        line.append("\n")
        guard let data = line.data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
