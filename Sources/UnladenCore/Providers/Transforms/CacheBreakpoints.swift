extension WireTransforms {
    /// Leaves out the prompt-cache breakpoints (``WireCacheControl``) beyond
    /// `max` (``Profile/maxCacheBreakpoints``; Anthropic rejects a request
    /// with more than four), one ``WireWarning/Code/droppedField`` warning
    /// each: a cache hint, never an error.
    ///
    /// Kept first, in order: breakpoints on tools, on the instructions, and
    /// on the leading `system`/`developer` messages (the stable prefix every
    /// later request shares); then the newest breakpoints of the
    /// conversation, so the oldest message breakpoints go. Breakpoints the
    /// wire model keeps in bags (a spelling it could not type) are neither
    /// counted nor touched. A request within the limit is unchanged.
    public static func limitCacheBreakpoints(_ request: inout WireRequest, max: Int, warnings: inout [WireWarning]) {
        enum Site {
            case tool(Int)
            case instruction(Int)
            /// A message part; `inner` is a part of a tool result's content.
            case part(message: Int, part: Int, inner: Int?)
        }
        func sites(_ parts: [WirePart], message: Int, newestFirst: Bool) -> [Site] {
            var found: [Site] = []
            for (p, part) in parts.enumerated() {
                var here: [Site] = []
                if case .toolResult(let result) = part {
                    for (k, inner) in result.content.enumerated() where inner.cacheControl != nil {
                        here.append(.part(message: message, part: p, inner: k))
                    }
                }
                if part.cacheControl != nil { here.append(.part(message: message, part: p, inner: nil)) }
                found += here
            }
            return newestFirst ? found.reversed() : found
        }

        var prefix: [Site] = []
        for (i, tool) in (request.tools ?? []).enumerated() {
            if case .function(let function) = tool, function.cacheControl != nil { prefix.append(.tool(i)) }
        }
        for (p, part) in (request.instructions ?? []).enumerated() where part.cacheControl != nil {
            prefix.append(.instruction(p))
        }
        let leading = request.messages.prefix { $0.role == .system || $0.role == .developer }.count
        for m in 0..<leading {
            prefix += sites(request.messages[m].parts, message: m, newestFirst: false)
        }
        var conversation: [Site] = []
        for m in (leading..<request.messages.count).reversed() {
            conversation += sites(request.messages[m].parts, message: m, newestFirst: true)
        }
        let all = prefix + conversation
        guard all.count > max else { return }

        let reason = "more than \(max) cache breakpoints; this one left out"
        for site in all.dropFirst(Swift.max(max, 0)) {
            switch site {
            case .tool(let i):
                guard case .function(var function)? = request.tools?[i] else { continue }
                function.cacheControl = nil
                request.tools?[i] = .function(function)
                warnings.append(WireWarning(.droppedField, reason, path: WirePath.key(WirePath.index("tools", i), WireCacheControl.key)))
            case .instruction(let p):
                request.instructions?[p].cacheControl = nil
                warnings.append(WireWarning(.droppedField, reason, path: WirePath.key(WirePath.index("instructions", p), WireCacheControl.key)))
            case .part(let m, let p, nil):
                request.messages[m].parts[p].cacheControl = nil
                let path = WirePath.index(WirePath.key(WirePath.index("messages", m), "content"), p)
                warnings.append(WireWarning(.droppedField, reason, path: WirePath.key(path, WireCacheControl.key)))
            case .part(let m, let p, let k?):
                guard case .toolResult(var result) = request.messages[m].parts[p] else { continue }
                result.content[k].cacheControl = nil
                request.messages[m].parts[p] = .toolResult(result)
                let path = WirePath.index(WirePath.key(WirePath.index(WirePath.key(WirePath.index("messages", m), "content"), p), "content"), k)
                warnings.append(WireWarning(.droppedField, reason, path: WirePath.key(path, WireCacheControl.key)))
            }
        }
    }
}
