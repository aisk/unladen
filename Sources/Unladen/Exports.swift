// `import Unladen` is the only import a library user needs.
//
// UnladenCore's plain-`public` surface was designed as the stable library
// surface (JSON, SSE, `HTTPTransport`, `MockTransport`, `URLSessionTransport`,
// `Endpoint`, `Profile`, `Provider`, `ProviderRegistry`, `Presets`,
// `ResolvedModel`, `UpstreamHTTPError`); everything unstable is
// `@_spi(Wire)`, which `@_exported` does not re-export. Re-exporting the
// module keeps one identity for each type (an `AsyncHTTPClientTransport` is
// the same `HTTPTransport` users see here), carries extensions and nested
// types along, and needs no hand-kept list of typealiases.
@_exported public import UnladenCore
