# Unladen

[![CI](https://github.com/aisk/unladen/actions/workflows/ci.yml/badge.svg)](https://github.com/aisk/unladen/actions/workflows/ci.yml)

Unladen is a Swift library for calling large language models from many providers through one API. It speaks the OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and Gemini protocols. Built-in providers are OpenAI, Anthropic, Gemini, DeepSeek, Moonshot, OpenRouter, Groq, Mistral, xAI, Together and Ollama.

You address a model as `"provider/model"`. Requests and replies, including streams, tool calls, reasoning and prompt caching, are translated to and from that provider's protocol. A conversation history can move from one provider to another; replay data the new provider can't verify, such as thinking signatures, is left out automatically.

A protocol-translating gateway server (the `unladen` executable) is in progress and not ready for use yet.

## Installation

Unladen needs Swift 6.4 or later. Add it to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/aisk/unladen.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Unladen", package: "unladen"),
        // Linux only: an HTTP transport built on AsyncHTTPClient.
        .product(name: "UnladenAsyncHTTPClient", package: "unladen"),
    ]),
]
```

On Apple platforms, Unladen uses `URLSession` by default. On Linux, add `UnladenAsyncHTTPClient` and pass `transport: AsyncHTTPClientTransport()` to `ModelClient`.

## Usage

```swift
import Unladen

// Keys come from `apiKeys` or the provider's environment variable (e.g. ANTHROPIC_API_KEY).
let client = ModelClient()
let model = try client.model("anthropic/claude-sonnet-4-6")

// One call.
let response = try await model.generate("Write a haiku about Swift.")
print(response.text)

// Streaming.
for try await part in model.stream("Tell me a short story.") {
    if case .textDelta(_, let delta) = part { print(delta, terminator: "") }
}

// Tools, then the same history continued on another provider.
let weather = Tool(
    name: "get_weather",
    description: "Current weather for a city",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
)
var history: [Message] = [.user("Weather in Paris?")]
let reply = try await model.generate(history, tools: [weather])
history.append(reply.message)
for call in reply.toolCalls {
    history.append(.tool(ToolResult(call: call, output: "18°C, sunny")))
}
let answer = try await client.model("openai/gpt-5.2").generate(history, tools: [weather])
print(answer.text)
```

## Tests

Many of the replay tests use real API recordings taken from [pydantic-ai](https://github.com/pydantic/pydantic-ai), the [Vercel AI SDK](https://github.com/vercel/ai) and [magpie](https://github.com/yetone/magpie). See [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md) for their licenses.

```sh
swift test
```

## License

Unladen is released under the [MIT License](LICENSE). The recorded test data keeps the licenses of the projects it came from; see [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md).
