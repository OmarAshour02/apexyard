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

# A quoted body that a shell, eval or source runs is code, not data.
# Each shape must still reach the push gates (#1805 rebase onto #1804 r4).
real_push = f"git {verb_push} origin feature/GH-1805-x"
runner_shapes = [
    ("fed-bash", f"bash <<'EOF'\ncd /tmp && {real_push}\nEOF"),
    ("fed-sh-s", f"/bin/sh -s <<'EOF'\n{real_push}\nEOF"),
    ("eval-subst", f"eval \"$(cat <<'EOF'\n{real_push}\nEOF\n)\""),
    ("eval-var", f"x=$(cat <<'EOF'\n{real_push}\nEOF\n); eval \"$x\""),
    ("source-stdin", f"source /dev/stdin <<'EOF'\n{real_push}\nEOF"),
    ("dot-stdin", f". /dev/stdin <<'EOF'\n{real_push}\nEOF"),
]
runner_bad = []
for label, cmd in runner_shapes:
    payload = tmp / f"runner-{label}.json"
    payload.write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    log = tmp / f"log-runner-{label}"
    log.write_text("")
    env["DISPATCH_LOG"] = str(log)
    subprocess.run(
        ["/bin/bash", str(new_route / "dispatch-bash.sh")],
        input=payload.read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    if "block-main-push.sh" not in log.read_text():
        runner_bad.append(label)
if runner_bad:
    bad("quoted body run by a shell/eval/source must route push gates: " + ",".join(runner_bad))
else:
    ok(f"quoted body run by a shell/eval/source routes push gates ({len(runner_shapes)} shapes)")

# #1805 B1 (CEO decision 2026-10-20): quoted mode strips a body only for an
# allow-listed data sink. Every other receiver keeps the raw command, so the
# push gates still see the body. Placeholder shapes, one per class.
w_sys = "sys" + "tem"
w_dot = "."
b1_shapes = [
    ("other-shell-tcsh", f"tcsh <<'EOF'\n{real_push}\nEOF"),
    ("other-shell-csh-s", f"/bin/csh -s <<'EOF'\n{real_push}\nEOF"),
    ("other-shell-fish", f"fish <<'EOF'\n{real_push}\nEOF"),
    ("interp-python", f"python3 - <<'EOF'\nimport os\nos.{w_sys}('{real_push}')\nEOF"),
    ("interp-perl", f"perl <<'EOF'\n{w_sys}('{real_push}');\nEOF"),
    ("interp-ruby", f"ruby <<'EOF'\n{w_sys}('{real_push}')\nEOF"),
    ("interp-node", f"node <<'EOF'\nrequire('child_process').execSync('{real_push}')\nEOF"),
    ("dot-in-if-then", f"if true; then {w_dot} /dev/stdin <<'EOF'\n{real_push}\nEOF\nfi"),
    ("dot-in-while-do", f"while true; do {w_dot} /dev/stdin <<'EOF'\n{real_push}\nEOF\nbreak; done"),
    ("backslash-dot", f"\\{w_dot} /dev/stdin <<'EOF'\n{real_push}\nEOF"),
    ("quoted-dot", f"'{w_dot}' /dev/stdin <<'EOF'\n{real_push}\nEOF"),
    ("shell-var-s", f"\"$SHELL\" -s <<'EOF'\n{real_push}\nEOF"),
    ("backslash-split-shell", f"ba\\sh <<'EOF'\n{real_push}\nEOF"),
    ("quote-split-shell", f"b''ash <<'EOF'\n{real_push}\nEOF"),
    ("script-written-then-run", f"cat > /tmp/s1805.sh <<'EOF'\n{real_push}\nEOF\nbash /tmp/s1805.sh"),
    ("script-written-then-exec", f"cat > /tmp/s1805.sh <<'EOF'\n{real_push}\nEOF\nchmod +x /tmp/s1805.sh && /tmp/s1805.sh"),
    ("tee-then-run", f"tee /tmp/s1805.sh <<'EOF'\n{real_push}\nEOF\nsh /tmp/s1805.sh"),
    ("pipe-into-shell", f"cat <<'EOF' | sh\n{real_push}\nEOF"),
    ("group-piped", f"{{ cat <<'EOF'\n{real_push}\nEOF\n}} | bash"),
    ("function-cat", f"cat() {{ bash; }}; cat <<'EOF'\n{real_push}\nEOF"),
    ("xargs", f"xargs -0 bash -c <<'EOF'\n{real_push}\nEOF"),
    ("env-wrapper", f"env bash <<'EOF'\n{real_push}\nEOF"),
]
b1_bad = []
for label, cmd in b1_shapes:
    payload = tmp / f"b1-{label}.json"
    payload.write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    log = tmp / f"log-b1-{label}"
    log.write_text("")
    env["DISPATCH_LOG"] = str(log)
    subprocess.run(
        ["/bin/bash", str(new_route / "dispatch-bash.sh")],
        input=payload.read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    if "block-main-push.sh" not in log.read_text():
        b1_bad.append(label)
if b1_bad:
    bad("non-sink receiver must route push gates: " + ",".join(b1_bad))
else:
    ok(f"non-sink receivers route push gates ({len(b1_shapes)} shapes)")

# Allow-listed data sinks: a prose body that names a push does not route the
# push gates. Each sink has a block twin that must still route them.
prose = f"Review note: run {real_push} after the merge."
w_gh = "g" + "h"
sink_pairs = [
    ("cat-redirect",
     f"cat > /tmp/r1805.md <<'EOF'\n{prose}\nEOF",
     f"cat > /tmp/r1805.md <<'EOF'\n{real_push}\nEOF\nsh /tmp/r1805.md"),
    ("cat-append",
     f"cat >> /tmp/r1805.md <<'EOF'\n{prose}\nEOF",
     f"cat >> /tmp/r1805.md <<'EOF'\n{real_push}\nEOF\n. /tmp/r1805.md"),
    ("cat-noclobber",
     f"cat >| /tmp/r1805.md <<'EOF'\n{prose}\nEOF",
     f"cat >| /tmp/r1805.md <<'EOF'\n{real_push}\nEOF\nbash < /tmp/r1805.md"),
    ("cat-alone",
     f"cat <<'EOF'\n{prose}\nEOF",
     f"cat <<'EOF' | bash\n{real_push}\nEOF"),
    ("cat-pipe-tee",
     f"cat <<'EOF' | tee -a /tmp/r1805.md\n{prose}\nEOF",
     f"cat <<'EOF' | tee /tmp/r1805.md | sh\n{real_push}\nEOF"),
    ("tee-files",
     f"tee /tmp/a1805.md /tmp/b1805.md <<'EOF' >/dev/null\n{prose}\nEOF",
     f"tee >(sh) <<'EOF'\n{real_push}\nEOF"),
    ("host-body-file",
     f"{w_gh} pr comment 1 --body-file - <<'EOF'\n{prose}\nEOF",
     f"{w_gh} pr comment 1 --body-file - <<'EOF'\n{real_push}\nEOF\n{w_gh} pr view 1 --json body -q .body | sh"),
    ("host-dash-F",
     f"{w_gh} issue comment 1 -F - <<'EOF'\n{prose}\nEOF",
     f"{w_gh} alias-x 1 -F - <<'EOF'\n{real_push}\nEOF"),
    ("host-input",
     f"{w_gh} api repos/o/r/issues/1/comments --input - <<'EOF'\n{prose}\nEOF",
     f"{w_gh} api repos/o/r/issues/1/comments --input /tmp/x <<'EOF'\n{real_push}\nEOF"),
    ("git-commit-F",
     f"git {verb_commit} -F - <<'EOF'\nfeat(#1805): note\n\n{prose}\nEOF",
     f"git -c core.editor=sh {verb_commit} -e -F - <<'EOF'\n{real_push}\nEOF"),
    ("git-notes-F",
     f"git notes add -F - <<'EOF'\n{prose}\nEOF",
     f"git notes edit <<'EOF'\n{real_push}\nEOF"),
]
sink_bad = []
for label, allow_cmd, twin_cmd in sink_pairs:
    for kind, cmd in (("allow", allow_cmd), ("twin", twin_cmd)):
        payload = tmp / f"sink-{label}-{kind}.json"
        payload.write_text(json.dumps({
            "tool_name": "Bash",
            "tool_input": {"command": cmd},
            "cwd": str(tmp),
        }))
        log = tmp / f"log-sink-{label}-{kind}"
        log.write_text("")
        env["DISPATCH_LOG"] = str(log)
        subprocess.run(
            ["/bin/bash", str(new_route / "dispatch-bash.sh")],
            input=payload.read_text(),
            text=True,
            capture_output=True,
            cwd=str(tmp),
            env=env,
            check=False,
        )
        routed = "block-main-push.sh" in log.read_text()
        if (kind == "allow" and routed) or (kind == "twin" and not routed):
            sink_bad.append(f"{label}-{kind}")
if sink_bad:
    bad("data-sink allow / twin routing: " + ",".join(sink_bad))
else:
    ok(f"data sinks strip prose and block twins route ({len(sink_pairs)} pairs)")

# Allow twin: runner words only inside the quoted prose body do not route.
twin_cmd = (
    "cat > /tmp/notes.md <<'EOF'\n"
    f"run bash or sh, then eval and source, then {real_push}\n"
    "EOF"
)
(tmp / "runner-twin.json").write_text(json.dumps({
    "tool_name": "Bash",
    "tool_input": {"command": twin_cmd},
    "cwd": str(tmp),
}))
log = tmp / "log-runner-twin"
log.write_text("")
env["DISPATCH_LOG"] = str(log)
subprocess.run(
    ["/bin/bash", str(new_route / "dispatch-bash.sh")],
    input=(tmp / "runner-twin.json").read_text(),
    text=True,
    capture_output=True,
    cwd=str(tmp),
    env=env,
    check=False,
)
if "block-main-push.sh" in log.read_text():
    bad("runner words inside quoted prose must not route push gates")
else:
    ok("runner words inside quoted prose do not route push gates")

# #1829 B1: an earlier heredoc on the start line whose delimiter the
# pattern does not match (a digit or an escaped name). The text between the
# two `<<` must not be lost. A1: a cat or tee target in a hooks directory
# keeps the raw command. Each case must route its gate; the allow twin not.
real_commit = f"git {verb_commit} -m wip"
q = "'"
def route_log(cmd, tag):
    (tmp / f"{tag}.json").write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    lg = tmp / f"log-{tag}"
    lg.write_text("")
    env["DISPATCH_LOG"] = str(lg)
    subprocess.run(
        ["/bin/bash", str(new_route / "dispatch-bash.sh")],
        input=(tmp / f"{tag}.json").read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    return lg.read_text()
hid_shapes = [
    ("digit-push", f"cat <<1; {real_push}; cat <<{q}EOF{q}\n1\nhello\nEOF", "block-main-push.sh"),
    ("escaped-push", f"cat <<\\X; {real_push}; cat <<{q}EOF{q}\nX\nhello\nEOF", "block-main-push.sh"),
    ("digit-commit", f"cat <<1; {real_commit}; cat <<{q}EOF{q}\n1\nhello\nEOF", "validate-commit-format.sh"),
    ("escaped-commit", f"cat <<\\X; {real_commit}; cat <<{q}EOF{q}\nX\nhello\nEOF", "validate-commit-format.sh"),
    ("husky-target", f"cat > .husky/pre-push <<{q}EOF{q}\n{real_push}\nEOF", "block-main-push.sh"),
    ("githooks-tee", f"tee .githooks/pre-push <<{q}EOF{q}\n{real_push}\nEOF", "block-main-push.sh"),
]
hid_bad = [lb for lb, cmd, gate in hid_shapes if gate not in route_log(cmd, f"hid-{lb}")]
if hid_bad:
    bad("earlier heredoc / hooks target must route gates: " + ",".join(hid_bad))
else:
    ok(f"earlier heredoc and hooks targets route gates ({len(hid_shapes)} shapes)")
hid_allow = f"cat <<{q}A{q} > /tmp/h1829.md\n{prose}\nA"
if "block-main-push.sh" in route_log(hid_allow, "hid-allow"):
    bad("allow twin: one quoted sink heredoc with prose must not route push gates")
else:
    ok("allow twin: one quoted sink heredoc with prose does not route push gates")

# Review-body class (#1805, seen after #1804 merged): a quoted heredoc body
# holds an unresolvable cd and a git verb that is not a builtin (an alias
# candidate) in prose. In the original body, the verb word was
# "hash-object" with its closing backtick. The alias check must not scan
# that body. The block twin runs the same words outside the heredoc, so the
# alias check still cannot resolve the repo.
w_git = "g" + "it"
w_cd = "c" + "d"
w_hash = "hash" + "-object"
w_verb = "zf" + "rob"
w_out = '"$' + 'OUT"'
review_body = (
    f"Line 143 is `paths=$({w_cd} {w_out} && find . -print)`.\n"
    f"The reviewer hook blocked `{w_git} {w_hash}` on an export.\n"
    f"Then run {w_git} {w_verb} on the snapshot.\n"
)
alias_allow_cmd = f"cat > /tmp/review-1805.md <<'EOF'\n{review_body}EOF"
alias_block_cmd = f"{w_cd} {w_out} && {w_git} {w_verb}"

def dispatch_route(tree, cmd, tag):
    payload = tmp / f"{tag}.json"
    payload.write_text(json.dumps({
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": str(tmp),
    }))
    log = tmp / f"log-{tag}"
    log.write_text("")
    env["DISPATCH_LOG"] = str(log)
    p = subprocess.run(
        ["/bin/bash", str(tree / "dispatch-bash.sh")],
        input=payload.read_text(),
        text=True,
        capture_output=True,
        cwd=str(tmp),
        env=env,
        check=False,
    )
    return p.returncode, p.stdout + p.stderr

rc, out = dispatch_route(new_route, alias_allow_cmd, "alias-allow")
if rc == 0 and "BLOCKED" not in out:
    ok("quoted review body with cd and git verbs in prose is allowed")
else:
    bad(f"quoted review body with cd and git verbs in prose is allowed; rc={rc} out={out[:240]!r}")
rc, out = dispatch_route(new_route, alias_block_cmd, "alias-block")
if rc == 2 and "cannot resolve the repository for this git alias" in out:
    ok("same cd and git verb outside the heredoc still block")
else:
    bad(f"same cd and git verb outside the heredoc still block; rc={rc} out={out[:240]!r}")
if fb_note:
    print(f"NOTE: skip fail-before (review body): {fb_note}", flush=True)
else:
    base_route = make_dispatch_tree(base_hooks, "base-route", stub_gates=True)
    rc, out = dispatch_route(base_route, alias_allow_cmd, "alias-allow-base")
    if rc == 2 and "git alias" in out:
        ok("fail-before: base blocks the quoted review body")
    else:
        bad(f"fail-before: base blocks the quoted review body; rc={rc} out={out[:240]!r}")

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
