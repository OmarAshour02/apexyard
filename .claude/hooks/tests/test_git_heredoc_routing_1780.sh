#!/bin/bash
# #1780 / #1805 step 2: quoted-heredoc routing, timing, and visit-once.
# Fixture bodies are written with the Write/Python tools — never built by a
# Bash heredoc that names push or commit verbs (that is the bug under test).
set -eu
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd)
HOOKS="$ROOT/.claude/hooks"
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

TMP=$(mktemp -d)
scratch=""
trap 'rm -rf "$TMP" "${scratch:-}"' EXIT

python3 - "$TMP" "$HOOKS" "$ROOT" <<'PY'
import collections, json, os, pathlib, re, shutil, subprocess, sys, tempfile, time

tmp, hooks, root = map(pathlib.Path, sys.argv[1:4])
pass_n = fail_n = 0
def ok(msg):
    global pass_n; pass_n += 1; print("PASS:", msg, flush=True)
def bad(msg):
    global fail_n; fail_n += 1; print("FAIL:", msg, flush=True)

# --- build fixtures without naming verbs on a parent shell command line ---
verb_push = "push"
verb_commit = "commit"
kw_chunk = (
    f"Review note: remember to run git {verb_push} after git {verb_commit}. "
    "Also see gh pr create and gh pr merge in the docs. "
)
kw_body = ""
while len(kw_body) < 16384:
    kw_body += kw_chunk
kw_body = kw_body[:16384]
plain_body = ("lorem ipsum dolor sit amet. " * 800)[:16384]

def heredoc_cmd(body, quoted=True):
    delim = "'EOF'" if quoted else "EOF"
    return f"cat > /tmp/x.md <<{delim}\n{body}\nEOF"

kw_cmd = heredoc_cmd(kw_body, quoted=True)
plain_cmd = heredoc_cmd(plain_body, quoted=True)
unquoted_cmd = heredoc_cmd(
    f"please git {verb_push} origin feature/GH-1805-x later", quoted=False
)
here_string_cmd = f'wc -l <<< "git {verb_push} origin feature/GH-1805-x"'

# Real push after cd + quoted heredoc (negative: gates must still fire).
real_push_cmd = (
    f"cd /tmp; cat > /tmp/x.md <<'EOF'\n"
    f"prose about git {verb_push} origin main\n"
    f"EOF\n"
    f"git {verb_push} origin feature/GH-1805-x"
)

(tmp / "kw.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": kw_cmd},
    "cwd": str(tmp),
}))
(tmp / "plain.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": plain_cmd},
    "cwd": str(tmp),
}))
(tmp / "real.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": real_push_cmd},
    "cwd": str(tmp),
}))
(tmp / "unquoted.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": unquoted_cmd},
    "cwd": str(tmp),
}))
(tmp / "herestring.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": here_string_cmd},
    "cwd": str(tmp),
}))

# Fail-before: archive the hooks tree at a pinned dev commit. The pin is the
# dev commit before #1805 (the #1804 squash). A squash merge keeps it on dev.
# HEREDOC_1780_BASE_REF overrides the pin.
FAIL_BEFORE_PIN = "5eb65c0f9cba2456c1a7fd41b56edc0a65f2c784"
base_ref = os.environ.get("HEREDOC_1780_BASE_REF") or FAIL_BEFORE_PIN
fb_note = ""
have = subprocess.run(
    ["git", "-C", str(root), "rev-parse", "--verify", "--quiet",
     base_ref + "^{commit}"],
    check=False, capture_output=True, text=True,
)
base_hooks = None
if have.returncode != 0:
    # Shallow CI clones can miss the pinned commit.
    fb_note = f"pinned base {base_ref} is not in this clone"
else:
    # Inside tmp, so the shell EXIT trap removes it.
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="heredoc-1780-base-", dir=str(tmp)))
    archive = subprocess.check_output(
        ["git", "archive", base_ref, ".claude/hooks"], cwd=root
    )
    subprocess.run(["tar", "-x", "-C", str(scratch)], input=archive, check=True)
    base_hooks = scratch / ".claude/hooks"
    disp = base_hooks / "dispatch-bash.sh"
    if not disp.is_file():
        fb_note = "no base dispatch-bash.sh"
    elif "APEXYARD_GIT_ROUTE_CMD" in disp.read_text():
        # The base already has the fix, so it cannot show the old timeout.
        fb_note = f"base {base_ref} already strips quoted heredocs"

def run_dispatch(hooks_dir, payload_path, locale="en_US.UTF-8", timeout=20):
    env = dict(os.environ)
    env["LC_ALL"] = locale
    env["PATH"] = str(tmp / "bin") + os.pathsep + env.get("PATH", "")
    p = subprocess.Popen(
        ["/bin/bash", str(hooks_dir / "dispatch-bash.sh")],
        stdin=open(payload_path, "r"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        cwd=str(tmp),
        env=env,
        start_new_session=True,
    )
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out + err, None
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, 9)
        out, err = p.communicate()
        return 124, (out or "") + (err or ""), "timeout"

# Stub always-on hooks. Keep real push/commit gates so timing and routing
# exercise git_visit_invocations. Real _lib-* files stay from src_hooks.
def make_dispatch_tree(src_hooks, label, stub_gates=False):
    dest = tmp / label
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src_hooks, dest)
    always = [
        "block-ambient-tracker-repo.sh", "block-privileged-escalation.sh",
        "require-skill-for-issue-create.sh", "require-orbit-slice-for-ticket.sh",
        "require-migration-ticket.sh", "require-active-ticket.sh",
        "warn-review-marker-write.sh", "warn-isolated-build-risk.sh",
        "block-reviewer-repo-mutation.sh", "block-reviewer-ci-wait.sh",
        "block-forged-menu-approval.sh", "block-git-add-all.sh",
        "suggest-ticket-template.sh", "validate-issue-structure.sh",
        "block-private-refs-in-public-repos.sh", "validate-pr-create.sh",
        "require-agdr-for-arch-pr.sh", "nudge-control-adversarial-test.sh",
        "block-unreviewed-merge.sh", "require-design-review-for-ui.sh",
        "block-merge-on-red-ci.sh", "require-architecture-review.sh",
        "detect-role-trigger.sh",
    ]
    gates = [
        "block-main-push.sh", "validate-branch-name.sh", "pre-push-gate.sh",
        "block-agent-routing-drift.sh", "check-secrets.sh",
        "block-onboarding-in-git.sh", "verify-commit-refs.sh",
        "validate-commit-format.sh", "require-agdr-for-arch-changes.sh",
        "warn-bootstrap-scope.sh",
    ]
    # Always-on stubs must exit 0 without requiring DISPATCH_LOG (timing runs).
    always_stub = '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n'
    gate_stub = (
        '#!/usr/bin/env bash\nset -euo pipefail\ncat >/dev/null\n'
        'printf \'%s\\n\' "$(basename "$0")" >> "${DISPATCH_LOG:?}"\n'
    )
    for name in always:
        path = dest / name
        path.write_text(always_stub)
        path.chmod(0o755)
    if stub_gates:
        for name in gates:
            path = dest / name
            path.write_text(gate_stub)
            path.chmod(0o755)
    return dest

(tmp / "bin").mkdir(exist_ok=True)
bash_link = tmp / "bin" / "bash"
if not bash_link.exists():
    bash_link.symlink_to("/bin/bash")

# Timing trees keep real push/commit gates. Routing trees stub the gates
# so DISPATCH_LOG shows which groups ran.
new_time = make_dispatch_tree(hooks, "new-time", stub_gates=False)
new_route = make_dispatch_tree(hooks, "new-route", stub_gates=True)

# Fail-before: 16KB keyword body times out or exceeds 3s / falsely blocks.
if fb_note:
    print(f"NOTE: skip fail-before: {fb_note}", flush=True)
else:
    base_time = make_dispatch_tree(base_hooks, "base-time", stub_gates=False)
    t0 = time.perf_counter()
    rc, out, note = run_dispatch(base_time, tmp / "kw.json", "en_US.UTF-8", timeout=25)
    base_dt = time.perf_counter() - t0
    base_bad = (rc == 124) or (base_dt > 3.0) or (rc == 2)
    if base_bad:
        ok(f"fail-before kw 16KB base_dt={base_dt:.3f}s rc={rc} note={note}")
    else:
        bad(f"fail-before expected slow/block; base_dt={base_dt:.3f}s rc={rc} out={out[:200]!r}")

# After-fix timing under UTF-8 and C (real gates; prose must not block).
# One warm-up run, then three timed runs. Every timed sample must be <= 3s.
for locale in ("en_US.UTF-8", "C"):
    run_dispatch(new_time, tmp / "kw.json", locale, timeout=20)
    times = []
    last_rc = 0
    out = ""
    timed_ok = True
    for _ in range(3):
        t0 = time.perf_counter()
        rc, out, note = run_dispatch(new_time, tmp / "kw.json", locale, timeout=20)
        last_rc = rc
        dt = time.perf_counter() - t0
        times.append(dt)
        if note == "timeout" or dt > 3.0 or rc != 0:
            timed_ok = False
            break
    if timed_ok:
        ok(f"kw 16KB {locale} times={['%.3f'%t for t in times]} max={max(times):.3f}s rc={last_rc}")
    else:
        bad(f"kw 16KB {locale} times={['%.3f'%t for t in times]} rc={last_rc} (want each <=3s, rc=0) out={(out or '')[:240]!r}")

# Prose mention must not route push gates (log has no block-main-push).
log = tmp / "log-prose"
log.write_text("")
env = dict(os.environ, DISPATCH_LOG=str(log), PATH=str(tmp / "bin") + os.pathsep + os.environ.get("PATH", ""))
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "kw.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
log_txt = log.read_text()
if "block-main-push.sh" in log_txt or "check-secrets.sh" in log_txt:
    bad("prose quoted heredoc must not route push/commit gates")
else:
    ok("prose quoted heredoc does not route push/commit gates")

# Negative: real push after cd + heredoc reaches every push gate.
log = tmp / "log-real"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "real.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
log_txt = log.read_text()
needed = [
    "block-main-push.sh", "validate-branch-name.sh", "pre-push-gate.sh",
    "block-agent-routing-drift.sh",
]
missing = [n for n in needed if n not in log_txt]
if missing:
    bad("real push after heredoc missing gates: " + ",".join(missing))
else:
    ok("real push after cd+heredoc reaches push gates")

# Unquoted heredoc: still routes (current checks) when body names the verb.
log = tmp / "log-unquoted"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "unquoted.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
if "block-main-push.sh" in log.read_text():
    ok("unquoted heredoc still routes push gates")
else:
    bad("unquoted heredoc still routes push gates")

# Here-string: still routes.
log = tmp / "log-hs"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "herestring.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
if "block-main-push.sh" in log.read_text():
    ok("here-string still routes push gates")
else:
    bad("here-string still routes push gates")

# Length cap fail-closed.
script = r'''
set -eu
. "$1"
export _GIT_CHAIN_SEGMENTS_MAX=100
if _git_chain_segments "$(printf 'x%.0s' {1..200})" >/dev/null 2>"$2"; then
  exit 1
fi
grep -q 'too long' "$2"
'''
err = tmp / "cap.err"
rc = subprocess.run(
    ["/bin/bash", "-c", script, "_", str(hooks / "_lib-git-global.sh"), str(err)],
).returncode
if rc == 0:
    ok("length cap fails closed with clear message")
else:
    bad("length cap fails closed with clear message")

print(f"TOTAL {pass_n} passed; {fail_n} failed", flush=True)
# Stash counts for the outer bash wrapper
(tmp / "counts").write_text(f"{pass_n} {fail_n}\n")
sys.exit(1 if fail_n else 0)
PY
rc=$?
if [ -f "$TMP/counts" ]; then
  read -r PASS FAIL < "$TMP/counts" || true
fi
echo "OUTER TOTAL ${PASS:-?} passed; ${FAIL:-?} failed (python rc=$rc)"
[ "$rc" -eq 0 ]
