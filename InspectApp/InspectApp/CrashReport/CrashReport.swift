import Foundation

/// One parsed entry from `~/Library/Logs/DiagnosticReports/`. Holds enough
/// summary information for the prompt UI plus the raw file body so we can
/// drop the whole report onto the user's pasteboard when they file an
/// issue.
struct CrashReport: Identifiable, Equatable {
    let url: URL
    let processName: String
    let appVersion: String?
    let osVersion: String?
    let bundleID: String?
    let date: Date
    let exceptionType: String?
    let signal: String?
    let crashedThreadIndex: Int?
    let rawContents: String

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
}
