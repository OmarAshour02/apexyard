#!/bin/bash
# Tests for validate-commit-format.sh's heredoc-substitution skip (#194).
#
# When a commit is invoked as
#   git commit -m "$(cat <<'EOF'
#   subject
#   body
#   EOF
#   )"
# the harness sees the literal `$(cat <<'EOF' ... EOF )` string, not the
# expanded message. The hook's regex over the `-m` value cannot validate
# that string — it would always fail. Pre-194 the hook blocked these
# commits as "malformed subject". Post-194 the hook detects the substitution
# pattern and exits 0 with an INFO message suggesting `git commit -F file`
# for full validation on multi-line messages.
#
# Each case:
#   - builds an isolated sandbox with the hook + helpers
#   - pipes a synthetic PreToolUse JSON for a `git commit ...` command
#   - asserts exit code + (when relevant) stderr content
#
# Exit 0 if all cases pass; 1 on first failure.

set -u

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"


SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)"
HOOK_SRC="$SRC_ROOT/.claude/hooks/validate-commit-format.sh"
LIB_CFG="$SRC_ROOT/.claude/hooks/_lib-read-config.sh"
LIB_STRIP="$SRC_ROOT/.claude/hooks/_lib-strip-heredoc.sh"
DEFAULTS="$SRC_ROOT/.claude/project-config.defaults.json"
FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/fixtures"
# Pre-#1805 / pre-#1810 tip: commit-format still scanned raw heredoc bodies.
PINNED_BEFORE_SHA="e48bbc49125dc2a7e80c2945c7c6e42fe42f4486"

if [ ! -x "$HOOK_SRC" ]; then
  echo "FAIL: hook not found or not executable at $HOOK_SRC" >&2
  exit 1
fi

PASS=0
FAIL=0
FAILED_CASES=""

make_sandbox() {
  local sb
  sb=$(mktemp -d)
  (
    cd "$sb" || exit 1
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
    : > onboarding.yaml
    git add onboarding.yaml
    git commit -q -m "init"
  )
  mkdir -p "$sb/.claude/hooks"
  cp "$HOOK_SRC" "$sb/.claude/hooks/validate-commit-format.sh"
  if [ -f "$LIB_CFG" ]; then cp "$LIB_CFG" "$sb/.claude/hooks/_lib-read-config.sh"; fi
  if [ -f "$LIB_STRIP" ]; then cp "$LIB_STRIP" "$sb/.claude/hooks/_lib-strip-heredoc.sh"; fi
  if [ -f "$DEFAULTS" ]; then cp "$DEFAULTS" "$sb/.claude/project-config.defaults.json"; fi
  chmod +x "$sb/.claude/hooks/validate-commit-format.sh"
  echo "$sb"
}

run_case() {
  local label="$1" cmd="$2" want_rc="$3" want_stderr_regex="$4"
  local sb; sb=$(make_sandbox)
  local input
  input=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}')
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-commit-format.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    cmd: ${cmd:0:200}" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# -- Cases ---------------------------------------------------------------

# Heredoc-substitution shape — pre-194 this blocked; post-194 it skips with INFO.
HEREDOC_CMD='git commit -m "$(cat <<'\''EOF'\''
feat(#194): subject line from heredoc

body line 1
body line 2
EOF
)"'
run_case "heredoc-substitution: skip with INFO" \
  "$HEREDOC_CMD" 0 "heredoc-substitution detected"

# Variation: unquoted heredoc delimiter.
HEREDOC_NOQ_CMD='git commit -m "$(cat <<EOF
feat: subject
EOF
)"'
run_case "heredoc-substitution unquoted delim: skip with INFO" \
  "$HEREDOC_NOQ_CMD" 0 "heredoc-substitution detected"

# Variation: <<- (tab-stripping heredoc).
HEREDOC_DASH_CMD='git commit -m "$(cat <<-'\''EOF'\''
	feat: subject
	EOF
)"'
run_case "heredoc-substitution <<-: skip with INFO" \
  "$HEREDOC_DASH_CMD" 0 "heredoc-substitution detected"

# Shell-looking text in a heredoc is part of the commit message. It must not
# be mistaken for a command chained after the outer `git commit` invocation.
for operator in ';' '&&' '|'; do
  BODY_OPERATOR_CMD="git commit -m \"\$(cat <<'EOF'
body text ${operator} git commit -m \\\"not a command\\\"
EOF
)\""
  run_case "heredoc body containing ${operator} git commit: skip with INFO" \
    "$BODY_OPERATOR_CMD" 0 "heredoc-substitution detected"
done

BODY_CLOSER_TEXT_CMD='git commit -m "$(cat <<'"'"'EOF'"'"'
) && git commit -m "still literal body text"
EOF
)"'
run_case "heredoc body resembling a substitution close: skip with INFO" \
  "$BODY_CLOSER_TEXT_CMD" 0 "heredoc-substitution detected"

HEREDOC_THEN_COMMIT_CMD="$HEREDOC_CMD
git commit -m \"invalid subject\""
run_case "heredoc followed by newline commit: block" \
  "$HEREDOC_THEN_COMMIT_CMD" 2 "newline compound commit commands"

run_case "heredoc followed by semicolon commit: block" \
  "$HEREDOC_CMD ; git commit -m \"invalid subject\"" 2 \
  "does not accept compound commit commands"

run_case "heredoc followed by and commit: block" \
  "$HEREDOC_CMD && git commit -m \"invalid subject\"" 2 \
  "does not accept compound commit commands"

run_case "heredoc followed by pipe commit: block" \
  "$HEREDOC_CMD | git commit -m \"invalid subject\"" 2 \
  "does not accept compound commit commands"

HEREDOC_CONTINUED_COMMIT_CMD="$HEREDOC_CMD \\
&& git commit -m \"invalid subject\""
run_case "heredoc followed by continued and commit: block" \
  "$HEREDOC_CONTINUED_COMMIT_CMD" 2 \
  "does not accept compound commit commands"

BACKTICK=$(printf '\140')
run_case "backtick command substitution: block" \
  "git commit -m \"fix: valid subject\" $BACKTICK git commit -m \"invalid subject\" $BACKTICK" 2 \
  "backtick command substitutions"

# Plain non-substitution -m → still validated as before.
run_case "plain -m valid subject: pass silently" \
  'git commit -m "feat(#194): valid subject"' 0 ""

run_case "plain -m bad subject: BLOCK" \
  'git commit -m "not a valid subject line"' 2 "BLOCKED: Commit subject"

run_case "plain -m '\''quoted'\'' valid subject: pass" \
  "git commit -m 'fix: a fix'" 0 ""

# The first -m value is the subject. A later -m value becomes the body.
run_case "multiple -m: valid subject and body pass" \
  'git commit -m "chore: valid subject" -m "body text"' 0 ""

# A later commit in a compound command must not bypass validation.
run_case "compound command with later invalid commit: block" \
  'git commit -m "fix: valid subject" && git commit -m "invalid subject"' 2 \
  "does not accept compound commit commands"

run_case "semicolon command with later invalid commit: block" \
  'git commit -m "fix: valid subject" ; git commit -m "invalid subject"' 2 \
  "does not accept compound commit commands"

run_case "newline command with later invalid commit: block" \
  $'git commit -m "fix: valid subject"\ngit commit -m "invalid subject"' 2 \
  "newline compound commit commands"

run_case "nested commit command substitution: block" \
  'git commit -m "fix: valid subject"$(git commit -m "invalid subject")' 2 \
  "does not accept command substitutions"

# A quoted value for another option must not impersonate a -m argument.
run_case "trailer decoy with equals syntax: invalid subject blocks" \
  "git commit --trailer='-m \"fix: decoy\"' -m \"invalid subject\"" 2 "BLOCKED: Commit subject"

run_case "trailer decoy with separate value: invalid subject blocks" \
  'git commit --trailer "-m fix: decoy" -m "invalid subject"' 2 "BLOCKED: Commit subject"

run_case "quoted subject text containing -m: valid subject passes" \
  'git commit -m "fix: describe -m safely"' 0 ""

# -F file path → no heredoc substitution involved, full validation runs.
# The skip pattern is anchored on `-m \$(cat <<` literally, so -F is never
# affected.
run_case "git commit -F (no -m): no heredoc skip applied" \
  'git commit -F /nonexistent/path' 0 ""

# A literal "$(cat <<" in a non--m position must NOT trigger the skip
# (e.g. `git commit -m "feat: subject" --trailer '...'` with a comment
# elsewhere). In practice this is hard to trigger without -m; this case
# documents the negative.
run_case "no heredoc-substitution: bad subject still blocks" \
  'git commit -m "junk"' 2 "BLOCKED: Commit subject"

# Non-commit command → no-op.
run_case "non-commit command exits 0 silently" \
  "git status" 0 ""

# -- #1810: quoted heredoc body is data; real commits still checked --------

run_case_from_fixture() {
  local label="$1" fixture="$2" want_rc="$3" want_stderr_regex="$4"
  local sb; sb=$(make_sandbox)
  local got_stderr got_rc
  got_stderr=$(cd "$sb" && bash .claude/hooks/validate-commit-format.sh < "$fixture" 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"

  if [ "$got_rc" != "$want_rc" ]; then
    echo "FAIL [$label]: want rc=$want_rc, got $got_rc" >&2
    echo "    stderr: ${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  if [ -n "$want_stderr_regex" ] && ! echo "$got_stderr" | grep -qE "$want_stderr_regex"; then
    echo "FAIL [$label]: stderr did not match /$want_stderr_regex/" >&2
    echo "    stderr: $got_stderr" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}

# File-writing quoted heredoc with Markdown backticks (and a git commit
# mention in the body) must not be blocked by commit-format.
run_case_from_fixture "1810 file-write heredoc with backticks: pass" \
  "$FIXTURES/commit-format-1810-filewrite-backticks.json" 0 ""

# A real commit whose -m holds a command substitution still blocks.
run_case_from_fixture "1810 -m with \$(…) command substitution: block" \
  "$FIXTURES/commit-format-1810-m-cmdsub.json" 2 \
  "does not accept command substitutions"

run_case_from_fixture "1810 -m with backtick command substitution: block" \
  "$FIXTURES/commit-format-1810-m-backtick-sub.json" 2 \
  "backtick command substitutions"

# A message read from a file is still checked as today.
run_case_F_file() {
  local label="1810 git commit -F bad subject: block"
  local sb; sb=$(make_sandbox)
  cp "$FIXTURES/commit-format-1810-F-bad-subject.txt" "$sb/msg.txt"
  local input got_stderr got_rc
  input=$(jq -nc --arg c "git commit -F msg.txt" '{tool_input:{command:$c}}')
  got_stderr=$(cd "$sb" && echo "$input" | bash .claude/hooks/validate-commit-format.sh 2>&1 >/dev/null)
  got_rc=$?
  rm -rf "$sb"
  if [ "$got_rc" != 2 ] || ! echo "$got_stderr" | grep -qE 'BLOCKED: Commit subject'; then
    echo "FAIL [$label]: want rc=2 and subject block, got rc=$got_rc stderr=${got_stderr:0:300}" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}
run_case_F_file

# Fail-before: pinned pre-#1805 tip still blocks the file-write fixture.
fail_before_1810() {
  local label="1810 fail-before pinned tip blocks file-write backticks"
  if ! git -C "$SRC_ROOT" cat-file -e "${PINNED_BEFORE_SHA}^{commit}" 2>/dev/null; then
    echo "NOTE: skip fail-before: pinned commit ${PINNED_BEFORE_SHA} missing"
    return
  fi
  local scratch before_hook
  scratch=$(mktemp -d)
  if ! git -C "$SRC_ROOT" archive "$PINNED_BEFORE_SHA" \
      .claude/hooks/validate-commit-format.sh \
      .claude/hooks/_lib-strip-heredoc.sh \
      2>/dev/null | tar -x -C "$scratch"; then
    echo "NOTE: skip fail-before: cannot archive hooks from ${PINNED_BEFORE_SHA}"
    rm -rf "$scratch"
    return
  fi
  before_hook="$scratch/.claude/hooks/validate-commit-format.sh"
  if grep -q 'APEXYARD_GIT_ROUTE_CMD\|_SCAN_CMD' "$before_hook" 2>/dev/null; then
    echo "NOTE: skip fail-before: pinned hook already contains the #1810 scan path"
    rm -rf "$scratch"
    return
  fi
  local sb got_rc
  sb=$(mktemp -d)
  mkdir -p "$sb/.claude/hooks"
  cp "$before_hook" "$sb/.claude/hooks/validate-commit-format.sh"
  if [ -f "$scratch/.claude/hooks/_lib-strip-heredoc.sh" ]; then
    cp "$scratch/.claude/hooks/_lib-strip-heredoc.sh" "$sb/.claude/hooks/_lib-strip-heredoc.sh"
  fi
  chmod +x "$sb/.claude/hooks/validate-commit-format.sh"
  set +e
  bash "$sb/.claude/hooks/validate-commit-format.sh" \
    < "$FIXTURES/commit-format-1810-filewrite-backticks.json" >/dev/null 2>&1
  got_rc=$?
  set -e
  rm -rf "$sb" "$scratch"
  if [ "$got_rc" -ne 2 ]; then
    echo "FAIL [$label]: want rc=2 on pinned tip, got $got_rc" >&2
    FAIL=$((FAIL+1)); FAILED_CASES="${FAILED_CASES}${label} "
    return
  fi
  echo "PASS [$label]"
  PASS=$((PASS+1))
}
fail_before_1810

# ---- Summary ------------------------------------------------------------

echo ""
echo "==================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==================================="
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAILED_CASES" >&2
  exit 1
fi
exit 0
