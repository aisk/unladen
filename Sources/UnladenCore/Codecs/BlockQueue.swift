/// The content blocks of a reply, for a stream encoder whose protocol
/// writes one block at a time (Anthropic's and Responses' streams): events
/// of the block being written (the live one) go out at once; a block that
/// starts meanwhile waits, with its events, until the blocks before it end.
/// The encoder writes, and closes its live block; this decides when.
struct BlockQueue {
    /// What to do with a block event.
    enum Route: Equatable {
        /// Write it now.
        case write
        /// Kept for later (``next()``).
        case wait
        /// Nothing to write: a tool call whose input was streamed already.
        case skip
        /// An event of a block that never started.
        case orphan(String)
    }

    /// Blocks (or whole events, `id == nil`) waiting for the live block.
    private var waiting: [(id: String?, events: [WireEvent])] = []
    private var streamedTools: Set<String> = []

    /// Where `event` goes while `live` is the block being written (`nil`:
    /// none). Events that belong to no block are written.
    mutating func route(_ event: WireEvent, live: String?) -> Route {
        let free = live == nil && waiting.isEmpty
        switch event {
        case .textStart(let block, _), .reasoningStart(let block, _), .refusalStart(let block, _),
             .toolInputStart(let block, _):
            if case .toolInputStart = event { streamedTools.insert(block) }
            if free { return .write }
            waiting.append((block, [event]))
            return .wait

        case .textDelta(let block, _), .textEnd(let block, _), .reasoningDelta(let block, _),
             .reasoningSignatureDelta(let block, _), .reasoningEnd(let block, _), .refusalDelta(let block, _),
             .refusalEnd(let block, _), .toolInputDelta(let block, _), .toolInputEnd(let block):
            if live == block { return .write }
            guard let slot = waiting.firstIndex(where: { $0.id == block }) else { return .orphan(block) }
            waiting[slot].events.append(event)
            return .wait

        case .toolCall(let block, _) where streamedTools.contains(block):
            // Already streamed through tool-input events.
            return .skip

        case .toolCall, .opaque:
            if free { return .write }
            waiting.append((nil, [event]))
            return .wait

        default:
            return .write
        }
    }

    /// The events of the next waiting block (or whole event), removed.
    mutating func next() -> [WireEvent]? {
        waiting.isEmpty ? nil : waiting.removeFirst().events
    }
}
