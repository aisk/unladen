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

`unladen check-config` checks a configuration without serving it. The gateway reloads its configuration on `SIGHUP` and when it is saved from the control panel. The control panel, in English or Chinese, also shows requests in flight, recent requests and sessions, and token usage by account, client and model; each finished request is appended to `~/.local/state/unladen/usage-YYYY-MM.jsonl` (or under `$XDG_STATE_HOME`).

## Container

`Containerfile`, `.containerignore` and `compose.yaml` sit at the root, so any
OCI builder and either Compose implementation work. `make image` builds and
tags it as `ghcr.io/aisk/unladen` — the name this project would publish under —
at `<git describe>` for a fixed reference and at `local` for the working copy:

```sh
make image                    # podman build; ENGINE=docker for docker
cp unladen.example.jsonc unladen.jsonc
chmod 0644 unladen.jsonc     # the image runs as uid 65532 and must read it
$EDITOR unladen.jsonc        # accounts, models, clients, panel token (16+ characters)
podman-compose up -d
# or: docker compose up -d
```

`make image TAG=0.1.0` gives a release tag and `make image-push TAG=0.1.0` sends
it to the registry the name points at; `make image IMAGE=…` builds under a
different name.

The configuration is mounted as a secret at `/data/unladen/config.jsonc`, and
one volume over `/data` keeps everything that outlives a restart:

| Path | What |
| --- | --- |
| `/data/unladen/config.jsonc` | The configuration (mounted read-only) |
| `/data/unladen/logins.json` | Tokens of accounts that signed in (ChatGPT, Antigravity) |
| `/data/unladen/usage-YYYY-MM.jsonl` | One line per finished request |

Keys belong in that file rather than in the environment: `podman inspect` and
`/proc/<pid>/environ` show environment variables to anyone who can reach the
container runtime, and the control panel at `/admin` only exists once
`panel.token` is set in the configuration. A read-only configuration means the
panel can show the file but not save it — edit it and send `SIGHUP`
(`podman kill -s HUP unladen`), or use the panel's Reload.

Environment variables still work for a quick try, without a configuration file:

```sh
podman run -d --name unladen -p 4141:4141 \
  -e UNLADEN_ANTHROPIC_API_KEY -e UNLADEN_DEEPSEEK_API_KEY \
  -e UNLADEN_API_KEY=<the key your clients present> \
  -v unladen-data:/data \
  unladen
```

Either way the image listens on `0.0.0.0:4141` as uid 65532, with `HOME`,
`XDG_CONFIG_HOME` and `XDG_STATE_HOME` pointing into `/data`, and `/health`
answers `ok` without authentication, which suits a liveness and readiness
probe. Signing in from the control panel works from a browser on any machine;
`unladen sign-in` on the command line needs `podman run -it`.

## Tests

Many of the replay tests use real API recordings taken from [pydantic-ai](https://github.com/pydantic/pydantic-ai), the [Vercel AI SDK](https://github.com/vercel/ai) and [magpie](https://github.com/yetone/magpie). See [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md) for their licenses.

```sh
swift test
```

## License

Unladen is released under the [MIT License](LICENSE). The recorded test data keeps the licenses of the projects it came from; see [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md).
