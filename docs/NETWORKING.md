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
The current await path sends that request projection directly. It does not yet
execute source-defined OkHttp interceptors or preserve DEX `Request` identity
and tags across the transport boundary.

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

The pinned MangaMelon path proves an API envelope that first encodes every DTO
default, then applies the exact UTF-8 → Okio `ByteString` → Base64 sequence and
places the result in a bounded form body. Popular, latest, filtered search,
details, chapters, and pages all cross the same source-scoped fake transport;
tests assert the decoded JSON for every request and remain fully offline.

The pinned Baozi Manhua 1.6.29 path uses the same source-scoped fake transport
for deterministic popular, latest, search, details, chapters, and pages tests.
Its exact DEX `imageRequest(Page)` method is executed before the request reaches
the app-facing image seam; the regression proves the fixture's CDN-host rewrite
without network I/O. The image request is projected to URL/headers only.

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

## Source interceptor and reader boundary

The Baozi APK contains source interceptors, but their behavior is not part of
the current runtime proof. `ReaderImagePipeline` converts `ImageRequest` to a
`CompatHTTPRequest` and calls the transport directly, so it drops DEX request
tags and does not run the APK's application/network interceptor chain. Banner
cropping, redirect-domain rewriting, and missing-image handling are therefore
not executed or proven through reader image loads. `URLSessionCompatHTTPTransport`
also follows redirects inside its delegate path; that final-response behavior
does not prove an interceptor can observe or rewrite intermediate redirects.

The next networking milestone is a bounded, source-scoped interceptor seam with
immutable interceptor snapshots, preserved request identity/tags, one-use
`proceed`, cancellation, and explicit budgets. The measured Baozi defaults are
at most 32 interceptors, 64 interceptor/terminal steps per call, depth at most
32, and one forward `proceed` per chain object. Over-budget or reentrant paths
must fail through a typed `IllegalStateException`/verification path; response-
body replacements count against the existing transport maximum, and nested
async execution must share the parent VM instruction budget. These constraints
are proposed for the next seam, not implemented behavior. It must be integrated
into the reader path before any source-defined image transform is claimed.
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
- Rate limiting: `RateLimitInterceptor` semantics (permits per interval).
- Cloudflare: challenge detection → WKWebView solve → cookie/UA sync → retry
  (see EXTENSION_RUNTIME.md M4). No bypass pretense.
- Additional retry/interceptor semantics as real corpus paths require them;
  source interceptor execution remains open as described above.

## Diagnostics

Pinned interpreted sources now expose a bounded local report containing only
typed unresolved VM surfaces, counted by source-operation stage. Arbitrary
transport/parser errors are ignored, so URL queries, authorization, cookies,
bodies, and response values never enter it. `compat-audit gaps` provides a
separate non-executing static/corpus priority report with no filenames or
request data. The app Diagnostics screen and user-selected file export remain
open; they must preserve the same local-only redaction boundary.
