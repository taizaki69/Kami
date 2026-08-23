# Networking

## Today

Native sources (`MangaDexSource`) use `URLSession` directly with a Kami
User-Agent, through a portable continuation wrapper (the async
`URLSession.data(from:)` conveniences are Darwin-only, and MihonCompatKit
stays host-testable on Windows/Linux).

The extension runtime models bounded OkHttp URLs, headers, form/text bodies,
cache policy, requests, isolated client identities, interceptor lists, and
calls. `OkHttpClient.newCall` produces a transport-neutral
`CompatHTTPRequest`; `OkHttpExtensionsKt.await` and `awaitSuccess` cross an
explicitly injected async transport without blocking an interpreter thread.

`URLSessionCompatHTTPTransport` is an actor owned by one source identity. It
applies request, redirect, timeout, header, and body limits; rejects insecure
HTTPS downgrades; enforces the response-body limit while delegate bytes arrive;
and keeps an in-memory cookie jar isolated to that source. Tests inject a fake
transport, so the pinned APK suite remains deterministic and makes no live
requests.

Async DEX frames resume after transport completion. Swift Task or OkHttp-call
cancellation maps to a typed VM cancellation, transport failures become
redacted `java.io.IOException` values, and `awaitSuccess` rejects non-2xx
responses with Mihon's `HttpException`. The exact host allow-list exposes
bounded `Response`, `ResponseBody`, `Headers`, and `okio.BufferedSource` values,
including one-shot body reads and common response charsets.

The pinned BatCave popular path now crosses the fake transport, consumes the
bounded response, and reaches
`JsoupExtensionsKt.asJsoup$default(Response, String, int, Object)`. That exact
HTML-parser signature is the current measured frontier.

## Remaining extension-facing stack

Still required for useful source results and broader extension compatibility:

- The exact Jsoup document/element/selector surface reached by the pinned APK,
  with input and DOM resource limits.
- Additional request/response overloads (including JSON and byte-array bodies)
  only as measured extensions reach them.
- Persistent per-source cookies and preferences; the current compat cookie jar
  is source-isolated but in memory only.
- Rate limiting: `RateLimitInterceptor` semantics (permits per interval).
- Cloudflare: challenge detection → WKWebView solve → cookie/UA sync → retry
  (see EXTENSION_RUNTIME.md M4). No bypass pretense.
- Additional retry/interceptor semantics as real corpus paths require them.

## Diagnostics

Production compatibility telemetry and the Diagnostics screen are not yet
implemented. When added, request diagnostics must remain local and redact URL
queries, authorization, cookies, bodies, and other source secrets by default.
