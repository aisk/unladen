import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import NIOPosix
import Testing
@_spi(Wire) import UnladenCore
@testable import UnladenServer

/// A raw HTTP/1.1 client: sends one request and can hang up at any time.
private struct RawConnection {
    let channel: any Channel

    static func open(port: Int) async throws -> RawConnection {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "localhost", port: port).get()
        return RawConnection(channel: channel)
    }

    func send(_ path: String, _ body: String) async throws {
        let head = "POST \(path) HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        try await channel.writeAndFlush(ByteBuffer(string: head + body)).get()
    }

    func hangUp() async throws {
        try await channel.close().get()
    }
}

/// Client disconnects must cancel the upstream request: Hummingbird does
/// not cancel route handlers by itself (see `DisconnectMonitor`).
@Suite struct DisconnectTests {
    @Test func beforeTheResponseHead() async throws {
        let started = Flag()
        let cancelled = Flag()
        let upstream = MockUpstream { _ in
            started.set()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.set()
                throw error
            }
            return reply("{}")
        }
        try await makeApp(makeGateway(upstream)).test(.live) { client in
            let connection = try await RawConnection.open(port: try #require(client.port))
            try await connection.send("/v1/chat/completions", ClientRequest.chat(model: "x"))
            #expect(await started.wait())
            try await connection.hangUp()
            #expect(await cancelled.wait())
        }
    }

    @Test func midStream() async throws {
        let cancelled = Flag()
        let streaming = Flag()
        let upstream = MockUpstream { _ in
            reply(streaming: AsyncStream { continuation in
                continuation.yield(Array(fixtureHead.utf8))
                continuation.onTermination = { _ in cancelled.set() }
                streaming.set()
            })
        }
        try await makeApp(makeGateway(upstream, model: "anthropic/claude-sonnet-4-5")).test(.live) { client in
            let connection = try await RawConnection.open(port: try #require(client.port))
            try await connection.send("/v1/messages", ClientRequest.anthropic(model: "x", stream: true))
            #expect(await streaming.wait())
            try await Task.sleep(for: .milliseconds(100))
            #expect(!cancelled.isSet)
            try await connection.hangUp()
            #expect(await cancelled.wait())
        }
    }

    /// The same request without a hang-up completes normally (the monitor
    /// does not fire on a healthy keep-alive connection).
    @Test func healthyConnectionsAreNotCancelled() async throws {
        let upstream = MockUpstream { _ in
            try await Task.sleep(for: .milliseconds(200))
            return reply(fixture("Chat/responses/text.json"))
        }
        try await makeApp(makeGateway(upstream)).test(.live) { client in
            for _ in 0..<2 {
                let response = try await client.post("/v1/chat/completions", ClientRequest.chat(model: "x"))
                #expect(response.status == .ok)
            }
        }
    }
}

private let fixtureHead = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}


"""
