@_spi(Wire) import UnladenCore

/// A prompt-cache breakpoint: the provider may cache the prompt up to and
/// including what carries it, so a later request with the same prefix
/// reads it from the cache.
///
/// Set one on a ``Message`` (it goes on the message's last part that can
/// carry one), on a single part (``ContentPart/cached(ttl:)``), or on a
/// ``Tool`` (caches the tool definitions up to it). For the system prompt,
/// mark the ``Role/system`` message.
///
/// ```swift
/// let history: [Message] = [
///     Message.system(longInstructions).cached(ttl: .oneHour),
///     .user([.text(contract).cached(), .text("Summarise clause 4.")]),
/// ]
/// let tools = [Tool(name: "search", inputSchema: schema).cached()]
/// ```
///
/// Where it is honoured:
/// - Anthropic Messages: `cache_control: {"type": "ephemeral"[, "ttl": …]}`
///   on the block (text, image, document, tool use, tool result), the
///   `system` block or the tool.
/// - Chat Completions, when the model's Profile says the upstream honours
///   breakpoints (``Profile/chatCacheControl``: OpenRouter and other relays
///   serving Claude): `cache_control` on the content part, on the last part
///   of a tool result's `tool` message, or on the tool. A breakpoint on a
///   tool call has no place in Chat.
/// - Responses, Gemini and other Chat upstreams: no per-block breakpoint
///   (caching is automatic, or uses Gemini's `cachedContent`). The
///   breakpoint is dropped with a ``CallWarning/Code/droppedField`` warning
///   whose path ends in `cache_control`: a cache hint
///   (``CallWarning/isCacheHint``), reported but never an error, since a
///   lost hint costs money, not correctness.
///
/// **Limit.** Claude takes at most four breakpoints per request
/// (``Profile/maxCacheBreakpoints``). More are trimmed, not sent to fail:
/// the breakpoints on tools and leading system messages are kept first, then
/// the newest ones; each one left out is reported as a cache hint.
/// Claude also requires 1-hour entries to come before 5-minute ones, in
/// prompt order (tools, system, messages): a shorter TTL that a 1-hour
/// breakpoint follows is raised to one hour, reported as a
/// ``CallWarning/Code/adjusted`` warning.
///
/// **Tool results.** A breakpoint on a part of ``ToolResult/output`` marks
/// the whole result (Anthropic's `tool_result` block; on Chat, the last part
/// of its `tool` message).
public struct CacheBreakpoint: Hashable, Sendable, Codable {
    /// How long the cache entry lives.
    public struct TTL: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral, Codable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.rawValue = value }

        /// Anthropic's default.
        public static let fiveMinutes: TTL = "5m"
        /// Anthropic's extended lifetime (priced higher to write).
        public static let oneHour: TTL = "1h"

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    /// `nil` sends no TTL: the provider's default (five minutes).
    public var ttl: TTL?

    public init(ttl: TTL? = nil) {
        self.ttl = ttl
    }

    var wire: WireCacheControl { WireCacheControl(ttl: ttl?.rawValue) }
}

/// Per-part settings: a cache breakpoint and raw provider options. Attach
/// them with ``ContentPart/cached(ttl:)`` or
/// ``ContentPart/withProviderOptions(_:)``.
public struct PartOptions: Hashable, Sendable {
    public var cache: CacheBreakpoint?
    /// Raw JSON merged into the part's object (see ``ProviderOptions``).
    public var providerOptions: ProviderOptions

    public init(cache: CacheBreakpoint? = nil, providerOptions: ProviderOptions = [:]) {
        self.cache = cache
        self.providerOptions = providerOptions
    }

    public var isEmpty: Bool { cache == nil && providerOptions.isEmpty }

    /// `other` over `self`: its breakpoint if it has one, its options merged
    /// over these key by key.
    func merging(_ other: PartOptions) -> PartOptions {
        var merged = self
        merged.cache = other.cache ?? cache
        for (key, value) in other.providerOptions.entries {
            merged.providerOptions[key] = WirePatch.overlay(value, on: providerOptions[key] ?? [:])
        }
        return merged
    }
}

extension ContentPart {
    /// The part without its ``PartOptions``.
    public var base: ContentPart {
        if case .annotated(let part, _) = self { return part.base }
        return self
    }

    /// The part's options; empty for a plain part.
    public var options: PartOptions {
        if case .annotated(let part, let options) = self { return part.options.merging(options) }
        return PartOptions()
    }

    /// The part with `options` merged over its own (a plain part when the
    /// result is empty).
    public func with(_ options: PartOptions) -> ContentPart {
        let merged = self.options.merging(options)
        return merged.isEmpty ? base : .annotated(base, merged)
    }

    /// The part as a prompt-cache breakpoint (see ``CacheBreakpoint``).
    public func cached(ttl: CacheBreakpoint.TTL? = nil) -> ContentPart {
        with(PartOptions(cache: CacheBreakpoint(ttl: ttl)))
    }

    /// The part with raw JSON for its object in the request (see
    /// ``ProviderOptions``): `["anthropic": ["citations": ["enabled": true]]]`
    /// on a document, say.
    public func withProviderOptions(_ providerOptions: ProviderOptions) -> ContentPart {
        with(PartOptions(providerOptions: providerOptions))
    }
}

extension Message {
    /// The message as a prompt-cache breakpoint: its last part that can
    /// carry one is marked (see ``CacheBreakpoint``).
    public func cached(ttl: CacheBreakpoint.TTL? = nil) -> Message {
        var message = self
        message.cache = CacheBreakpoint(ttl: ttl)
        return message
    }
}

extension Tool {
    /// The tool as a prompt-cache breakpoint: the definitions up to and
    /// including it are cached (see ``CacheBreakpoint``).
    public func cached(ttl: CacheBreakpoint.TTL? = nil) -> Tool {
        var tool = self
        tool.cache = CacheBreakpoint(ttl: ttl)
        return tool
    }
}
