/// The wire protocols Unladen speaks, on either side of the gateway.
///
/// A wire value records the protocol it was decoded from (its `source`).
/// Encoders for the same protocol write unknown-field bags and opaque parts
/// back verbatim; encoders for another protocol drop them and warn.
@_spi(Wire) public enum WireProtocol: String, Hashable, Sendable, CaseIterable {
    /// OpenAI Chat Completions (`/v1/chat/completions`) and its many compatibles.
    case chatCompletions = "chat"
    /// OpenAI Responses (`/v1/responses`).
    case responses
    /// Anthropic Messages (`/v1/messages`).
    case anthropicMessages = "anthropic"
    /// Google Gemini `generateContent` / `streamGenerateContent`.
    case gemini
}

/// Identifies the system that produced a piece of fidelity data (a thinking
/// signature, encrypted reasoning, an item id), e.g. `"anthropic"`,
/// `"openai"`, `"google-vertex"`.
///
/// It is a plain string on purpose: which systems accept each other's data
/// is decided by endpoint trust sets, not by the wire model.
@_spi(Wire) public typealias WireSystemID = String
