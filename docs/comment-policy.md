# Comment and documentation policy: self-check procedure

The binding rules — the two independent axes, and rules 1 through 5 — live in
`AGENT.md` under "Comment and documentation policy". `AGENT.md` is the source
of truth for **what the rules require**; this document is the how-to for
**checking that they hold**: the candidate file set, the commands that sweep
for a violation, the per-language comment-syntax table, the notes on
extracting a comment span safely, and the detailed handling of a third-party
`LICENSE` body. Nothing here overrides `AGENT.md`; a change to a rule belongs
there, and a change to how the rule is checked belongs here.

## Self-check

Three steps. A single `rg` one-liner is not enough: it misses `#` and
`<!-- -->` comments and it reports every URL that contains `//`.

**Candidate set** — always start from tracked files. A bare `rg` sweep
silently skips ignored and hidden files and follows nothing about symlinks:

```bash
jj file list                     # the authoritative file set
```

**Task ids** — both file contents and file names. Do not pipe into `xargs`;
paths with spaces break it:

```bash
jj file list | while IFS= read -r p; do rg -n 'TASK-[0-9]' -- "$p"; done
jj file list | rg -i 'task-[0-9]'
```

**Japanese in comments** — look for Japanese by Unicode block (CJK
punctuation, kana, ideographs, fullwidth forms), not for non-ASCII bytes: an
English comment may legitimately hold an em dash or an arrow, and flagging
those reports a correctly translated file as debt. Decide the comment syntax
per language, and look only inside comment spans so that fixtures and UI
strings are not reported:

| Comment syntax | Applies to |
|---|---|
| `//` only | `.zig` `.zon` (Zig has no block comments) |
| `//` and `/* */` | `.c` `.cpp` `.h` `.m` `.swift` `.js` |
| `#` | `.sh` `.py` `.nix` `.toml` `.gitignore`, harness replay scripts (`.txt`), extensionless shell wrappers |
| `/* */` only | `.css`, and `<style>` content (`//` is legal inside `url(http://…)`) |
| `<!-- -->` | `.html`, outside quoted attributes and outside `<script>`/`<style>` raw text |

`.md` has no comment pass: policy treats a Markdown body as prose to
translate in full, so the whole file is in scope and there is nothing to
distinguish.

Extracting spans safely means recognising everything that can contain a `//`
or `#` without starting a comment: string and char literals; Zig and ZON `\\`
multiline strings; Swift multiline (`"""`) and raw (`#"…"#`) strings; C++ raw
strings (`R"tag(…)tag"`); JS template literals — including finding the `}`
that really closes a `${…}`, which brace counting alone gets wrong — and
regex literals; Python and TOML triple-quoted strings, escapes included;
shell heredocs, taking the delimiter as a whole word (`<<'END-OF-FILE'`) and
matching the terminator exactly, with `<<-` stripping tabs only; Nix
multiline strings and `/* */`; and quoted HTML attribute values.

Symlinks are followed once per canonical target. Binaries (`.png` `.wav`
`.ttf` `.bdf`) are never inspected.

## Third-party `LICENSE` handling

Third-party `LICENSE` bodies sit on one axis only: they are exempt from
translation (rule 1), but not from the no-task-id rule (rule 3) — a local
annotation added next to an upstream licence still must not carry an id.
Anything outside this repository is out of scope entirely.
