# Kami

A native iOS manga reader with a bounded Swift interpreter for measured
Mihon/Tachiyomi extension APKs and a native MangaDex source.

Created and maintained by [taizaki69](https://github.com/taizaki69).

## Project status

Documentation reviewed on **2026-10-04** against `main` at
[`a479806`](https://github.com/taizaki69/Kami/commit/a479806ba81c71845ba0a154a096bf47736b7393).
The [project status](docs/PROJECT_STATUS.md) distinguishes that snapshot from
the open continuation PRs and records verification for their exact commits.

| Area | Available in the reviewed `main` snapshot |
| --- | --- |
| Reading | LTR, RTL and webtoon modes; zoom/pan; saved progress/history; reader settings; bounded image loading, prefetch and explicit retry |
| Browsing | Native MangaDex; admitted exact extension profiles; popular/latest/search, details, chapters and generic filter editing |
| Extensions | Store indexes, content-addressed installation, signature verification, persisted trust, enable/disable and authenticated startup restoration |
| Persistence | SQLite schema v2, library membership, chapter state and history; category/download tables exist but their product flows are incomplete |
| Backups | Early decoder only; the corrected Mihon decoder and native Files export are in open PRs |
| Builds | Swift package tests, iOS simulator compilation, unsigned device compilation and unsigned IPA packaging in GitHub Actions |

Categories, configurable FoolSlide, manual updates, resumable downloads,
offline reading, native backup export and stronger state consistency are
implemented in **open PRs #10–20**. They are not yet merged into `main`.
Native restore preview/commit, Mihon import mapping, source migration and
several reader improvements remain on the [task tracker](TODO.md).

## Extension compatibility

The reviewed `main` catalog contains **10 exact current lib 1.6 profiles**:
BatCave 1.6.9, Kawii Manga 1.6.1, MangaMelon 1.6.1, Baozi Manhua 1.6.29,
TuttoAnimeManga 1.6.10, Mangas-Origines.fr 1.6.58, Komikcast/VoraToon 1.6.83,
Yomu Comics/SSSCanlator 1.6.59, EternalMangas 1.6.28 and DocTruyen3Q 1.6.38.
FoolSlide Customizable is an additional exact profile in
[PR #10](https://github.com/taizaki69/Kami/pull/10).

Each profile requires matching APK bytes, signature, manifest and source IDs.
Deterministic fixtures exercise the real APK through injected transport. They
do not establish live-site availability, arbitrary APK compatibility,
Cloudflare handling or Android bitmap support. The two legacy lib 1.4 APKs
have constructor coverage, not full source-operation coverage.

The [compatibility matrix](docs/EXTENSION_COMPATIBILITY_MATRIX.md) lists
profile evidence and limits. The [corpus guide](Tests/corpus/README.md)
explains the difference between manifest roles and executable catalog
membership, including the two stale role labels on `main`.

## Build and test

From the repository root, with a compatible Swift toolchain:

```bash
bash scripts/fetch_corpus.sh
swift test --package-path Packages/MihonCompatKit
swift test --package-path Packages/KamiCore
```

Portable KamiCore tests do not exercise SQLite or ImageIO when those modules
are unavailable. App compilation requires macOS and Xcode. See
[Building Kami](BUILDING.md) for platform details and
[IPA builds](docs/IPA_BUILD.md) for the unsigned artifact and signing boundary.

## Development documentation

- [Current status and open PRs](docs/PROJECT_STATUS.md)
- [Priorities and acceptance criteria](TODO.md)
- [Architecture](ARCHITECTURE.md) and [contributing](CONTRIBUTING.md)
- [Extension runtime](docs/EXTENSION_RUNTIME.md) and
  [dated ecosystem research](docs/EXTENSION_COMPATIBILITY_ANALYSIS.md)
- [Reader](docs/READER.md), [networking](docs/NETWORKING.md),
  [database](docs/DATABASE.md) and [backups](docs/BACKUP_COMPATIBILITY.md)
- [Continuation handoff and historical evidence](HANDOFF.md)

## License and test inputs

See [LICENSES.md](LICENSES.md) for the existing rights and dependency notices.
Vendored APKs are test inputs and are not shipped in the iOS app; their
attribution is in the [corpus notice](Tests/corpus/KEIYOUSHI-EXTENSIONS-NOTICE.md).
