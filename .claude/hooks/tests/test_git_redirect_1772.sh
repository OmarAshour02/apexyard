#!/bin/bash
# #1772 / #1805 step 1: redirections before the git verb still route.
# Fail-before uses the hooks tree at ALIAS_1748 / branch base when set.
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

has_in() {
  local lib="$1" cmd="$2" sub="$3"
  /bin/bash -c '
    . "$1" || exit 1
    if command_has_git_subcommand "$2" "$3"; then exit 0; else exit 1; fi
  ' _ "$lib" "$cmd" "$sub"
}

# Load verbs from this file only (never put them on the parent Shell line).
PUSH_CMD='git push origin feature/GH-1805-x'
COMMIT_CMD='git commit -m x'

cases_push=(
  "git >/dev/null push origin feature/GH-1805-x"
  "git 2>&1 push origin feature/GH-1805-x"
  "git>/tmp/x push origin feature/GH-1805-x"
  "git < /dev/null push origin feature/GH-1805-x"
  "git</dev/null push origin feature/GH-1805-x"
  "git -C /tmp >/dev/null push origin feature/GH-1805-x"
  "git >/dev/null -C /tmp push origin feature/GH-1805-x"
)
cases_commit=(
  "git >/dev/null commit -m x"
  "git 2>/dev/null commit -m x"
)

# Fail-before: archive the branch base (parent of first #1805 commit, or
# REDIRECT_1772_BASE_HOOKS / REDIRECT_1772_BASE_REF).
BASE_HOOKS="${REDIRECT_1772_BASE_HOOKS:-}"
if [ -z "$BASE_HOOKS" ]; then
  BASE_REF="${REDIRECT_1772_BASE_REF:-}"
  if [ -z "$BASE_REF" ]; then
    first_1805=$(git -C "$ROOT" log --reverse --format=%H --fixed-strings --grep='#1805' -1 2>/dev/null || true)
    if [ -n "$first_1805" ]; then
      BASE_REF=$(git -C "$ROOT" rev-parse "${first_1805}^")
    else
      # Uncommitted fix: compare against the last committed hooks tree.
      BASE_REF=HEAD
    fi
  fi
  if git -C "$ROOT" rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    scratch=$(mktemp -d)
    git -C "$ROOT" archive "$BASE_REF" .claude/hooks | tar -x -C "$scratch"
    BASE_HOOKS="$scratch/.claude/hooks"
  fi
fi

if [ -n "${BASE_HOOKS:-}" ] && [ -f "$BASE_HOOKS/_lib-git-global.sh" ]; then
  fb_miss=0
  for cmd in "${cases_push[@]}"; do
    if has_in "$BASE_HOOKS/_lib-git-global.sh" "$cmd" push; then
      fail "fail-before still routes: $cmd"
    else
      fb_miss=$((fb_miss + 1))
    fi
  done
  for cmd in "${cases_commit[@]}"; do
    if has_in "$BASE_HOOKS/_lib-git-global.sh" "$cmd" commit; then
      fail "fail-before still routes: $cmd"
    else
      fb_miss=$((fb_miss + 1))
    fi
  done
  if [ "$fb_miss" -eq $((${#cases_push[@]} + ${#cases_commit[@]})) ]; then
    pass "fail-before: ${fb_miss} redirect cases miss routing on base"
  fi
else
  echo "WARN: no base hooks for fail-before; skipped" >&2
fi

# After-fix: current library routes every redirect case.
if has_in "$HOOKS/_lib-git-global.sh" "$PUSH_CMD" push; then
  pass "plain push still routes"
else
  fail "plain push still routes"
fi
if has_in "$HOOKS/_lib-git-global.sh" "$COMMIT_CMD" commit; then
  pass "plain commit still routes"
else
  fail "plain commit still routes"
fi

for cmd in "${cases_push[@]}"; do
  if has_in "$HOOKS/_lib-git-global.sh" "$cmd" push; then
    pass "routes push: $cmd"
  else
    fail "routes push: $cmd"
  fi
done
for cmd in "${cases_commit[@]}"; do
  if has_in "$HOOKS/_lib-git-global.sh" "$cmd" commit; then
    pass "routes commit: $cmd"
  else
    fail "routes commit: $cmd"
  fi
done

# `git > push` writes to a file named push; it is not a push verb.
if has_in "$HOOKS/_lib-git-global.sh" "git > push" push; then
  fail "file-named push is not a verb"
else
  pass "file-named push is not a verb"
fi

# prepare_invocation skips the redirection and finds the verb.
if /bin/bash -c '
  . "$1" || exit 1
  git_prepare_invocation "git >/dev/null log" log "$PWD"
' _ "$HOOKS/_lib-git-global.sh"; then
  pass "prepare skips redirect before log"
else
  fail "prepare skips redirect before log"
fi

# Dispatcher routes push gates for a redirect-shaped push (stub gates).
TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "${scratch:-}"' EXIT
mkdir -p "$TMP/hooks" "$TMP/bin"
ln -s /bin/bash "$TMP/bin/bash"
PATH="$TMP/bin:$PATH"
cp "$HOOKS/dispatch-bash.sh" "$HOOKS/_lib-awk-fallback.sh" "$HOOKS/_lib-extract-pr.sh" \
  "$HOOKS/_lib-command-scrub.sh" "$HOOKS/_lib-git-global.sh" "$HOOKS/_lib-strip-heredoc.sh" \
  "$TMP/hooks/" 2>/dev/null || true
chmod +x "$TMP/hooks/dispatch-bash.sh"
scripts='block-ambient-tracker-repo.sh block-privileged-escalation.sh require-skill-for-issue-create.sh require-orbit-slice-for-ticket.sh require-migration-ticket.sh require-active-ticket.sh warn-review-marker-write.sh warn-isolated-build-risk.sh block-reviewer-repo-mutation.sh block-reviewer-ci-wait.sh block-forged-menu-approval.sh block-git-add-all.sh block-main-push.sh validate-branch-name.sh pre-push-gate.sh block-agent-routing-drift.sh check-secrets.sh block-onboarding-in-git.sh verify-commit-refs.sh validate-commit-format.sh require-agdr-for-arch-changes.sh warn-bootstrap-scope.sh suggest-ticket-template.sh validate-issue-structure.sh block-private-refs-in-public-repos.sh validate-pr-create.sh require-agdr-for-arch-pr.sh nudge-control-adversarial-test.sh block-unreviewed-merge.sh require-design-review-for-ui.sh block-merge-on-red-ci.sh require-architecture-review.sh detect-role-trigger.sh'
for script in $scripts; do
  cat > "$TMP/hooks/$script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
name=$(basename "$0")
printf '%s\n' "$name" >> "${DISPATCH_LOG:?}"
EOF
  chmod +x "$TMP/hooks/$script"
done

payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
  'git >/dev/null push origin feature/GH-1805-x')
: > "$TMP/log"
printf '%s' "$payload" | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null
if grep -qx 'block-main-push.sh' "$TMP/log" && grep -qx 'validate-branch-name.sh' "$TMP/log"; then
  pass "dispatcher routes push gates for redirect push"
else
  fail "dispatcher routes push gates for redirect push"
  cat "$TMP/log" >&2 || true
fi

payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
  'git >/dev/null commit -m x')
: > "$TMP/log"
printf '%s' "$payload" | DISPATCH_LOG="$TMP/log" "$TMP/hooks/dispatch-bash.sh" >/dev/null
if grep -qx 'check-secrets.sh' "$TMP/log" && grep -qx 'validate-commit-format.sh' "$TMP/log"; then
  pass "dispatcher routes commit gates for redirect commit"
else
  fail "dispatcher routes commit gates for redirect commit"
  cat "$TMP/log" >&2 || true
fi

echo "TOTAL $PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
