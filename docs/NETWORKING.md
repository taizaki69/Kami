# Networking

## Today

Native sources (`MangaDexSource`) use `URLSession` directly with a Kami
User-Agent, through a portable continuation wrapper (the async
`URLSession.data(from:)` conveniences are Darwin-only, and MihonCompatKit
stays host-testable on Windows/Linux).

The extension runtime now models bounded OkHttp URLs, headers, form/text
bodies, cache policy, requests, isolated client identities, interceptor lists,
and inert calls. `OkHttpClient.newCall` exposes a transport-neutral
`CompatHTTPRequest` for policy/transport handoff but performs no network I/O.
The pinned BatCave path reaches `OkHttpExtensionsKt.awaitSuccess` exactly.

## Extension-facing transport and response stack (next runtime slice)

The OkHttp compatibility client must support what extension DEX measures show
they use:

- Request building: URL, query params, headers, method; bodies: form-encoded,
  JSON, byte arrays.
- Response: code, message, headers, body bytes (`.bytes()`, `.string()` with
  charset), `isSuccessful`.
- Per-source clients (`HttpSource.client` is overridable): each source gets an
  isolated client instance with its own interceptors.
- Cookie jar per source, persisted in `source_preference`; synchronized with
  the WebView bridge (shared `HTTPCookieStorage` partition per source).
- Rate limiting: `RateLimitInterceptor` semantics (permits per interval).
- Cloudflare: challenge detection → WKWebView solve → cookie/UA sync → retry
  (see EXTENSION_RUNTIME.md M4). No bypass pretense.
- Timeouts, retry, cancellation: mapped onto URLSession task cancellation and
  Swift structured concurrency. Extension calls run inside cancellable Tasks;
  the interpreter checks cancellation at method-entry boundaries.

## Diagnostics

Every request through the compat client is logged (URL, status, duration)
with secrets redacted (Authorization, Cookie values, password-like body
fields) — feeds the Diagnostics screen (mission §30).
