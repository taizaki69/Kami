# Contributing

Start with [project status](docs/PROJECT_STATUS.md), [TODO.md](TODO.md) and
[BUILDING.md](BUILDING.md). `main` and the open continuation stack have
different capabilities; preserve that distinction in code reviews and docs.

## Ground rules

1. Support compatibility claims with focused runtime regressions and exact
   fixture identities. Static analysis, constructor execution and full source
   operations are separate evidence. Update the
   [matrix](docs/EXTENSION_COMPATIBILITY_MATRIX.md) with scope and limitations.
2. Keep host behavior in MihonCompatKit. Guard platform-specific imports and
   run both Swift packages; portable tests do not replace Apple/SQLite checks.
3. Keep signature/hash/manifest/source-ID admission, resource limits,
   cancellation and redaction intact. A corpus entry or structural plan never
   authorizes downloaded execution.
4. Ship database changes as numbered migrations. Preserve reading state and
   test rollback, identity conflicts and stale work where mutations are involved.
5. Keep generated Xcode projects, credentials and machine-local instructions
   out of commits. Follow the existing [license notices](LICENSES.md).

## Corpus and validation workflow

- The lock is [Tests/corpus/manifest.json](Tests/corpus/manifest.json).
  `scripts/fetch_corpus.sh` consumes it; do not add package names only to the
  fetch script. Include pinned bytes, provenance, the appropriate role and
  meaningful regressions when extending the corpus.
- `ExtensionAnalyzer.implementedClasses` is a coarse prioritization heuristic.
  Add entries only with runtime-backed coverage; an entry does not implement
  every method on that class. Update static baselines only for explained
  behavior changes, not to conceal a regression.
- Run checks appropriate to the changed surface using [BUILDING.md](BUILDING.md).
  Record the tested commit and platform. For app changes, verify simulator,
  unsigned device and IPA workflow results for the PR's current head/tree.
- Keep documentation scoped to the branch it describes. Mark implemented
  open-PR work as pending integration; retain dated historical evidence without
  presenting its counts as current. Check relative links and `git diff --check`
  for documentation changes.
