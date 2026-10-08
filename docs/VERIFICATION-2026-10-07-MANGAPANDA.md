# MangaPanda exact-profile verification — 2026-10-07

This continuation starts at PR #33 commit
`d0cf165c9f0d22fb7f3d17781e6b29792eb3a1db`. It adds the exact
MangaPanda.onl 1.6.36 profile, recovery after uncatchable VM failures, and the
bounded host behavior reached by its real DEX. The full reader/compatibility
goal remains active. PRs stay unmerged.

## Identity and admission

| Field | Pinned value |
|---|---|
| Package | `eu.kanade.tachiyomi.extension.en.mangapandaonl` |
| Version / code | `1.6.36` / `36` |
| APK SHA-256 | `00ba5d0cfd65132b6feffee60b7c8d5eca23c4ce4bd5687c7908e6c9f15a3166` |
| Signer fingerprint | `9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2` |
| Source ID | `0x6a52d2d1fc303a8e` |
| Base URL / language | `https://mangapanda.onl` / `en` |

Downloaded execution continues through `ExtensionAdmissionService` and
`ExtensionSourceFactory`: bounded immutable bytes, digest, complete signing
identity, manifest, exact source-ID set, then postconstruction metadata checks.
Raw profile constructors reauthenticate the same exact bytes. No preferences
or editable settings are enabled for this profile. Factory tests cover wrong
source sets, manifest identity, signer trust, injected preferences and replaced
files before HTTP. A real SQLite reopen restores the admission and executes
the source; a disabled installation cannot restore. Package-owned registry
removal revokes retained sources and image capabilities before transport.

## Real APK evidence

`MangaPandaRuntimeTests` uses injected offline transports for metadata,
popular/latest/text search, dynamic genres, details, chapters, pages and reader
image execution. The measured `Lc1;` filter job persists its virtual compressed
cache, deduplicates genres, and returns typed sort options. Selecting Action and
A–Z on page two produces `genre: "action"`, `mod: ALPHABET` and `offset: 30`
in the real GraphQL request. Option objects retain their DEX type and identity.

Cold requests exercise cookie-key acquisition and the actual Kotlin mutex.
Website cookies do not become Cookie headers at unrelated API, image or IP
origins. Page execution runs the APK's IP lookup and history callbacks against
fixtures; these callbacks are not silently skipped. Reader requests use the
inherited page URL/headers and the source's actual configured client. No live
manga website was contacted, and this evidence does not establish its current
availability, Cloudflare handling or compatibility with newer APK releases.

Cancellation is injected at each of the four cold page-request boundaries.
A queued retry cannot start another transport request before the cancelled
request drains. It then succeeds from a fresh session. A separate regression
reproduces the APK's stale manga in-flight guard on a raw VM, verifies recovery
through the app-facing adapter, rejects old image capabilities and stale genre
schemas before HTTP, and verifies explicit genre refresh and a new search.

## Runtime changes and bounds

- Kotlin mutexes retain identity owners, FIFO tickets, at most 32 waiters and
  at most 30 seconds of contention. Guard failures release only permits acquired
  by their async VM session. Normal return and ordinary DEX exceptions preserve
  Kotlin lock lifetimes. Actual DEX budget tests distinguish those cases.
- VM/cancellation guards invalidate a private pinned-source session after work
  drains. Its replacement uses the same authenticated parsed input and immutable
  configuration, rechecks metadata and never replays an operation automatically.
  Filters return to their initial schema; fetched genres require refresh.
- Private sessions weakly track at most 200,000 live runtime objects/arrays,
  checked at instruction and operation boundaries. Existing host-call limits
  bound allocations between checks. Retirement severs session-owned cycles and
  bridge registrations; external objects remain untouched. Tests include a
  10,001-node cycle, async ownership isolation and actual DEX allocation limits.
  This is session retirement, not a general garbage collector or measured
  device memory budget.
- The source-scoped cookie jar is shared by DEX and URLSession, bounded to 256
  cookies and 8,192 bytes per cookie. Domain/path/secure/expiry/public-suffix
  rules and redirect header revalidation apply. Global URLSession cookie storage
  stays disabled. The production transport retains its jar across VM recovery;
  an injected transport without that capability receives a new bridge-owned jar.
- Regex replacement now handles numeric/named references, escapes and unmatched
  captures under byte, capture, match, progress, time and cancellation limits.
  Reversed lists are read-only backed views. JSON object replacement returns the
  prior value and validates the complete candidate before mutation; nested
  builder lambdas share the VM budget. NaN and infinity are rejected before
  Foundation JSON serialization, which raises an Objective-C exception on
  Darwin for those inputs. Rejection preserves the old value and finite Int64
  values retain their exact decimal representation. HTTP callbacks deliver
  network IO failure once and propagate VM guards or callback failures without
  redelivery.
- Literal UTF-16 substring direction fixes `substringAfterLast`, including
  DocTruyen3Q's genre URL. Float/Double text retains signed zero, Java notation
  thresholds and exponent syntax; finite sampled bit patterns round-trip. The
  digit generation does not claim every historical Android dtoa tie behavior.

Full OkHttp parity is not claimed: automatic cookies enter at the transport
boundary, after network interceptors. General Android UI, arbitrary coroutine
launches, unrestricted regex grammar and arbitrary extension execution remain
outside the measured host implementation.

## Public suffix resource

`Resources/public_suffix_list.dat` is the unchanged ICANN + PRIVATE list from
[publicsuffix.org](https://publicsuffix.org/list/public_suffix_list.dat), version
`2026-10-07_07-28-19_UTC`, upstream commit
`3929462652695bad04f0a27afb600974014a3c8b`, 335,478 bytes, SHA-256
`ba7d836c0ea57a8bcf9f1fcb868066a7554bed029b441ecc6204ad8494a32612`.
Its MPL-2.0 notice is retained. SwiftPM copies it into the runtime resource
bundle; no network update occurs while interpreting a source. Missing/malformed
data fails closed for domain cookies. A future update must preserve the notice,
record origin/version/hash and rerun public-suffix, cookie and Apple packaging
checks. It grants no trust to an extension or hostname.

## Corpus and verification

The 27 artifacts and their hashes/paths are unchanged: 14 execution fixtures
(12 exact current profiles and two legacy constructor fixtures), seven
measurement artifacts and six signature conformance fixtures. The static audit
changed from 359 to 331 unique missing method surfaces after host registrations,
then to 330 when MangaPanda left the measurement role. These are separate
effects. Two postpromotion audits were byte-identical: seven analyzed, zero
errors, three structural candidates, four wrapper-blocked artifacts, zero
omitted invocations and zero unsupported opcodes. The baseline was regenerated
from those outputs and compared against unchanged instruction/identity counts.

Linux Swift 6.3.3 verification: 430 MihonCompatKit tests, 236 portable KamiCore
tests and 510 KamiCore tests with SQLite pass. Apple workflow results are recorded
with the implementation PR and local checkpoint. Exact-head macOS, simulator,
device and IPA evidence must be checked separately from portable test logs;
physical-device and live-site behavior are not inferred from CI.

Durable local evidence: `.git/checkpoints/20261007-mangapanda/`, including full
test logs, before/after static audits, per-artifact count deltas and snapshots.
