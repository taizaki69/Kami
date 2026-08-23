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
bounded response, parses it through `JsoupExtensionsKt.asJsoup$default`, and
returns an exact `MangasPage` from the source's production selectors. The
fixture remains deterministic and offline. BatCave's nonblank text-search path
also proves the exact page-2 GET and its 600-second cache policy before parsing
the result through the same bounded surface. The public latest-updates path
proves its cached page-3 GET, and the real manga-details worker proves its
cached detail GET before returning the expected core `SManga` fields. The
combined update worker reuses the same bounded response path and returns exact
generated-DTO chapter results. The page-list worker runs its generated request
serializer, sends the exact JSON POST, decodes its response DTOs from a bounded
Okio source, and returns normalized page image URLs. All of these tests remain
offline.

The pinned Kawii Manga path independently proves bounded dynamic
`HttpUrl.Builder` queries for search/details/pages and executes the source's
exact `headersBuilder` override so `x-app-key` reaches every deterministic JSON
GET. Percent-encoded query growth is charged against the final 8 KiB URL limit
before intermediate output can grow past it.

Each pinned `KamiSource` owns its transport together with one mutable
interpreter behind a bounded actor queue, so a suspended request cannot permit
another caller to enter the same VM concurrently. Production transport
disallows plain HTTP by default; deterministic injected transports remain the
only paths used by the corpus tests.

## Remaining extension-facing stack

Still required for the remaining source results and broader extension
compatibility:

- Additional Jsoup document/element APIs only as the next pinned source paths
  measure them; the covered BatCave paths already enforce input, DOM, extracted
  string, result-count, and cumulative selector-work limits.
- Additional request/response overloads, including byte-array and streaming
  request bodies, only as measured extensions reach them.
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
