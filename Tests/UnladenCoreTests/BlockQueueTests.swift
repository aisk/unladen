import Testing
@_spi(Wire) @testable import UnladenCore

@Suite struct BlockQueueTests {
    @Test func aBlockStartedMeanwhileWaitsWithItsEvents() {
        var queue = BlockQueue()
        let call = WireToolCall(id: "c", name: "f", arguments: "")
        #expect(queue.route(.textStart(id: "a", text: WireText("")), live: nil) == .write)
        #expect(queue.route(.toolInputStart(id: "b", call: call), live: "a") == .wait)
        #expect(queue.route(.toolInputDelta(id: "b", delta: "{}"), live: "a") == .wait)
        #expect(queue.route(.textDelta(id: "a", delta: "hi"), live: "a") == .write)
        #expect(queue.route(.textDelta(id: "z", delta: "?"), live: "a") == .orphan("z"))
        #expect(queue.next()?.count == 2)
        #expect(queue.next() == nil)
        // The call's input was streamed: its whole call adds nothing.
        #expect(queue.route(.toolCall(id: "b", call: call), live: nil) == .skip)
        #expect(queue.route(.toolCall(id: "d", call: call), live: nil) == .write)
    }
}
