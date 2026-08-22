# Contributing

## Ground rules
1. **Measured claims only.** A compatibility statement requires a test or a
   `compat-audit` run behind it. Update `docs/EXTENSION_COMPATIBILITY_MATRIX.md`
   with evidence, not expectations.
2. Every compatibility fix adds a regression test (mission §38): reproduce,
   test, fix, verify neighbors, update the matrix.
3. Keep `MihonCompatKit` free of Apple-only imports outside `#if canImport`
   guards — it must keep building on Linux/Windows CI.
4. Database changes ship as numbered migrations; never mutate shipped steps.
5. Run `swift test --package-path Packages/MihonCompatKit` before anything
   else; it is the fastest signal.

## Workflow
- `scripts/fetch_corpus.sh` pins the test corpus; add package names there
  when expanding coverage, and record results in the matrix.
- Change `ExtensionAnalyzer.implementedClasses` only with runtime-backed tests;
  its class-level score is a prioritization heuristic, not proof that every
  method on a class is implemented. Keep host behavior centralized in
  `HostBridge` instead of scattering extension-specific cases through app code.
