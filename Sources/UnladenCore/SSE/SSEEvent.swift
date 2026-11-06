/// A dispatched server-sent event.
public struct SSEEvent: Hashable, Sendable {
    /// The `event` field of this event's block, or `nil` if it had none
    /// (which EventSource treats as `"message"`).
    public var event: String?
    /// The `data` lines joined with `"\n"`. May be empty (`data:` alone).
    public var data: String
    /// The `id` field set in this event's block, or `nil` if it had none.
    ///
    /// Unlike EventSource's `lastEventId`, this does not inherit an id from an
    /// earlier block; ``SSEParser/lastEventID`` tracks that.
    public var id: String?

    public init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// One item produced by the SSE parser.
public enum SSEElement: Hashable, Sendable {
    /// A complete event, emitted at the blank line that terminates its block.
    case event(SSEEvent)
    /// A comment line (`: ping`), emitted as soon as the line is complete,
    /// i.e. before any event whose block it appears in. The text is
    /// everything after the colon, with one leading space removed.
    /// EventSource ignores comments; the gateway treats them as keepalives.
    case comment(String)
    /// A valid `retry` field (ASCII digits only), emitted as soon as the line
    /// is complete. EventSource applies it immediately, independent of events.
    case retry(Int)
}
