# ADR-012: Source language and comment policy for a public repository

- Status: Accepted
- Date: 2026-07-26

## Context

`kngn` is public. The rest of the project is not: the task tracker,
the meta repository (operating procedures, machine names), and development notes
are all private. Comments and documentation in this repository were written in
Japanese for an audience of one, and they refer freely to private task ids.

Two problems follow.

**Dead references that look live.** A measurement over the tree found 2,958
`TASK-NN` references: 2,370 in comments, 352 in prose and other files with no
comment syntax, 225 in string literals (`test "..."` names, build step
descriptions that appear in `zig build --help`, window titles, values inside e2e
scripts), and 11 in file names. Each one resolves only in the private tracker. A reader here cannot follow any of them,
yet they read as if they could.

**A language barrier for contributors.** Identifiers, APIs, log keys and wire
formats are already English; only the prose explaining them is not.

Token efficiency was the original motivation for switching to English, so it was
measured rather than assumed. Translating a representative sample of ten real
comments gave a ratio of 0.78 English tokens per Japanese token — about 22% on
Japanese prose, and roughly 150k tokens or **6.8% of the repository** overall,
because the mixed Japanese/English text is already dense with English
identifiers that tokenize identically. That is a real but secondary benefit, and
it is recorded here so nobody later mistakes efficiency for the reason.

## Decision

**English** for source comments, `docs/adr/`, `docs/plans/`, every `README.md`,
and `AGENT.md`. Japanese remains in the private tiers, which are not part of
this repository.

**Two exceptions stay Japanese**, because they are data rather than prose:
Japanese test fixtures (multibyte-handling test data) and user-visible UI
strings. Translating either changes behaviour or breaks a test.

**No task-tracker ids anywhere in this repository** — comments, `test` names,
build step descriptions, script values, file names, documentation.

The two requirements are independent axes, and the exceptions above attach only
to the language axis. "Do not translate this string" does not mean "never touch
this string": seven example programs put a task id in a window title or an
on-screen label — `Window.create(w, h, "GUI Torture Suite (<task id>)")` and the
like — so the public build showed private ids in its own title bar. Those keep
their wording and lose the id. Deciding this needs no judgement,
because a task id is never legitimately part of user-facing text.

Measured distribution of the 225 references that sit outside comments: 188
`test "..."` names, 9 build step descriptions (visible in `zig build --help`), 5
layer-exception reason strings, 12 values inside e2e scripts, 7 UI strings and
window titles, and the rest scattered. Step *names* are the `zig build <name>` interface and
contain no ids; nothing uses `--test-filter`, so renaming test names is safe.

**Comments state the current contract**; design decisions, rejected
alternatives, trade-offs and the measurements behind them go to an ADR; design
spanning several work items goes to `docs/plans/`; operating procedures stay in
the meta repository.

The binding rules live in `AGENT.md` under "Comment and documentation
policy"; the self-check procedure that verifies them lives in
`docs/comment-policy.md`. This ADR records *why*; `AGENT.md` records *what to
do*; `docs/comment-policy.md` records *how to check it*.

## Consequences

Provenance no longer lives in the source. It is recovered through
`jj file annotate` → commit message → task tracker. That chain was audited
before deciding, and it is **incomplete**: of 276 unique ids referenced in code,
all 276 exist as tracker entries, but 16 appear in no commit message, and only 5
of those are reachable through a sub-id. Eleven are reachable through neither.

So the removal is preceded by a machine-generated manifest of every reference —
repository, revision, path, line, column, UTF-8 byte offset, occurrence index,
id, raw text, file digest — stored in the **private** repository. Generation is
fail-closed: it refuses to run unless the working copy is clean and sits exactly
on the revision it claims to describe, and refuses to write at all if any tracked
file could not be read. The public tree
stays clean while provenance stays complete, including for those eleven.

Enforcement is by convention and review, not tooling: this repository gains no
lint step and no build step for the policy. `docs/comment-policy.md` states
the self-check — which comment syntax applies where, and every construct that
can hold a `//` or `#` without starting a comment — and the meta repository's
review checklist includes policy conformance. The task-id half of that check is a `jj file list`
sweep anyone can run here; the comment half needs a real lexer, which lives with
the migration tooling in the private repository rather than in this build. The
trade-off is accepted deliberately: the alternative was a ratchet enforced by
`zig build`, and keeping the public build free of migration machinery was judged
worth more than mechanical enforcement.

Mass translation cannot be verified by reading. Each migration step instead
proves that **only comments changed**, by stripping all comments from the before
and after files and requiring byte equality. That proof is only as good as the
comment lexer, so the lexer is biased toward "this is code" and is itself tested
against fixtures covering every construct that can contain a `//` or `#` without
starting a comment. Japanese is detected by Unicode block, which is a heuristic
rather than language identification: fullwidth ASCII counts as Japanese
typography, romaji does not count at all, and the blocks are listed in the tool. What the proof cannot catch is a *mistranslation*: a comment
that still describes a contract, but the wrong one. Review of the contract-heavy
areas — the real-time audio contract, the performance rules, frame pacing,
buffer ownership, the netsync wire format — is the only defence there, and is
required for those paths.

## Numbering

ADR numbers continue from **013**. Files are named
`NNN_english-slug.md`; the Japanese file names of 001–011 are renamed to English
slugs, and their decisions are not altered by that rename.
