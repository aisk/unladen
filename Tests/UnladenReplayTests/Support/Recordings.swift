import Foundation
import HTTPTypes
import Testing
@_spi(Wire) import UnladenCore
import UnladenTestSupport

/// One recorded exchange with a vendor, as `Scripts/recordings` imported it:
/// `case.json` (provenance, vendor, protocol, status, facts) plus the
/// request and response bodies as recorded.
///
/// Every test over recordings is parameterized on ``Recording/all`` (or a
/// filter of it), so a case added to the manifest is a new test case in
/// every layer it qualifies for.
struct Recording: Sendable, Hashable, CustomTestStringConvertible {
    let id: String
    let meta: JSONValue
    let directory: URL

    var testDescription: String { id }

    // MARK: Loading

    static let root: URL = Bundle.module.url(forResource: "Recordings", withExtension: nil)!

    /// Every recording, sorted by id.
    static let all: [Recording] = {
        let manager = FileManager.default
        var result: [Recording] = []
        let vendors = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        for vendor in vendors.sorted() {
            let vendorURL = root.appendingPathComponent(vendor)
            for name in ((try? manager.contentsOfDirectory(atPath: vendorURL.path)) ?? []).sorted() {
                let directory = vendorURL.appendingPathComponent(name)
                guard let data = manager.contents(atPath: directory.appendingPathComponent("case.json").path),
                      let meta = try? JSONValue(parsing: Array(data))
                else { continue }
                result.append(Recording(id: "\(vendor)/\(name)", meta: meta, directory: directory))
            }
        }
        return result
    }()

    static func named(_ id: String) -> Recording {
        guard let recording = all.first(where: { $0.id == id }) else {
            fatalError("no recording \(id); run Scripts/recordings/import_recordings.py")
        }
        return recording
    }

    // MARK: Metadata

    var vendor: String { meta["vendor"]?.stringValue ?? "" }
    var wire: WireProtocol { WireProtocol(rawValue: meta["protocol"]?.stringValue ?? "")! }
    var status: Int { meta["status"]?.numberValue?.int ?? 200 }
    var isSuccess: Bool { (200..<300).contains(status) }
    var isStream: Bool { meta["stream"] == true }
    /// The Unladen model reference (`provider/model`) the recording's
    /// vendor and model resolve to, when Unladen has a preset for it.
    var target: String? { meta["target"]?.stringValue }
    var model: String? { meta["model"]?.stringValue }
    /// The recorded request path (e.g. `/v1/messages`), when known.
    var path: String? { meta["path"]?.stringValue }
    /// What the recorded response says, extracted independently of Unladen.
    var facts: JSONValue? { meta["facts"] }
    var client: String? { meta["client"]?.stringValue }
    var responseHeaders: HTTPFields {
        var fields = HTTPFields()
        for (name, value) in meta["headers"]?.objectValue ?? [:] {
            if let field = HTTPField.Name(name), let value = value.stringValue { fields[field] = value }
        }
        return fields
    }

    /// The reason a check of this recording is a known issue, if it is one
    /// (`expect.knownIssues.<check>` in the manifest).
    func knownIssue(_ check: String) -> String? {
        meta["expect"]?["knownIssues"]?[check]?.stringValue
    }

    /// Request body paths allowed to differ when the recorded request is
    /// sent again through Unladen, with the reason
    /// (`expect.requestChanges`).
    var allowedRequestChanges: [String: String] {
        var result: [String: String] = [:]
        for (path, reason) in meta["expect"]?["requestChanges"]?.objectValue ?? [:] {
            result[path] = reason.stringValue ?? ""
        }
        return result
    }

    /// Warning codes the decoder is expected to produce (beyond the
    /// lossless `unknown_field` / `opaque_content` notes).
    var expectedWarnings: Set<String> {
        Set((meta["expect"]?["warnings"]?.arrayValue ?? []).compactMap(\.stringValue))
    }

    // MARK: Bodies

    private func file(_ name: String) -> [UInt8]? {
        FileManager.default.contents(atPath: directory.appendingPathComponent(name).path).map(Array.init)
    }

    var requestBytes: [UInt8]? { file("request.json") }
    var requestJSON: JSONValue? { requestBytes.flatMap { try? JSONValue(parsing: $0) } }
    var responseBytes: [UInt8]? { file(isStream ? "response.sse" : "response.json") }
    var responseJSON: JSONValue? { isStream ? nil : responseBytes.flatMap { try? JSONValue(parsing: $0) } }

    func responseElements() throws -> [SSEElement] {
        var parser = SSEParser()
        let elements = try parser.parse(responseBytes ?? [])
        parser.finish()
        return elements
    }
}

// MARK: - Filters

extension Recording {
    /// Successful replies with a body (decodable by the protocol's codec).
    static var replies: [Recording] { all.filter { $0.isSuccess && $0.responseBytes != nil } }
    static var completeReplies: [Recording] { replies.filter { !$0.isStream } }
    static var streamedReplies: [Recording] { replies.filter(\.isStream) }
    /// Non-2xx replies.
    static var errors: [Recording] { all.filter { !$0.isSuccess } }
    /// Recorded requests (vendor traffic and client samples).
    static var requests: [Recording] { all.filter { $0.requestBytes != nil } }
    /// Requests a vendor accepted, with an Unladen preset for the vendor.
    static var acceptedRequests: [Recording] {
        all.filter { $0.isSuccess && $0.requestBytes != nil && $0.target != nil && $0.client == nil }
    }
}

// MARK: - Checking

/// Records `problems` as failures, or as a known issue when the recording
/// lists `check` under `expect.knownIssues` (a known issue that no longer
/// reproduces is then reported, so stale entries are noticed).
///
/// `expect.accepted.<check>` instead names a difference judged correct
/// behaviour (not a bug), with the reason; the check then only requires
/// that some difference is still there, so a stale entry is noticed too.
func expectNoProblems(
    _ problems: [String],
    _ recording: Recording,
    check: String,
    sourceLocation: SourceLocation = #_sourceLocation,
) {
    if let reason = recording.meta["expect"]?["accepted"]?[check]?.stringValue {
        #expect(!problems.isEmpty, "\(recording.id): \(check) is accepted as differing (\(reason)) but no longer differs", sourceLocation: sourceLocation)
        return
    }
    if let reason = recording.knownIssue(check) {
        withKnownIssue(Comment(rawValue: reason)) {
            for problem in problems { Issue.record(Comment(rawValue: problem), sourceLocation: sourceLocation) }
        }
    } else {
        #expect(problems == [], "\(recording.id): \(check)", sourceLocation: sourceLocation)
    }
}
