import Foundation
import HTTPTypes
import Testing
import Unladen
@_spi(Wire) import UnladenCore
import UnladenTestSupport

/// The recordings whose vendor accepted the recorded request and whose
/// target resolves to an endpoint of the recording's protocol.
private let replayable: [Recording] = Recording.acceptedRequests.filter { recording in
    guard let target = recording.target,
          let resolved = try? ProviderRegistry.builtIn.resolve(target, preferring: recording.wire.apiProtocol)
    else { return false }
    return resolved.endpoint.apiProtocol.wire == recording.wire
}

/// Whether a `jsonDifferences` line is at exactly `path`; `[*]` in `path`
/// matches any array index.
func matches(_ difference: String, path: String) -> Bool {
    var location = Substring(difference.prefix { $0 != ":" && $0 != " " })
    var pattern = Substring(path)
    while !pattern.isEmpty {
        if pattern.hasPrefix("[*]") {
            guard location.first == "[" else { return false }
            let digits = location.dropFirst().prefix(while: \.isNumber)
            guard !digits.isEmpty, location.dropFirst(1 + digits.count).first == "]" else { return false }
            location = location.dropFirst(2 + digits.count)
            pattern = pattern.dropFirst(3)
        } else {
            guard location.first == pattern.first else { return false }
            location = location.dropFirst()
            pattern = pattern.dropFirst()
        }
    }
    return location.isEmpty
}

/// Non-2xx recordings (each has a target).
private let errorReplies: [Recording] = Recording.errors.filter { $0.target != nil }

/// Successful replies that carry an in-stream error.
private let streamErrors: [Recording] = Recording.streamedReplies.filter { $0.facts?["error"] != nil && $0.target != nil }

/// Layer B: recordings through ``UpstreamCall`` against a mock transport.
///
/// - A request the vendor accepted, decoded as a client request of the same
///   protocol and sent through the vendor's preset (Profile transforms,
///   encoding, path, auth), goes out as recorded: any difference must be
///   declared in the case (`expect.requestChanges`) with its reason. The
///   recorded reply then comes back through the call (stream bridging
///   included) and says what the recording says.
/// - A recorded error status reaches the caller verbatim (`UpstreamError`)
///   and maps to the library's ``UnladenError/http(_:)`` with the provider's
///   message, retryability and `Retry-After`.
@Suite struct UpstreamReplayTests {
    let registry = ProviderRegistry.builtIn

    func target(_ recording: Recording) throws -> ResolvedModel {
        try registry.resolve(try #require(recording.target), preferring: recording.wire.apiProtocol)
    }

    @Test(arguments: replayable)
    func acceptedRequestGoesOutAsRecorded(_ recording: Recording) async throws {
        let target = try target(recording)
        let replay = ReplayTransport([recording])
        let call = UpstreamCall(target: target, apiKey: "test-key", transport: replay.transport)
        let request = try Codecs.parseRequest(
            recording.requestBytes ?? [], as: recording.wire, model: recording.model ?? target.model, stream: recording.isStream,
        )
        let reply = try await call.send(request.value, stream: recording.isStream)
        let sent = try #require(replay.requests.first)

        // Path and credentials as the vendor expects them.
        if let recordedPath = recording.path, recording.meta["host"]?.stringValue == sent.head.authority {
            let route = String(recordedPath.split(whereSeparator: { $0 == "?" || $0 == "#" }).first ?? "")
            #expect(sent.route.hasSuffix(route), "\(sent.route) does not end in the recorded \(route)")
        }
        switch target.endpoint.auth {
        case .bearer: #expect(sent.header("authorization") == "Bearer test-key")
        case .anthropic: #expect(sent.header("x-api-key") == "test-key")
        case .googleAPIKey: #expect(sent.header("x-goog-api-key") == "test-key")
        case .none: break
        }

        // The body, modulo declared changes.
        let allowed = recording.allowedRequestChanges.keys
        let problems = jsonDifferences(sent.json, try #require(recording.requestJSON)).filter { difference in
            !CodecReplayTests.isWrittenBack(difference, recording.wire) && !allowed.contains { matches(difference, path: $0) }
        }
        expectNoProblems(problems, recording, check: "requestReplay")

        // The recorded reply comes back through the call.
        let response: WireResponse
        switch reply.body {
        case .response(let complete):
            response = complete
        case .events(let stream):
            var accumulator = WireResponseAccumulator()
            for try await event in stream { accumulator.add(event) }
            response = accumulator.response
        }
        let summary = ReplySummary(response)
        let facts = try #require(recording.facts)
        #expect(summary.text == facts["text"]?.stringValue)
        #expect(summary.toolCalls.map(\.name) == (facts["toolCalls"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue })
    }

    @Test(arguments: errorReplies)
    func errorStatusReachesTheCaller(_ recording: Recording) async throws {
        let target = try target(recording)
        let call = UpstreamCall(target: target, apiKey: "test-key", transport: ReplayTransport([recording]).transport)
        let request = try recording.requestBytes.map {
            try Codecs.parseRequest($0, as: recording.wire, model: recording.model ?? target.model, stream: recording.isStream).value
        } ?? WireRequest(model: target.model, messages: [WireMessage(role: .user, parts: [.text(WireText("Hello"))])])

        await #expect {
            _ = try await call.send(request, stream: false)
        } throws: { error in
            guard case UpstreamError.http(let http) = error else { return false }
            return http.status.code == recording.status && http.body == recording.responseBytes
                && http.retryAfter == recording.responseHeaders[.retryAfter]
        }

        // The library's view of the same reply.
        let client = ModelClient(
            transport: ReplayTransport([recording]).transport, apiKeys: [target.provider: "test-key"],
            environment: [:], warningPolicy: .lenient,
        )
        let model = try client.model(try #require(recording.target), preferring: recording.wire.apiProtocol)
        do {
            _ = try await model.generate("Hello")
            Issue.record("expected HTTP \(recording.status)")
        } catch UnladenError.http(let http) {
            #expect(http.statusCode == recording.status)
            #expect(http.providerMessage == recording.facts?["error"]?.stringValue)
            #expect(http.isRetryable == ([408, 409, 429].contains(recording.status) || recording.status >= 500))
            #expect(http.retryAfterSeconds == recording.responseHeaders[.retryAfter].flatMap { Int($0) })
        }
    }

    @Test(arguments: streamErrors)
    func streamErrorReachesTheCaller(_ recording: Recording) async throws {
        let target = try target(recording)
        // Through the call, streamed: an error event carries the message.
        let call = UpstreamCall(target: target, apiKey: "test-key", transport: ReplayTransport([recording]).transport)
        let reply = try await call.send(
            WireRequest(model: target.model, messages: [WireMessage(role: .user, parts: [.text(WireText("Hello"))])]), stream: true,
        )
        guard case .events(let stream) = reply.body else {
            Issue.record("expected a stream")
            return
        }
        var errors: [WireStreamError] = []
        for try await event in stream {
            if case .error(let error) = event { errors.append(error) }
        }
        #expect(errors.first?.message == recording.facts?["error"]?.stringValue)

        // The library's stream throws it.
        let client = ModelClient(
            transport: ReplayTransport([recording]).transport, apiKeys: [target.provider: "test-key"],
            environment: [:], warningPolicy: .lenient,
        )
        let model = try client.model(try #require(recording.target), preferring: recording.wire.apiProtocol)
        do {
            for try await _ in model.stream("Hello") {}
            Issue.record("expected a stream error")
        } catch UnladenError.stream(let error) {
            #expect(error.message == recording.facts?["error"]?.stringValue)
        }
    }
}
