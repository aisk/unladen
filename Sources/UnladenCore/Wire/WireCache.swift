/// A prompt-cache breakpoint: the provider may cache the prompt up to and
/// including the block that carries it (Anthropic `cache_control`).
///
/// A first-class field rather than a bag key, so a breakpoint survives a
/// change of protocol: an Anthropic client's `cache_control` reaches a Chat
/// upstream that honours it (OpenRouter or another relay serving Claude),
/// and a Chat client's reaches Anthropic. Where it lives:
/// ``WireText``, ``WireMedia``, ``WireToolCall``, ``WireToolResult`` and
/// ``WireFunctionTool``.
///
/// **Decoding.** The Anthropic and Chat decoders lift a `cache_control`
/// value into this field only when writing the field back reproduces it
/// exactly: `{"type":"ephemeral"}` or `{"type":"ephemeral","ttl":"…"}`, in
/// that key order, and no unknown key after it in its object (encoders
/// write the field after the object's bag). Any other spelling stays in the
/// bag, where it goes back to the same protocol as before and is dropped
/// elsewhere.
///
/// **Encoding.** Anthropic writes it on the block or tool; Chat on the
/// content part (a tool result's on the last part of its `tool` message)
/// or on the tool's envelope, when ``ChatRequestOptions/cacheControl``
/// allows it; Responses and Gemini have no per-block breakpoint (caching is
/// automatic, or uses `cachedContent`) and drop it with a
/// ``WireWarning/Code/droppedField`` warning whose path ends in
/// `cache_control`, a cache hint (``WireWarning/isCacheHint``).
@_spi(Wire) public struct WireCacheControl: Hashable, Sendable {
    /// The cache lifetime (`"5m"`, `"1h"`); `nil` is the provider's
    /// default (five minutes).
    public var ttl: String?

    public init(ttl: String? = nil) {
        self.ttl = ttl
    }

    /// The JSON key every protocol that has one uses.
    public static let key = "cache_control"

    /// `{"type":"ephemeral"[,"ttl":…]}`.
    public var json: JSONValue {
        var object: JSONObject = ["type": "ephemeral"]
        if let ttl { object["ttl"] = .string(ttl) }
        return .object(object)
    }

    /// The breakpoint `value` spells, or `nil` if ``json`` would not
    /// reproduce it exactly.
    public init?(json value: JSONValue) {
        guard case .object(let object) = value, object["type"] == "ephemeral" else { return nil }
        switch object.count {
        case 1:
            self.init()
        case 2:
            guard object.keys == ["type", "ttl"], case .string(let ttl)? = object["ttl"] else { return nil }
            self.init(ttl: ttl)
        default:
            return nil
        }
    }

    /// Moves `bag`'s `cache_control` into a breakpoint when it can be
    /// written back exactly (see the type's documentation).
    static func lift(from bag: inout JSONObject) -> WireCacheControl? {
        guard let index = bag.index(forKey: key), index == bag.count - 1,
              let cache = WireCacheControl(json: bag.values[index])
        else { return nil }
        bag[key] = nil
        return cache
    }
}

/// Caller-supplied JSON deep-merged over one object an encoder writes: the
/// library's message-, part- and tool-level provider options, already
/// resolved for the target endpoint. Decoders never produce one.
///
/// Only an encoder for ``protocol`` applies it, last, so it wins over
/// everything the encoder wrote: objects merge key by key, anything else
/// replaces, and `null` removes the key. Other encoders ignore it. Where a
/// target writes no object for the element (Chat reasoning and refusals are
/// message fields; an Anthropic `system` message is not a turn), the patch
/// is dropped with a ``WireWarning/Code/droppedField`` warning.
@_spi(Wire) public struct WirePatch: Hashable, Sendable {
    public var `protocol`: WireProtocol
    public var object: JSONObject

    public init(protocol: WireProtocol, object: JSONObject) {
        self.protocol = `protocol`
        self.object = object
    }

    /// `object` with the patch merged over it.
    public func apply(to object: inout JSONObject) {
        object = Self.merge(self.object, over: object)
    }

    /// `patch` over `base` (see the type's documentation).
    public static func merge(_ patch: JSONObject, over base: JSONObject) -> JSONObject {
        var object = base
        for (key, value) in patch {
            switch value {
            case .null:
                object.removeValue(forKey: key)
            case .object(let inner):
                object[key] = .object(merge(inner, over: object[key]?.objectValue ?? [:]))
            default:
                object[key] = value
            }
        }
        return object
    }

    /// `first` and then `second` as one patch (a later message's over an
    /// earlier one's, when an encoder joins them into one object).
    public static func combined(_ first: WirePatch?, _ second: WirePatch?) -> WirePatch? {
        guard let first else { return second }
        guard let second else { return first }
        guard first.protocol == second.protocol else { return first }
        return WirePatch(protocol: first.protocol, object: overlay(second.object, on: first.object))
    }

    /// Two patches as one: objects merge key by key, anything else
    /// (`null` included, which must still remove its key) replaces.
    public static func overlay(_ later: JSONObject, on earlier: JSONObject) -> JSONObject {
        var object = earlier
        for (key, value) in later {
            if case .object(let inner) = value, case .object(let base)? = object[key] {
                object[key] = .object(overlay(inner, on: base))
            } else {
                object[key] = value
            }
        }
        return object
    }
}

// MARK: - Encoder helpers

/// Applies `patch` to `object` when it is for `target`.
func applyPatch(_ patch: WirePatch?, to object: inout JSONObject, target: WireProtocol) {
    guard let patch, patch.protocol == target else { return }
    patch.apply(to: &object)
}

/// `true` if `patch` is for `target` (an encoder must then write an object
/// it can go into).
func hasPatch(_ patch: WirePatch?, for target: WireProtocol) -> Bool {
    patch?.protocol == target
}

/// Warns that a patch for `target` has no object to go into there.
func dropPatch(_ patch: WirePatch?, target: WireProtocol, path: String, warnings: inout [WireWarning]) {
    guard let patch, patch.protocol == target, !patch.object.isEmpty else { return }
    warnings.append(WireWarning(.droppedField, "provider options have no object to go into here", path: path))
}

/// Writes `cache` as `cache_control` when `allowed`, after the object's
/// bag (a bag's own `cache_control` wins); otherwise warns that the
/// breakpoint was dropped (a cache hint: never an error).
func writeCacheControl(
    _ cache: WireCacheControl?,
    to object: inout JSONObject,
    allowed: Bool,
    path: String,
    reason: @autoclosure () -> String,
    warnings: inout [WireWarning],
) {
    guard let cache else { return }
    if allowed {
        if !object.contains(key: WireCacheControl.key) { object[WireCacheControl.key] = cache.json }
    } else {
        dropCacheControl(cache, path: path, reason: reason(), warnings: &warnings)
    }
}

/// Warns that the breakpoint at `path` was dropped.
func dropCacheControl(_ cache: WireCacheControl?, path: String, reason: String, warnings: inout [WireWarning]) {
    guard cache != nil else { return }
    warnings.append(WireWarning(.droppedField, "cache breakpoint dropped: \(reason)", path: WirePath.key(path, WireCacheControl.key)))
}

extension WirePart {
    /// The part's prompt-cache breakpoint, for the kinds that have one.
    public var cacheControl: WireCacheControl? {
        get {
            switch self {
            case .text(let value): value.cacheControl
            case .image(let value), .file(let value): value.cacheControl
            case .toolCall(let value): value.cacheControl
            case .toolResult(let value): value.cacheControl
            case .reasoning, .refusal, .opaque: nil
            }
        }
        set {
            switch self {
            case .text(var value): value.cacheControl = newValue; self = .text(value)
            case .image(var value): value.cacheControl = newValue; self = .image(value)
            case .file(var value): value.cacheControl = newValue; self = .file(value)
            case .toolCall(var value): value.cacheControl = newValue; self = .toolCall(value)
            case .toolResult(var value): value.cacheControl = newValue; self = .toolResult(value)
            case .reasoning, .refusal, .opaque: break
            }
        }
    }
}
