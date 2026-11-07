extension WireTransforms {
    /// Leaves out the prompt-cache breakpoints (``WireCacheControl``) beyond
    /// `max` (``Profile/maxCacheBreakpoints``; Anthropic rejects a request
    /// with more than four), one ``WireWarning/Code/droppedField`` warning
    /// each: a cache hint, never an error.
    ///
    /// Counts what the encoder for `target` will write, and only that: on
    /// Anthropic every typed breakpoint (a tool result's inner ones moved
    /// onto the result first, see ``WireToolResult/hoistCacheControl()``);
    /// on Chat, when `chatCacheControl` (``ChatRequestOptions/cacheControl``)
    /// lets it write them, those on content parts, tool results and tools
    /// but not tool calls; on Responses and Gemini none. A `cache_control`
    /// kept in a bag (a spelling the wire model could not type, written back
    /// only to the same protocol) occupies a slot and is never touched: the
    /// typed ones get what is left, and a client request whose own spellings
    /// exceed `max` gets one ``WireWarning/Code/unsupportedValue`` cache hint
    /// and goes as written.
    ///
    /// Kept first, in order: breakpoints on tools, on the instructions, and
    /// on the leading `system`/`developer` messages (the stable prefix every
    /// later request shares); then the newest breakpoints of the
    /// conversation, so the oldest message breakpoints go. A request within
    /// the limit is unchanged.
    public static func limitCacheBreakpoints(
        _ request: inout WireRequest,
        max: Int,
        target: WireProtocol = .anthropicMessages,
        chatCacheControl: Bool? = nil,
        warnings: inout [WireWarning],
    ) {
        if target == .anthropicMessages, request.source != target {
            hoistToolResultCacheControl(&request, warnings: &warnings)
        }
        let sites = CacheSite.all(in: request, target: target, chatCacheControl: chatCacheControl)
        let kept = sites.filter(\.prefix) + sites.filter { !$0.prefix }.reversed()
        let bags = kept.filter { !$0.typed }
        let typed = kept.filter(\.typed)
        if bags.count > max {
            warnings.append(WireWarning(
                .unsupportedValue, "\(bags.count) cache breakpoints written as the client spelled them; the limit is \(max)",
                path: bags[Swift.max(max, 0)].path,
            ))
        }
        let budget = Swift.max(max - bags.count, 0)
        guard typed.count > budget else { return }
        let reason = "more than \(max) cache breakpoints; this one left out"
        for site in typed.dropFirst(budget) {
            site.location.set(nil, in: &request)
            warnings.append(WireWarning(.droppedField, reason, path: site.path))
        }
    }

    /// Raises the TTL of a breakpoint that a longer-lived one follows:
    /// Anthropic reads the prompt as tools, system, then messages, and
    /// rejects a `"1h"` breakpoint after a `"5m"` one (or one without a
    /// TTL, five minutes). Each raised breakpoint gets an
    /// ``WireWarning/Code/adjusted`` warning: the cache lives longer and
    /// costs more to write, nothing else changes.
    ///
    /// Only typed breakpoints the encoder for `target` writes are raised
    /// (see ``limitCacheBreakpoints(_:max:target:chatCacheControl:warnings:)``);
    /// bag-held ones still count as later breakpoints but keep their bytes.
    /// TTLs other than `"5m"` and `"1h"` are left alone and ignored.
    public static func raiseEarlierCacheTTLs(
        _ request: inout WireRequest,
        target: WireProtocol = .anthropicMessages,
        chatCacheControl: Bool? = nil,
        warnings: inout [WireWarning],
    ) {
        func rank(_ ttl: String?) -> Int? {
            switch ttl {
            case nil, "5m": 0
            case "1h": 1
            default: nil
            }
        }
        var longestLater = 0
        for site in CacheSite.all(in: request, target: target, chatCacheControl: chatCacheControl).reversed() {
            guard let rank = rank(site.ttl) else { continue }
            if site.typed, rank < longestLater, var cache = site.location.get(in: request) {
                let old = cache.ttl ?? "5m"
                cache.ttl = "1h"
                site.location.set(cache, in: &request)
                warnings.append(WireWarning(.adjusted, "cache TTL \(old) raised to 1h: a 1h breakpoint follows it", path: site.path))
            }
            longestLater = Swift.max(longestLater, rank)
        }
    }

    /// Moves every tool result's inner breakpoints onto the result
    /// (``WireToolResult/hoistCacheControl()``), with a cache-hint warning
    /// for each one that merged into another.
    static func hoistToolResultCacheControl(_ request: inout WireRequest, warnings: inout [WireWarning]) {
        for m in request.messages.indices {
            for p in request.messages[m].parts.indices {
                guard case .toolResult(var result) = request.messages[m].parts[p] else { continue }
                let collapsed = result.hoistCacheControl()
                request.messages[m].parts[p] = .toolResult(result)
                let contentPath = WirePath.key(WirePath.index(WirePath.key(WirePath.index("messages", m), "content"), p), "content")
                for k in collapsed {
                    dropCacheControl(
                        WireCacheControl(), path: WirePath.index(contentPath, k),
                        reason: "a tool result carries one breakpoint", warnings: &warnings,
                    )
                }
            }
        }
    }
}

/// One `cache_control` the encoder for a target will write.
private struct CacheSite {
    enum Container {
        case instructions
        case message(Int)
    }

    enum Location {
        case tool(Int)
        /// A part; `inner` is a part of a tool result's content.
        case part(Container, part: Int, inner: Int?)

        func get(in request: WireRequest) -> WireCacheControl? {
            switch self {
            case .tool(let i):
                guard case .function(let function)? = request.tools?[i] else { return nil }
                return function.cacheControl
            case .part(let container, let p, let inner):
                let part = switch container {
                case .instructions: request.instructions?[p]
                case .message(let m): request.messages[m].parts[p]
                }
                guard let part else { return nil }
                guard let k = inner else { return part.cacheControl }
                guard case .toolResult(let result) = part else { return nil }
                return result.content[k].cacheControl
            }
        }

        func set(_ cache: WireCacheControl?, in request: inout WireRequest) {
            switch self {
            case .tool(let i):
                guard case .function(var function)? = request.tools?[i] else { return }
                function.cacheControl = cache
                request.tools?[i] = .function(function)
            case .part(let container, let p, let inner):
                func update(_ part: inout WirePart) {
                    guard let k = inner else { part.cacheControl = cache; return }
                    guard case .toolResult(var result) = part else { return }
                    result.content[k].cacheControl = cache
                    part = .toolResult(result)
                }
                switch container {
                case .instructions:
                    if request.instructions != nil { update(&request.instructions![p]) }
                case .message(let m):
                    update(&request.messages[m].parts[p])
                }
            }
        }

        var path: String {
            switch self {
            case .tool(let i):
                return WirePath.key(WirePath.index("tools", i), WireCacheControl.key)
            case .part(let container, let p, let inner):
                var path = switch container {
                case .instructions: WirePath.index("instructions", p)
                case .message(let m): WirePath.index(WirePath.key(WirePath.index("messages", m), "content"), p)
                }
                if let k = inner { path = WirePath.index(WirePath.key(path, "content"), k) }
                return WirePath.key(path, WireCacheControl.key)
            }
        }
    }

    var location: Location
    /// A typed breakpoint (``WireCacheControl``); otherwise a bag's.
    var typed: Bool
    var ttl: String?
    /// On a tool, the instructions or a leading system message.
    var prefix: Bool

    var path: String { location.path }

    /// Every site in prompt order: tools, instructions, then messages, a
    /// tool result's content before the result.
    static func all(in request: WireRequest, target: WireProtocol, chatCacheControl: Bool?) -> [CacheSite] {
        let include = request.source == target
        let writesTyped = switch target {
        case .anthropicMessages: true
        case .chatCompletions: chatCacheControl ?? include
        case .responses, .gemini: false
        }
        func bagCache(_ bag: JSONObject) -> JSONValue? {
            include ? bag[WireCacheControl.key] : nil
        }
        func ttl(of value: JSONValue) -> String? {
            value["ttl"]?.stringValue
        }

        var sites: [CacheSite] = []
        for (i, tool) in (request.tools ?? []).enumerated() {
            switch tool {
            case .function(let function):
                if let value = bagCache(function.extra) ?? bagCache(function.envelopeExtra) {
                    sites.append(CacheSite(location: .tool(i), typed: false, ttl: ttl(of: value), prefix: true))
                } else if writesTyped, let cache = function.cacheControl {
                    sites.append(CacheSite(location: .tool(i), typed: true, ttl: cache.ttl, prefix: true))
                }
            case .opaque(let opaque):
                if include, opaque.protocol == target, let value = opaque.value[WireCacheControl.key] {
                    sites.append(CacheSite(location: .tool(i), typed: false, ttl: ttl(of: value), prefix: true))
                }
            }
        }

        /// The site of one part that is not a tool result.
        func site(_ part: WirePart, at location: Location, prefix: Bool) -> CacheSite? {
            let bag: JSONObject? = switch part {
            case .text(let value): value.extra
            case .image(let value), .file(let value): value.extra
            case .toolCall(let value): value.extra
            case .toolResult(let value): value.extra
            case .reasoning(let value): target == .anthropicMessages ? value.extra : nil
            case .refusal: nil
            case .opaque(let opaque): opaque.protocol == target ? opaque.value.objectValue : nil
            }
            if let bag, let value = bagCache(bag) {
                return CacheSite(location: location, typed: false, ttl: ttl(of: value), prefix: prefix)
            }
            guard writesTyped, let cache = part.cacheControl else { return nil }
            if target == .chatCompletions, case .toolCall = part { return nil }
            return CacheSite(location: location, typed: true, ttl: cache.ttl, prefix: prefix)
        }

        func parts(_ parts: [WirePart], in container: Container, prefix: Bool) {
            for (p, part) in parts.enumerated() {
                guard case .toolResult(let result) = part else {
                    if let site = site(part, at: .part(container, part: p, inner: nil), prefix: prefix) { sites.append(site) }
                    continue
                }
                for (k, inner) in result.content.enumerated() {
                    if let site = site(inner, at: .part(container, part: p, inner: k), prefix: prefix) { sites.append(site) }
                }
                let location = Location.part(container, part: p, inner: nil)
                guard target == .chatCompletions else {
                    if let site = site(part, at: location, prefix: prefix) { sites.append(site) }
                    continue
                }
                // Chat: the result's breakpoint goes on its message's last
                // part, unless that part already has one; the result's bag
                // is the tool message's.
                if let value = bagCache(result.extra) {
                    sites.append(CacheSite(location: location, typed: false, ttl: ttl(of: value), prefix: prefix))
                }
                if writesTyped, let cache = result.cacheControl {
                    let last = result.content.indices.last
                    let lastMarked = last.map { k in sites.contains { $0.location.matches(container, p, k) } } ?? false
                    if !lastMarked {
                        sites.append(CacheSite(location: location, typed: true, ttl: cache.ttl, prefix: prefix))
                    }
                }
            }
        }

        if let instructions = request.instructions {
            parts(instructions, in: .instructions, prefix: true)
        }
        let leading = request.messages.prefix { $0.role == .system || $0.role == .developer }.count
        for (m, message) in request.messages.enumerated() {
            parts(message.parts, in: .message(m), prefix: m < leading)
        }
        return sites
    }
}

private extension CacheSite.Location {
    func matches(_ container: CacheSite.Container, _ p: Int, _ k: Int) -> Bool {
        guard case .part(let c, let part, let inner?) = self, part == p, inner == k else { return false }
        switch (c, container) {
        case (.instructions, .instructions): return true
        case (.message(let a), .message(let b)): return a == b
        default: return false
        }
    }
}
