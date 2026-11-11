# Unladen

[![CI](https://github.com/aisk/unladen/actions/workflows/ci.yml/badge.svg)](https://github.com/aisk/unladen/actions/workflows/ci.yml)

Unladen is a local LLM gateway written in Swift. Point your clients at one endpoint and speak the OpenAI Chat Completions, OpenAI Responses, Anthropic Messages or Gemini protocol. Unladen translates each request to the protocol of the upstream that serves the model, and translates the reply back. Built-in providers are OpenAI, Anthropic, Gemini, DeepSeek, Moonshot, OpenRouter, Groq, Mistral, xAI, Together and Ollama.

Its routing and account design draws on ideas from [claude-code-router](https://github.com/musistudio/claude-code-router), [cc-switch](https://github.com/farion1231/cc-switch) and [magpie](https://github.com/yetone/magpie).

## The server

```sh
swift build -c release --product unladen --static-swift-stdlib
.build/release/unladen --config config.jsonc
```

The configuration is JSON with comments and trailing commas, read from `--config` or `~/.config/unladen/config.jsonc`.

```jsonc
{
  "listen": "127.0.0.1:4141",
  // Opens the control panel at /admin.
  "panel": { "token": "${UNLADEN_ADMIN_TOKEN}" },
  // The accounts the gateway pays with. Accounts of one provider form a
  // pool; the next one is tried when one fails.
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

**What you get**

- **Four client protocols over one port.** A Claude Code or OpenCode client, a Gemini CLI and a plain OpenAI SDK can all talk to the same gateway, each in its own protocol, and share the accounts and model names configured there.
- **Model mapping.** `models` maps the names clients ask for to the account that answers. A name can pass through to its own provider, point at a fixed upstream model, or fall back to another mapping.
- **Account pools.** Accounts of one provider form a pool; when one fails, the next one is tried.
- **Client keys.** Clients present a key from `clients`, and a client can be limited to a subset of the model names.
- **A control panel at `/admin`**, in English or Chinese, once `panel.token` is set, showing requests in flight, recent requests and sessions, token usage by account, client and model, and editing the configuration itself. Every finished request is appended to `~/.local/state/unladen/usage-YYYY-MM.jsonl` (or under `$XDG_STATE_HOME`).
- **Subscription accounts.** A `chatgpt` account may hold an OpenAI API key, or none. Then it signs in with a ChatGPT account ("Sign in with ChatGPT") and uses that plan through OpenAI's Responses API, for your own use only. An `antigravity` account signs in with Google and uses an Antigravity subscription through Google's Code Assist backend; Google does not offer this to other apps and may suspend an account it sees used outside Antigravity, so use one you can afford to lose. Sign in from the control panel or with `unladen sign-in <provider>`; tokens are kept in `~/.local/state/unladen/logins.json` and refreshed as needed.
- **Operational niceties.** `unladen check-config` checks a configuration without serving it. The server reloads its configuration on `SIGHUP` and when it is saved from the panel. `/health` answers `ok` without authentication, which suits a liveness and readiness probe.

It is early work; the routing topology beyond forwarding and pools is still growing.

## Container

`Containerfile`, `.containerignore` and `compose.yaml` sit at the root, so `podman` with `podman-compose`, or `docker` with `docker compose`, both work (`docker` reads only `.dockerignore`, a symlink to `.containerignore`).

```sh
podman build -f Containerfile -t unladen:local .
# or: docker build -f Containerfile -t unladen:local .

mkdir -p config
cp unladen.example.jsonc config/config.jsonc
chmod 0644 config/config.jsonc   # the container runs as uid 65532 and must read it
$EDITOR config/config.jsonc      # accounts, models, clients, panel token (16+ characters)
podman-compose up -d
# or: docker compose up -d
```

The configuration directory is mounted read-only at `/config/unladen`, and one volume over `/data` keeps everything that outlives a restart (sign-in tokens, usage logs). Keys belong in the configuration file rather than in the environment, because anyone who can reach the container runtime can read the environment, while the panel at `/admin` exists only once `panel.token` is set. A read-only mount means the panel can show the file but not save it, so edit it and send `SIGHUP` (`podman kill -s HUP unladen`), or use the panel's Reload. The image listens on `0.0.0.0:4141` as uid 65532. For a quick try without a configuration file, `UNLADEN_ANTHROPIC_API_KEY`-style environment variables work too.

## The library

Unladen is also a Swift library for calling large language models from many providers through one API; the server above is built on it. You address a model as `"provider/model"`, and requests and replies, including streams, tool calls, reasoning and prompt caching, are translated to and from that provider's protocol. A conversation history can move from one provider to another; replay data the new provider cannot verify, such as thinking signatures, is left out automatically.

Unladen needs Swift 6.4 or later. Add it to `Package.swift`.

```swift
dependencies: [
    .package(url: "https://github.com/aisk/unladen.git", branch: "main"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Unladen", package: "unladen"),
        // Linux only. An HTTP transport built on AsyncHTTPClient.
        .product(name: "UnladenAsyncHTTPClient", package: "unladen"),
    ]),
]
```

On Apple platforms, Unladen uses `URLSession` by default. On Linux, add `UnladenAsyncHTTPClient` and pass `transport: AsyncHTTPClientTransport()` to `ModelClient`.

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
```

## Tests

Many of the replay tests use real API recordings taken from [pydantic-ai](https://github.com/pydantic/pydantic-ai), the [Vercel AI SDK](https://github.com/vercel/ai) and [magpie](https://github.com/yetone/magpie). See [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md) for their licenses.

```sh
swift test
```

## License

Unladen is released under the [MIT License](LICENSE). The recorded test data keeps the licenses of the projects it came from; see [THIRD_PARTY_NOTICES.md](Tests/UnladenReplayTests/Recordings/THIRD_PARTY_NOTICES.md).
