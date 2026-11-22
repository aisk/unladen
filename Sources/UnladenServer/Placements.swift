// Keeping a long conversation on the target that holds its prompt cache.
//
// A route's later targets are other models, often at other providers: a
// conversation moved there pays for its whole context again, uncached.
// Past `fallback_max_context`, a conversation under way stays on the
// target that last answered it (else the route's first), and a failure
// there goes back to the client, which retries it, instead of moving on.
//
// Its context is the input its upstream reported for the last turn, plus
// an estimate of what was added since; without a report, an estimate of
// the whole. A conversation whose cache has gone cold has nothing to lose
// and moves on as any other.

import NIOConcurrencyHelpers
@_spi(Wire) import UnladenCore

/// The target that last answered a conversation.
struct Placement: Sendable, Equatable {
    var reference: String
    /// When it last answered: the first content, then the end of the reply.
    var at: ContinuousClock.Instant
    /// The estimated context of the request it answered; `nil` when the
    /// route set no limit and nothing was estimated.
    var estimate: Int?
    /// The input tokens its upstream reported for that request (cached
    /// ones included); `nil` until the reply ends, or when it reports none.
    var reportedInput: Int?
    /// The request it answered (``Placements/Ticket/request``).
    var request = 0
    /// How long its prompt cache lives unread
    /// (``ConversationContext/cacheLifetime(_:at:)``).
    var lifetime: Duration = .seconds(300)
}

/// The target that last answered each conversation.
final class Placements: Sendable {
    /// One request's hold on its conversation's placement: what it writes
    /// when it is answered, and when its reply ends.
    struct Ticket: Sendable, Hashable {
        var conversation: String
        var request: Int
    }

    /// How long a placement is kept: well past the longest a prompt cache
    /// is assumed to live, so that one gone cold is known as such, and long
    /// enough that a conversation taken up again days later is still known
    /// (its sealed reasoning only the target that wrote it reads).
    static let retention: Duration = .seconds(30 * 24 * 3600)
    /// How many conversations are kept.
    static let limit = 4096

    private struct State {
        var placements: [String: Placement] = [:]
        var next = 1
    }

    private let state = NIOLockedValueBox(State())

    init() {}

    /// How a conversation is told apart: its session, its subagent, and the
    /// model name it asks for (a session asks for a small model too). `nil`
    /// when the request names no session.
    static func conversation(_ origin: RequestOrigin, model: String) -> String? {
        guard let session = origin.session else { return nil }
        return [session, origin.subagent ?? "", model.lowercased()].joined(separator: "\u{0}")
    }

    /// A ticket for a new request of `conversation`.
    func ticket(for conversation: String) -> Ticket {
        state.withLockedValue { state in
            defer { state.next += 1 }
            return Ticket(conversation: conversation, request: state.next)
        }
    }

    /// Where `conversation` was last answered, within ``retention``.
    func placement(for conversation: String, now: ContinuousClock.Instant = .now) -> Placement? {
        state.withLockedValue { state in
            guard let placement = state.placements[conversation], placement.at + Self.retention > now else { return nil }
            return placement
        }
    }

    /// The conversations of `session` and where each was last answered,
    /// within ``retention``.
    func placements(ofSession session: String) -> [(subagent: String?, model: String, placement: Placement)] {
        let now = ContinuousClock.now
        let prefix = session + "\u{0}"
        return state.withLockedValue { state in
            state.placements.compactMap { key, placement in
                guard key.hasPrefix(prefix), placement.at + Self.retention > now else { return nil }
                let parts = key.dropFirst(prefix.count).split(separator: "\u{0}", omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                return (parts[0].isEmpty ? nil : String(parts[0]), String(parts[1]), placement)
            }
        }
    }

    /// `reference` has begun answering `ticket`'s request, estimated at
    /// `estimate` tokens; its prompt cache lives `lifetime` unread.
    func answering(_ reference: String, estimate: Int?, lifetime: Duration = .seconds(300), for ticket: Ticket) {
        let now = ContinuousClock.now
        state.withLockedValue { state in
            state.placements[ticket.conversation] = Placement(
                reference: reference, at: now, estimate: estimate, request: ticket.request, lifetime: lifetime,
            )
            guard state.placements.count > Self.limit else { return }
            state.placements = state.placements.filter { $0.value.at + Self.retention > now }
            if state.placements.count > Self.limit {
                let oldest = state.placements.sorted { $0.value.at < $1.value.at }.prefix(state.placements.count - Self.limit)
                for (key, _) in oldest { state.placements.removeValue(forKey: key) }
            }
        }
    }

    /// `ticket`'s reply has ended, its upstream reporting `input` tokens.
    /// Ignored when a later request of the conversation has been answered
    /// since: its input belongs with that request's estimate.
    func answered(_ ticket: Ticket, input: Int?) {
        let now = ContinuousClock.now
        state.withLockedValue { state in
            guard var placement = state.placements[ticket.conversation], placement.request == ticket.request else { return }
            placement.at = now
            if let input, input > 0 { placement.reportedInput = input }
            state.placements[ticket.conversation] = placement
        }
    }
}

/// A conversation kept on one target: it carries more context than
/// `fallback_max_context`.
struct KeptPlace: Sendable, Equatable {
    /// The target it stays on.
    var reference: String
    /// Its context, in tokens.
    var context: Int
    /// What the upstream reported of it for the last turn; `nil`: all of
    /// `context` is estimated.
    var reported: Int?
    var limit: Int
    /// It builds on a reply the upstream keeps (`previous_response_id`),
    /// whose context the request does not carry.
    var storedReply: Bool

    /// Why no other target was tried, for the log.
    var note: String {
        let size: String
        if storedReply {
            size = "builds on a reply its upstream keeps"
        } else if let reported {
            size = "carries about \(context) tokens of context (\(reported) reported for the last turn, the rest estimated)"
        } else {
            size = "carries about \(context) tokens of context (estimated)"
        }
        return "not falling back to another target: the conversation \(size), over fallback_max_context \(limit); kept on \(reference)"
    }

    /// Whether `request` stays on one of `candidates`' targets, and which:
    /// the one that last answered the conversation (`placement`) when it
    /// is still a candidate, else the first.
    ///
    /// Not kept: a new conversation, and one whose cache at its target has
    /// gone cold (``ConversationContext/cacheLifetime(_:at:)``),
    /// which have nothing to lose; nor one that builds on a stored reply
    /// without a placement, as which target keeps that reply is not known.
    /// `estimate` is ``ConversationContext/estimatedTokens(_:)`` of `request`.
    static func keep(
        _ request: WireRequest, estimate: Int, candidates: [Candidate], limit: Int?, placement: Placement?,
        now: ContinuousClock.Instant = .now,
    ) -> KeptPlace? {
        guard let limit, let first = candidates.first,
              candidates.contains(where: { $0.reference != first.reference }),
              ConversationContext.continues(request)
        else { return nil }
        let storedReply = ConversationContext.buildsOnStoredReply(request)
        // A place that is no candidate any more is no place.
        let placed = placement.flatMap { placement in
            candidates.first { $0.reference == placement.reference }.map { (placement, $0.target) }
        }
        if storedReply, placed == nil { return nil }
        if !storedReply, let (placement, target) = placed,
           placement.at + ConversationContext.cacheLifetime(request, at: target) < now
        {
            return nil
        }
        var context = estimate
        var reported: Int?
        if let placement = placed?.0, let input = placement.reportedInput, let before = placement.estimate {
            // What the upstream counted, and what was added since.
            reported = input
            context = max(input + estimate - before, 0)
        }
        guard storedReply || context > limit else { return nil }
        return KeptPlace(
            reference: placed?.0.reference ?? first.reference, context: context, reported: reported, limit: limit,
            storedReply: storedReply,
        )
    }
}

// MARK: - Context

/// What a request carries of its conversation.
enum ConversationContext {
    /// Whether `request` goes on with a conversation: it carries an earlier
    /// turn of the model (an assistant message, a tool call or result,
    /// reasoning), or builds on a reply the upstream keeps.
    static func continues(_ request: WireRequest) -> Bool {
        if buildsOnStoredReply(request) { return true }
        return request.messages.contains { message in
            message.role == .assistant || message.parts.contains { part in
                switch part {
                case .toolCall, .toolResult, .reasoning: true
                default: false
                }
            }
        }
    }

    /// A Responses request that continues a stored reply
    /// (`previous_response_id`) or conversation (`conversation`).
    static func buildsOnStoredReply(_ request: WireRequest) -> Bool {
        ["previous_response_id", "conversation"].contains { key in
            if let value = request.extra[key], !value.isNull { true } else { false }
        }
    }

    /// The tokens of context `request` carries, estimated without a
    /// tokenizer: a token for every four bytes of ASCII and for every other
    /// character, a fixed amount for each image or file.
    static func estimatedTokens(_ request: WireRequest) -> Int {
        var tokens = estimatedTokens(request.instructions ?? [])
        for message in request.messages { tokens += estimatedTokens(message.parts) }
        for tool in request.tools ?? [] {
            switch tool {
            case .function(let function):
                tokens += estimatedTokens(function.name) + estimatedTokens(function.description ?? "")
                if let parameters = function.parameters { tokens += estimatedTokens(parameters.encoded()) }
            case .opaque(let opaque):
                tokens += estimatedTokens(opaque.value.encoded())
            }
        }
        return tokens
    }

    /// What an image or a file is counted as.
    static let mediaTokens = 1000

    /// How long a prompt cache lives unread: five minutes by default (Anthropic's
    /// and OpenAI's); an hour when the request asks for it (a `cache_control`
    /// `ttl` of `1h`, or a longer `prompt_cache_retention`) and at the
    /// targets that ``cachesForAnHour(_:)``.
    static func cacheLifetime(_ request: WireRequest, at target: ResolvedModel) -> Duration {
        if cachesForAnHour(target) || asksForLongCache(request) { return .seconds(3600) }
        return .seconds(300)
    }

    /// Whether `target` keeps a conversation's prefix cached for an hour or
    /// more unread: the ChatGPT backend a ChatGPT sign-in uses, and
    /// DeepSeek, whose guide speaks of hours to days, under whatever name
    /// a provider calls it (its endpoints, or its host).
    static func cachesForAnHour(_ target: ResolvedModel) -> Bool {
        target.provider == "chatgpt" || target.endpoint.system == "deepseek"
            || QuotaReader.host(of: target.endpoint.baseURL) == "api.deepseek.com"
    }

    static func asksForLongCache(_ request: WireRequest) -> Bool {
        if let retention = request.extra["prompt_cache_retention"]?.stringValue, retention != "in_memory" { return true }
        func long(_ control: WireCacheControl?) -> Bool { control?.ttl == "1h" }
        func long(_ parts: [WirePart]) -> Bool {
            parts.contains { part in
                switch part {
                case .text(let text): long(text.cacheControl)
                case .image(let media), .file(let media): long(media.cacheControl)
                case .toolCall(let call): long(call.cacheControl)
                case .toolResult(let result): long(result.cacheControl) || long(result.content)
                default: false
                }
            }
        }
        if long(request.instructions ?? []) || request.messages.contains(where: { long($0.parts) }) { return true }
        return (request.tools ?? []).contains { tool in
            if case .function(let function) = tool { long(function.cacheControl) } else { false }
        }
    }

    static func estimatedTokens(_ parts: [WirePart]) -> Int {
        var tokens = 0
        for part in parts {
            switch part {
            case .text(let text): tokens += estimatedTokens(text.text)
            case .image, .file: tokens += mediaTokens
            case .reasoning(let reasoning):
                tokens += estimatedTokens(reasoning.text) + estimatedTokens(reasoning.encrypted ?? "")
            case .toolCall(let call): tokens += estimatedTokens(call.name) + estimatedTokens(call.arguments)
            case .toolResult(let result): tokens += estimatedTokens(result.content)
            case .refusal(let refusal): tokens += estimatedTokens(refusal.text)
            case .opaque(let opaque): tokens += estimatedTokens(opaque.value.encoded())
            }
        }
        return tokens
    }

    static func estimatedTokens(_ text: String) -> Int {
        estimatedTokens(text.utf8)
    }

    static func estimatedTokens(_ bytes: some Sequence<UInt8>) -> Int {
        var ascii = 0
        var other = 0
        for byte in bytes {
            if byte < 0x80 {
                ascii += 1
            } else if byte & 0xC0 != 0x80 {
                // The first byte of a character outside ASCII.
                other += 1
            }
        }
        return (ascii + 3) / 4 + other
    }
}
