# ADR-017: App-data isolation for unattended harness runs

- Status: Accepted
- Date: 2026-07-29
- Scope: why `libs/appshell` reads harness-related environment variables directly when
  resolving the default application-data directory, and which alternatives were rejected.
  The operational contract (which env states isolate) lives in `docs/harness.md` and in
  the doc comment on `paths.shouldIsolateDefaultPath`.

## Context

Unattended harness runs (file replay, headless live) must not read or write the
developer's real application-data directory. A leftover autosave there opens a recovery
modal at startup, and while that modal is up every injected event is absorbed instead of
reaching the canvas — which makes e2e scripts look flaky when the real cause is session
pollution.

`KNGN_APPSHELL_DIR` already lets a caller override the directory, and several e2e
scripts set it per run. The gap is every other unattended launch that forgets the
override: isolation has to be the default for those runs, not an opt-in.

## Decision

`libs/appshell/src/paths.zig` reads `KNGN_HARNESS_SCRIPT` and `KNGN_HEADLESS` itself and,
when isolation is requested and no explicit override is passed, redirects
`openAppDataDir` to a per-process temporary directory
(`<TMPDIR>/kngn-appdata-<pid>-<nonce>/<app_name>`). The path is created once per process,
logged once to stderr, and never deleted (cleanup is left to the OS temp directory).
Creation failure is an error; there is no fallback to the real app-data path.

An explicit `KNGN_APPSHELL_DIR` (passed by the application as `override_path`) always
wins. Display-backed live (`KNGN_HARNESS_LISTEN` with `KNGN_HEADLESS` unset) does not
isolate, so a human peeking at a live session still sees their own data.

## Why appshell reads harness env names

appshell cannot import `core/control`. Injecting the isolation decision from core into
appshell would reverse the `apps → kit → libs → core` dependency direction. Reading the
same public environment signals that already decide transport and headless mode is the
smallest cross-layer contract: the env names are stable public API, and every appshell
consumer (pixie, patch, examples) gets the protection without per-app wiring.

## Rejected alternatives

1. **Harness writes `KNGN_APPSHELL_DIR` back into the process environment.** Ownership and
   lifetime of the override become unclear (who created it, who may clear it, what
   happens when the application already set it). Mutating process-global env from a
   control-plane module is a worse contract than a pure path decision inside appshell.

2. **Disable persistence entirely under the harness.** Autosave scan, recovery modal,
   recent files, preferences and window-state load/save would all stop running, so e2e
   could not exercise those paths. A temporary directory keeps the real persistence code
   on the happy path and only moves *where* it writes.

## Consequences

- Changing the meaning of `KNGN_HARNESS_SCRIPT` or `KNGN_HEADLESS` requires updating both
  the harness/platform settlement and `paths.shouldIsolateDefaultPath`.
- Temporary directories accumulate under `/tmp` until the OS reclaims them.
- Callers that intentionally want a contaminated or fixture app-data tree under
  unattended runs must set `KNGN_APPSHELL_DIR` explicitly.
