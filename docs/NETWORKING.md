# Networking

## Today

Native sources (`MangaDexSource`) use `URLSession` directly with a Kami
User-Agent, through a portable continuation wrapper (the async
`URLSession.data(from:)` conveniences are Darwin-only, and MihonCompatKit
stays host-testable on Windows/Linux).

The extension runtime models bounded OkHttp URLs, headers, form/text bodies,
cache policy, requests, isolated client identities, interceptor lists, and
calls. `OkHttpClient.newCall` retains both the exact DEX `Request`/tags and its
transport-neutral `CompatHTTPRequest` projection. `OkHttpExtensionsKt.await`
and `awaitSuccess` snapshot application then network interceptors in
registration order, execute them asynchronously without blocking an
interpreter thread, reach the explicitly injected transport at the terminal,
and unwind responses in reverse order. The bounded chain preserves the outer
VM instruction budget, checks cancellation at every edge, allows at most 32
interceptors, 64 interceptor/terminal steps, depth 32, and one `proceed` per
chain object, and validates replacement bodies/headers against the transport
policy.

`URLSessionCompatHTTPTransport` is an actor owned by one source identity. It
applies request, redirect, timeout, header, and body limits; rejects insecure
HTTPS downgrades; enforces the response-body limit while delegate bytes arrive;
and keeps an in-memory cookie jar isolated to that source. Its optional
single-exchange capability returns one response without following a redirect,
while preserving the same validation, streaming limits, cancellation, and
cookie storage. Tests inject a fake transport, so the pinned APK suite remains
deterministic and makes no live requests.

Async DEX frames resume after transport completion. Swift Task or OkHttp-call
cancellation maps to a typed VM cancellation, transport failures become
redacted `java.io.IOException` values, and `awaitSuccess` rejects non-2xx
responses with Mihon's `HttpException`. The exact host allow-list exposes
bounded `Response`, `Response.Builder`, `ResponseBody`, `Headers`, and
`okio.BufferedSource` values, including exact request retention, redirect/
header/code/body rebuilding, one-shot body reads, and common response charsets.
`awaitSuccess` applies its 2xx check after the complete response unwind.

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

The pinned MangaMelon path proves an API envelope that first encodes every DTO
default, then applies the exact UTF-8 → Okio `ByteString` → Base64 sequence and
places the result in a bounded form body. Popular, latest, filtered search,
details, chapters, and pages all cross the same source-scoped fake transport;
tests assert the decoded JSON for every request and remain fully offline.

The pinned Baozi Manhua 1.6.29 path uses the same source-scoped fake transport
for deterministic popular, latest, search, details, chapters, and pages tests.
Those core operations traverse the APK's configured interceptor chain and its
finite one-second rate limiter.
Its exact DEX `imageRequest(Page)` method is executed before the request reaches
the app-facing image seam; the regression proves the fixture's CDN-host rewrite
without network I/O. With banner mode explicitly disabled, the image request
also carries an opaque capability backed by the exact actor-owned DEX
Request/tags and configured client.

Each pinned `KamiSource` owns its transport together with one mutable
interpreter behind a bounded actor queue, so a suspended request cannot permit
another caller to enter the same VM concurrently. Production transport
disallows plain HTTP by default when constructed with its default policy;
deterministic injected transports remain the only paths used by the corpus
tests. The source retains that exact policy and `ReaderView` passes it into the
reader pipeline. Reader requests are validated before even an injected
transport sees the URL/headers, HTTPS is the default, HTTP requires explicit
source opt-in, and redirects use the same source-scoped policy. Reader-specific
image response limits remain independent of the source response-body limit.
For ordinary page-URL profiles, source-derived `Authorization`,
`Proxy-Authorization`, `Cookie`, `Cookie2`, and `Host` headers are retained only
when the image URL has the source's exact scheme, host, and effective port.
Non-secret CDN headers such as `Referer` and `Origin` remain available across
origins.

## Reader interceptor boundary

`ReaderImagePipeline` validates every public URL/header projection first.
Ordinary requests then use its direct transport. A request with a source-scoped
capability instead asks the source actor to run the exact retained DEX Request
through its configured bounded application/network chain and shared cookie jar;
KamiCore receives only the bounded response and an opaque UUID used for
deduplication/cache separation. For a transport that exposes single exchanges,
application interceptors run once, network interceptors run for each response,
and a rewritten `Location` selects the next bounded GET. Every hop shares the
source redirect limit, HTTPS-downgrade policy, cancellation checks, retained
Request tags, and the call's 64-step/one-VM-session budget. Cross-origin
follow-ups strip `Authorization`, `Proxy-Authorization`, explicit `Cookie`,
`Cookie2`, and `Host`; the source cookie jar then applies only cookies valid for
the new URL.
The real Baozi regression proves its retained redirect-domain tag rewrites a raw
302 and the rewritten source-host URL is fetched to final image bytes.

This seam is intentionally reader-image/GET scoped. Ordinary source operations
still use the existing terminal transport contract, so this is not evidence of
general OkHttp retry, POST-redirect, or intermediate-response parity. Baozi
banner cropping remains unsupported until a bounded portable pixel/JPEG
implementation exists; the production factory explicitly defaults
`BAOZI_BANNER=0`, and a metadata-only Bitmap shim would not be compatibility.
Reader retry must also regenerate and revalidate the source `ImageRequest` and
define expiry/credential-refresh behavior; the current per-page retry reuses the
request resolved during page loading.

## Remaining extension-facing stack

Still required for the remaining source results and broader extension
compatibility:

- Additional Jsoup document/element APIs only as the next pinned source paths
  measure them; the covered BatCave paths already enforce input, DOM, extracted
  string, result-count, and cumulative selector-work limits.
- Additional request/response overloads, including byte-array and streaming
  request bodies, only as measured extensions reach them.
- Persistent per-source cookies and preferences; the current compat cookie jar
  is source-isolated but in memory only. Baozi scalar preferences are accepted
  by the exact profile when injected, but production preference UI/persistence
  is not wired.
- General rate-limiter parity beyond the exact finite Baozi path (permits per
  interval, retry behavior, and other time representations).
- Cloudflare: challenge detection → WKWebView solve → cookie/UA sync → retry
  (see EXTENSION_RUNTIME.md M4). No bypass pretense.
- Additional retry/interceptor semantics as real corpus paths require them,
  including general source-operation response sequences and non-GET follow-up
  rules where a measured extension actually requires them.

## Diagnostics

Pinned interpreted sources now expose a bounded local report containing only
the first typed unresolved VM surface observed at the public VM boundary for
each source operation, even when a nested host bridge catches or replaces
that error. Unknown external fields fail closed unless the exact host field is
modeled. Arbitrary transport/parser errors are ignored, so URL queries,
authorization, cookies, bodies, and response values never enter the report.
`compat-audit gaps` provides a separate non-executing static/corpus priority
report with no filenames or request data, while `compat-audit promote-gap`
strictly converts a canonical redacted runtime report into a focused XCTest
assertion seed. The app Diagnostics screen and user-selected file export remain
open; they must preserve the same local-only redaction boundary.
