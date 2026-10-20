# Route git push and commit gates past redirections and quoted heredoc prose

> In the context of the Bash dispatcher and shared git matcher, facing (1) a
> redirection before the subcommand that skipped push and commit routing and
> (2) quoted-heredoc prose that named those verbs and timed out the visitor, I
> decided to skip redirections (with a full shell-word target) in the shared
> grammar, strip a confirmed quoted heredoc body before push and commit
> routing only when the whole command is one allow-listed data sink, visit each real
> invocation once on that stripped text, and replace the per-character chain
> segmenter with one awk pass plus a length cap, to keep the gates correct
> and inside a 3 s budget, accepting that unquoted heredocs, here-strings and
> every other command shape still route on the raw command and that a
> strip load failure fails closed by running both gate groups.

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
  merge-shape matching. The alias check and the visitor read the stripped
  text (or `APEXYARD_GIT_ROUTE_CMD`). Make `_git_chain_segments` one awk pass
  with a 64 KiB fail-closed cap and a per-command cache. Partially refines
  AgDR-0113 for dispatcher routing only; additive presence rules for
  ref extraction stay in force.
- 2026-10-20 (CEO decision, Code Reviewer B1 on PR #1829): the first
  version kept a body when the stripped text named a runner from a short
  deny-list (`sh`, `bash`, `eval`, `source`, `.` and others). Other shells,
  interpreters, quote-split or backslash-split runner words, dot commands
  after a reserved word, a shell in a variable, and a script written and run
  in the same command were not on that list. The base blocked them. The
  first version did not. The CEO chose to invert the default: strip only
  for an allow-list of data sinks (Decision 5).
- 2026-10-20 (Code Reviewer B2 on PR #1829): a redirection target unit with
  no whitespace stopped at a quoted target with a space or at a
  substitution target. The verb stayed hidden. The target unit is now one
  full shell word, and an unmatched target fails closed (Decision 1).
- 2026-10-20 (CEO decision: narrow to single-command sinks after 5 review
  rounds on PR #1829): rounds 2 to 4 found more ways for other text in the
  same command to reach or hide around a stripped body (an earlier heredoc
  with an unmatched delimiter, a line continuation that splits `<<`, a
  file that a later command reads by an implicit name, a git or gh config
  file, a hooks path in another repo). The CEO chose to strip only when
  the whole command is one data sink (Decision 5). The multi-command
  allow-list and the written-file checks are removed.

## Context

Ticket: me2resh/apexyard#1805 (umbrella). Children: #1772 (redirect
routing), #1780 (heredoc timeout / false route). The investigation findings
are in #1777.

AgDR-0113 forbids using `strip_heredoc_bodies` to decide whether a gate
fires, because an over-strip can fail open. #1780 needs a subtractive route
filter for quoted heredoc **data**. The control is fail-closed: if the
stripper cannot load or returns non-zero, the dispatcher runs both push and
commit gate groups. A body is data only when a known data sink receives it
and the command holds nothing else.
The allow-list makes that a positive check, so a receiver that the filter
does not know keeps the raw command (AgDR-0113: a subtractive filter must
not decide whether a gate fires on a guess). A negative test keeps a real
`git push` after `cd` and a quoted heredoc on the gate path.

## Options considered

| Option | Pros | Cons |
|--------|------|------|
| A. Strip quoted heredocs at dispatch; linearise segments; visit stripped text | Hits the measured root cause; keeps merge-shape matching on raw text | Must keep fail-closed strip and unquoted/here-string behaviour |
| B. Absolute timeout only | Simple | Still false-blocks prose; does not fix #1772 |
| C. Drop visitor for compound commands | Avoids cost | Weakens cd/-C resolution |

**Chosen: A.**

## Decision

1. **#1772** — Extend `_git_sub_re` / `_git_scan_globals` so a redirection
   before the verb is skipped like the shell does. Require a non-empty
   redirection target so `git > push` is not treated as a push verb. The
   target is one full shell word: plain characters, escaped characters,
   quoted parts (a space is allowed inside), and one level of `$(...)` or
   backquote substitution. The no-jq payload pattern uses the same units.
   When the target is a word that these units cannot match (a nested
   substitution, a quote inside a substitution) or is not closed, and a
   push or commit word follows, `git_uncertain_protected_shape` returns
   true. The dispatcher then runs both gate groups, and the gates block.
   The no-jq path blocks the same shape.
2. **#1780** — Call `strip_heredoc_bodies "$COMMAND" quoted` on the raw
   command, then join continuations on its output (#1829 B1b: the stripper
   must see each backslash-newline). Export `APEXYARD_GIT_ROUTE_CMD`
   for gate visitors. Run the dispatcher alias check on that stripped text
   so quoted heredoc prose is not scanned. Keep `COMMAND` raw for
   merge-shape matching. Gate-level `git_alias_check` in
   `git_visit_invocations` reads the same stripped text.
3. **Visit once** — `git_visit_invocations` matches on the stripped route text
   and warms/export the segment cache once per visit.
4. **Linear segments** — `_git_chain_segments` uses `_run_awk_or_fallback` with
   the former Bash loop as fallback. Cap default 65536 bytes; above that,
   print a clear BLOCKED message and return 2.
5. **Single-command data sinks (CEO decision, 2026-10-20: narrow to
   single-command sinks after 5 review rounds)** — In `quoted` mode,
   `strip_heredoc_bodies` keeps the stripped text only when the whole Bash
   command, without that one heredoc body, is exactly ONE simple command
   that is a data sink, with nothing before or after it. Otherwise it
   returns the raw command unchanged. The sinks are:
   - `cat > file` or `cat >> file`. The heredoc operator can come before
     or after the redirection (`cat <<'X' > file`).
   - `cat <<'X' | tee [-a] file`. This is the only pipe that is allowed.
   - `tee [-a] file`.
   - `git commit ... -F -` or `--file=-`.
   - `git notes add|append ... -F -` or `--file=-`.
   - `gh pr|issue|release create|comment|edit ... --body-file -` or `-F -`.
   Each sink has one file target. The target must be a plain relative or
   absolute path with no quotes. No part of it may be `..`, a `.git*` name,
   `.husky`, `hooks`, `.hooks` or `githooks`. The file must not be a
   symbolic link. Its resolved directory must exist and must not be inside
   the git dir, `$XDG_CONFIG_HOME`, or a home-directory dot file or dot
   directory (this includes `$HOME/.config`). The hooks-path check reads
   `core.hooksPath` (with `~` expanded) in the target's repo and in the
   current repo. When a hooks path is set and does not resolve to a
   directory, or the target is inside it, the function returns the raw
   command.
   The function returns the raw command for all other text: `;`, `&&`,
   `||`, `&`, a pipe other than the `tee` form, a second heredoc or a
   here-string, any other visible line, a line continuation anywhere in the
   visible text, a subshell, a group, a substitution or any `$` expansion,
   a backslash, a glob, an assignment prefix, a quoted command word, `cd`,
   a redirection other than the one target, the git options `-c`, `-C`,
   `-e`, `--edit`, `--editor`, `-t` and `--template`, and the gh options
   `-e`, `--editor`, `-w` and `--web`. Any parse doubt (an unclosed quote,
   an earlier `<<` on the start line or on the logical line that
   continuations join, visible text over 4 KiB) also returns the raw
   command. The dispatcher strips the raw command and then joins
   continuations, because bash removes a backslash-newline before it reads
   operators: `<\<newline><` is one `<<` (#1829 B1b).
   Shapes that stay on the raw command, as on the base, include
   `git commit -m "$(cat <<'EOF' ... )"` (the receiver is inside a
   substitution), a multi-line `gh` command with continuations before the
   body, a sink after `cd`, and a body file that a later command in the
   same Bash call reads.

## Consequences

- A 16 KB quoted heredoc whose prose names push/commit finishes in 3 s or
  less (UTF-8 and `LC_ALL=C`) and does not route those gates.
- A real push after `cd` and a quoted heredoc still reaches every push gate.
- Unquoted heredocs and here-strings still route when they name the verbs.
- A quoted body in any command other than a single allow-listed data sink
  still routes, because the raw command is kept. That scan can be slow for
  a large body, and a dispatcher timeout blocks (fail closed).
- A quoted redirection target with a space, or a substitution target, no
  longer hides the verb. A target the grammar cannot match fails closed.
- No other command runs in the same Bash call as a stripped body, so no
  command in that call can read a file that the sink wrote.
- Residual: a later Bash call can use a file, a commit message or a pull
  request body that a sink wrote. This is out of scope. It is the same
  class as a file written by the Write tool, which the text gates did not
  see before this change either.
- Dispatcher and visitor alias checks use the stripped route text so quoted
  heredoc prose is not scanned. Real alias verbs outside those bodies still
  block. Merge-shape matching stays on the raw command.

## Artifacts

- `.claude/hooks/_lib-git-global.sh`
- `.claude/hooks/dispatch-bash.sh`
- `.claude/hooks/_lib-strip-heredoc.sh` (`quoted` mode)
- `.claude/hooks/tests/test_git_redirect_1772.sh`
- `.claude/hooks/tests/test_git_heredoc_routing_1780.sh`
