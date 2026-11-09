# Unladen

[![CI](https://github.com/aisk/unladen/actions/workflows/ci.yml/badge.svg)](https://github.com/aisk/unladen/actions/workflows/ci.yml)

Unladen is a Swift library for calling large language models from many providers through one API. It speaks the OpenAI Chat Completions, OpenAI Responses, Anthropic Messages and Gemini protocols. Built-in providers are OpenAI, Anthropic, Gemini, DeepSeek, Moonshot, OpenRouter, Groq, Mistral, xAI, Together and Ollama.

You address a model as `"provider/model"`. Requests and replies, including streams, tool calls, reasoning and prompt caching, are translated to and from that provider's protocol. A conversation history can move from one provider to another; replay data the new provider can't verify, such as thinking signatures, is left out automatically.

The `unladen` executable is a gateway built on the library: clients speak any of the four protocols to it, and it translates each request for the upstream that serves the model. It is early work; see [Gateway](#gateway).

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

## Gateway

```sh
swift build -c release --product unladen --static-swift-stdlib
.build/release/unladen --config config.jsonc
```

The configuration is JSON with comments and trailing commas, read from `--config` or `~/.config/unladen/config.jsonc`:

```jsonc
{
  "listen": "127.0.0.1:4141",
  // Opens the control panel at /admin.
  "panel": { "token": "${UNLADEN_ADMIN_TOKEN}" },
  // The accounts the gateway pays with. Accounts of one provider form a
  // pool: the next one is tried when one fails.
  "accounts": {
    "anthropic": "${ANTHROPIC_API_KEY}",
    "deepseek": "${DEEPSEEK_KEY_1}",
    "deepseek-2": { "provider": "deepseek", "key": "${DEEPSEEK_KEY_2}" },
  },
  // The model names clients may ask for, and who answers them.
  "models": {
    "claude-*": "anthropic",               // the name asked for, passed on
    "fast": "deepseek/deepseek-chat",
    "*": "@fast",                          // every other name
  },
  // The keys clients present; without models, a client may use every name above.
  "clients": {
    "laptop": { "key": "${UNLADEN_KEY_LAPTOP}", "models": "*" },
    "ci": { "key": "${UNLADEN_KEY_CI}" },
  },
}
```

An account of provider `chatgpt` may hold an OpenAI API key, or none: then it signs in with a ChatGPT account ("Sign in with ChatGPT") and uses that plan through OpenAI's Responses API, for your own use only. Write it as `"chatgpt": {}`, then sign in from the control panel (when adding the account, or later) or with `unladen sign-in chatgpt`; the tokens are kept in `~/.local/state/unladen/logins.json` and refreshed as needed.

An account of provider `antigravity` signs in with Google and uses an Antigravity subscription through Google's Code Assist backend. Google does not offer this to other apps and may suspend an account it sees used outside Antigravity: use one you can afford to lose, at your own risk.

`unladen check-config` checks a configuration without serving it. The gateway reloads its configuration on `SIGHUP` and when it is saved from the control panel. The control panel also shows requests in flight, recent requests and sessions, and token usage by account, client and model; each finished request is appended to `~/.local/state/unladen/usage-YYYY-MM.jsonl` (or under `$XDG_STATE_HOME`). The design, including what later versions will add, is in [docs/server-config-design.md](docs/server-config-design.md) (Chinese).

## Tests

Many of the replay tests use real API recordings taken from [pydantic-ai](https://github.com/pydantic/pydantic-ai), the [Vercel AI SDK](https://github.com/vercel/ai) and [magpie](https://github.com/yetone/magpie). See [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md) for their licenses.

```sh
swift test
```

## License

Unladen is released under the [MIT License](LICENSE). The recorded test data keeps the licenses of the projects it came from; see [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md).
