# Commit-format scans use stripped route text for quoted heredoc data

> In the context of the commit-format PreToolUse gate, facing a file-writing
> quoted heredoc whose body held Markdown backticks (and often the words
> `git commit`), I decided to run presence, newline-compound, and backtick
> scans on the same quoted-stripped route text as push/commit routing, so a
> quoted heredoc body stays data, accepting that a missing stripper keeps
> today's raw-command scan and that unquoted heredocs are unchanged.

## Status

Accepted. AgDR-0259. Implements me2resh/apexyard#1810.
Stacked on AgDR-0262 / #1805.

### Architecture evolution

- 2026-10-19 (AgDR-0262): Dispatcher strip of quoted heredocs stopped false
  push/commit routing. `validate-commit-format.sh` still scanned the raw
  command for presence and backticks, so a count==0 visit fallback or a
  direct hook call blocked file writes whose prose named `git commit` and
  held Markdown backticks.
- 2026-10-19 (this record): The commit-format gate builds `_SCAN_CMD` from
  `APEXYARD_GIT_ROUTE_CMD` or `strip_heredoc_bodies … quoted`, then uses
  that text for presence, newline-compound, and backtick checks. Raw
  `COMMAND` still feeds message extraction and the heredoc-substitution
  skip. A real commit whose `-m` holds a command substitution still
  blocks. A message from `-F` is still validated.

## Context

Ticket: me2resh/apexyard#1810. Review agents could not write a review body
file when the body held inline code spans. #1805 fixed dispatcher routing
for the common path; the gate itself still false-blocked when invoked on
the raw command.

## Options considered

| Option | Pros | Cons |
|--------|------|------|
| A. Strip-aware scans inside validate-commit-format (#1810) | Matches AgDR-0262 route text; paired unsafe cases stay blocked | Gate must load the stripper when the dispatcher did not export a route |
| B. Tests only (rely on #1805 dispatch) | Smaller diff | Fail-closed dispatch and direct hook calls still block |
| C. Drop count==0 visit fallback globally | Fixes every commit gate | Wider behaviour change than this ticket |

**Chosen: A.**

## Decision

1. Prefer `APEXYARD_GIT_ROUTE_CMD` when the dispatcher set it.
2. Else strip confirmed quoted heredoc bodies; fail closed if that strip
   returns non-zero after a successful load.
3. If the stripper file is absent, keep scanning the raw command (test
   sandboxes and sparse trees).
4. Keep subject validation, `-F` reads, and the `$(cat <<…)` skip on the
   raw command.

## Consequences

- A `cat > file <<'EOF'` body with backticks is not blocked.
- `git commit -m "… $(…)"` and backtick command substitutions still block.
- `git commit -F <file>` still validates the file subject.

## Artifacts

- `.claude/hooks/validate-commit-format.sh`
- `.claude/hooks/tests/test_validate_commit_format_heredoc.sh`
- `.claude/hooks/tests/fixtures/commit-format-1810-*`
