# Route git push and commit gates past redirections and quoted heredoc prose

> In the context of the Bash dispatcher and shared git matcher, facing (1) a
> redirection before the subcommand that skipped push and commit routing and
> (2) quoted-heredoc prose that named those verbs and timed out the visitor, I
> decided to skip redirections in the shared grammar, strip confirmed quoted
> heredoc bodies before push and commit routing, visit each real invocation
> once on that stripped text, and replace the per-character chain segmenter
> with one awk pass plus a length cap, to keep the gates correct and inside a
> 3 s budget, accepting that unquoted heredocs and here-strings still route
> as they do today and that a strip load failure fails closed by running both
> gate groups.

## Status

Accepted. AgDR-0262. Implements me2resh/apexyard#1805 (fixes #1772 and #1780).
Stacked on AgDR-0253 / PR #1804.

### Architecture evolution

- 2026-10-19: Shared `_git_sub_re` treated only global options between `git`
  and the verb. A redirection in that position (`git >/dev/null push`,
  `git>file push`) made `command_has_git_subcommand` miss, so push and commit
  gates never ran (#1772).
- 2026-10-19: Push and commit routing scanned the raw command, including
  quoted heredoc bodies. Prose that named `git push` or `git commit` routed
  eight hooks into `git_visit_invocations`. `_git_chain_segments` was a
  per-character Bash loop (quadratic under UTF-8). Cost grew with mention
  count times text length (investigation #1777 / #1780).
- 2026-10-19 (this record): Skip redirection tokens in the shared grammar and
  in `_git_scan_globals`. Strip confirmed **quoted** heredoc bodies before
  push and commit routing in `dispatch-bash.sh`. Keep the raw command for
  merge-shape matching and for `git_alias_check`. Visit on the stripped text
  (or `APEXYARD_GIT_ROUTE_CMD`). Make `_git_chain_segments` one awk pass with
  a 64 KiB fail-closed cap and a per-command cache. Partially refines
  AgDR-0113 for dispatcher routing only; additive presence rules for
  ref extraction stay in force.

## Context

Ticket: me2resh/apexyard#1805 (umbrella). Children: #1772 (redirect routing),
#1780 (heredoc timeout / false route). Investigation findings: #1777.

AgDR-0113 forbids using `strip_heredoc_bodies` to decide whether a gate
fires, because an over-strip can fail open. #1780 needs a subtractive route
filter for quoted heredoc **data**. The control is fail-closed: if the
stripper cannot load or returns non-zero, the dispatcher runs both push and
commit gate groups. A negative test keeps a real `git push` after `cd` and a
quoted heredoc on the gate path.

## Options considered

| Option | Pros | Cons |
|--------|------|------|
| A. Strip quoted heredocs at dispatch; linearise segments; visit stripped text | Hits the measured root cause; keeps merge/alias on raw text | Must keep fail-closed strip and unquoted/here-string behaviour |
| B. Absolute timeout only | Simple | Still false-blocks prose; does not fix #1772 |
| C. Drop visitor for compound commands | Avoids cost | Weakens cd/-C resolution |

**Chosen: A.**

## Decision

1. **#1772** — Extend `_git_sub_re` / `_git_scan_globals` so a redirection
   before the verb is skipped like the shell does. Require a non-empty
   redirection target so `git > push` is not treated as a push verb.
2. **#1780** — After continuation join, call
   `strip_heredoc_bodies "$_scan_cmd" quoted`. Export `APEXYARD_GIT_ROUTE_CMD`
   for gate visitors. Run the dispatcher alias check on that stripped text
   so quoted heredoc prose is not scanned. Keep `COMMAND` raw for
   merge-shape matching. Gate-level `git_alias_check` in
   `git_visit_invocations` reads the same stripped text.
3. **Visit once** — `git_visit_invocations` matches on the stripped route text
   and warms/export the segment cache once per visit.
4. **Linear segments** — `_git_chain_segments` uses `_run_awk_or_fallback` with
   the former Bash loop as fallback. Cap default 65536 bytes; above that,
   print a clear BLOCKED message and return 2.
5. **Runner bodies stay code** — A quoted body that a shell, `eval`,
   `source` or `.` runs is code, not data. Examples are `bash <<'EOF'`,
   `eval "$(cat <<'EOF'`, and `x=$(cat <<'EOF' ...); eval "$x"`. In `quoted`
   mode, when the stripped text still names one of these runners,
   `strip_heredoc_bodies` returns the raw command unchanged. A grep error
   also returns the raw command. The rebase onto #1804 round 4 found this
   case (`G7-r4-shell-notes`).

## Consequences

- A 16 KB quoted heredoc whose prose names push/commit finishes in 3 s or
  less (UTF-8 and `LC_ALL=C`) and does not route those gates.
- A real push after `cd` and a quoted heredoc still reaches every push gate.
- Unquoted heredocs and here-strings still route when they name the verbs.
- A quoted body that a shell, `eval` or `source` runs still routes. A
  command that also names a runner outside the body keeps the raw scan. That
  scan can be slow for a large body, and a dispatcher timeout blocks (fail
  closed).
- Dispatcher and visitor alias checks use the stripped route text so quoted
  heredoc prose is not scanned. Real alias verbs outside those bodies still
  block. Merge-shape matching stays on the raw command.

## Artifacts

- `.claude/hooks/_lib-git-global.sh`
- `.claude/hooks/dispatch-bash.sh`
- `.claude/hooks/_lib-strip-heredoc.sh` (`quoted` mode)
- `.claude/hooks/tests/test_git_redirect_1772.sh`
- `.claude/hooks/tests/test_git_heredoc_routing_1780.sh`
