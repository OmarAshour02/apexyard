#!/bin/bash
# Heredoc-body stripping — an ADDITIVE-refinement helper, never a gate filter.
#
# Not a hook itself (prefixed `_lib-`). Sourced by `_lib-extract-push-ref.sh`
# via `. "$(dirname "$0")/_lib-strip-heredoc.sh"`.
#
# WHY THIS EXISTS, AND WHY IT IS ITS OWN FILE (me2resh/apexyard#1066)
# --------------------------------------------------------------------
# A heredoc body (a commit message, a PR body, review prose written via
# `cat > file <<EOF ... EOF`) is literal payload, not a command. Scanning
# the WHOLE raw command text for `git push` / `git commit` — as
# `is_tag_push` / `extract_push_ref` originally did — matches prose that
# merely *mentions* a git command before the real invocation. This function
# strips CONFIRMED heredoc bodies so the ref-extraction / tag-push-exemption
# questions in `_lib-extract-push-ref.sh` see the real command, not prose.
#
# It was split into its own file (rather than living inline in
# `_lib-extract-push-ref.sh`) because it is a genuinely standalone parsing
# primitive with more than one consumer: `_lib-extract-push-ref.sh` uses it
# today, and `verify-commit-refs.sh`'s `resolve_commit_workdir()` (added in
# #1073) parses the same kind of raw-command-text shape (`git -C <path>`,
# `cd <path> &&`) and is a natural second adopter, per the coordinator's
# review. See docs/agdr/AgDR-0113-heredoc-stripper-additive-only.md for the
# full three-way design record and — critically — the governance rule
# below, which every adopter of this file MUST follow.
#
# ============================================================================
# GOVERNANCE — READ BEFORE USING THIS FUNCTION ANYWHERE NEW
# ============================================================================
# `strip_heredoc_bodies` is a SUBTRACTIVE pre-filter: it decides what a
# caller is even ALLOWED to see. That is fundamentally different from
# `extract_push_ref`, which is ADDITIVE: it tries to answer "what is the
# ref", and if it gets that wrong, the caller still has the raw command and
# an independent local-state fallback to fall back on — the failure is
# local and visible.
#
# A bug in a SUBTRACTIVE filter is silent and global: if this function ever
# over-strips (removes text that was actually a real, executing command),
# and a caller used its OUTPUT to decide "is there even a git push/commit
# command here at all", that caller's gate silently never fires. This is
# not hypothetical — it is exactly the bug a security review caught in the
# first version of the #1066 fix (me2resh/apexyard#1075): both
# `validate-branch-name.sh` and `block-main-push.sh` ran their presence
# checks (`grep -qE 'git push'` / `'git commit'`) against text this
# function had already filtered, so eight distinct malformed-heredoc shapes
# (see the AgDR) made the filter eat the real command, and the gate exited
# 0 without ever asking whether a push was happening.
#
# THE RULE: use `strip_heredoc_bodies` (directly, or via `extract_push_ref` /
# `is_tag_push` in `_lib-extract-push-ref.sh`) ONLY to refine an ADDITIVE
# question — "given that a real git operation is independently known (from
# RAW, unfiltered text) to be happening, which ref / is it exempt" — and
# NEVER to decide whether a gate should fire at all. The presence check
# that answers "is there a push/commit here" MUST always run against the
# raw, unfiltered command string. If you are about to write
# `if echo "$STRIPPED_TEXT" | grep -q 'git push'` as a gating condition,
# stop — that is exactly the mistake this comment exists to prevent.
#
# ONE EXCEPTION (AgDR-0262, #1780 / #1805): the dispatcher and
# git_visit_invocations use `quoted` mode for push and commit routing. That
# mode strips a body only when the command that receives it is on a short
# allow-list of data sinks (see _shq_sinks_ok). Any other receiver, and any
# parse doubt, returns the raw command, so the gates see the body.
#
# Strips heredoc BODY text (and the heredoc's own start/terminator lines)
# from a command string, but ONLY for heredocs that are CONFIRMED — both:
#
#   1. ANCHORED: after the delimiter word, the rest of that line (trimmed of
#      leading whitespace) is empty, a `#` comment, or a plain output
#      redirection (`>`, `>>`, an fd redirect like `2>`, or `&>`) — nothing
#      else. A `<<` sitting inside a quoted string, an arithmetic
#      expression (`$((1 << N))`), or followed by `&&` / `||` / `;` / a
#      pipe / another `<<` fails this check and is never treated as a
#      heredoc start. This is what makes `"shift with << N" && git push
#      origin main` and `X=$((1 << N)); git push origin main` and `git
#      commit -m "use a << b shift"` all leave the real command untouched.
#
#   2. TERMINATED: scanning forward from the candidate start, some later
#      line — after tab-stripping for `<<-` — exactly equals the delimiter.
#      If no such line exists anywhere in the rest of the command, the
#      candidate is REJECTED: nothing is stripped for it, and the command
#      from that point on is returned UNCHANGED. An unterminated heredoc
#      (or one whose delimiter this parser can't compute exactly — a
#      backslash-escaped delimiter like `<<E\OF`, a quoted multi-word
#      delimiter like `<<'E O F'`, a delimiter containing a `.` like
#      `<<END.OF`) will therefore never find its (differently-shaped) real
#      terminator line and is safely left un-stripped rather than eating
#      the remainder of the command looking for a terminator that will
#      never arrive. See the AgDR for the deliberate residue this leaves:
#      those exotic delimiter shapes are recognised as *heredoc-like* but
#      never actually stripped, which is safe (nothing is hidden) but means
#      a LEGITIMATE use of one of those shapes doesn't get the "prose is
#      hidden from presence checks" nicety either. Given presence checks
#      never consult this function's output (per the governance rule
#      above), that residue has no safety impact — only a minor UX one.
#
# A line containing a here-STRING (`<<<`) is never treated as a heredoc
# start, so `wc -l <<< "$var"` is left untouched.
#
# Returns: prints the command with CONFIRMED heredoc bodies removed. Always
# exits 0.
#
# Optional second argument:
#   all     (default) — strip every confirmed heredoc
#   quoted  — strip only heredocs whose delimiter is quoted (`<<'EOF'` /
#             `<<"EOF"`). Used by the dispatcher for push/commit routing
#             (#1780 / AgDR-0262). Unquoted heredocs and here-strings keep
#             today's checks. A body is stripped only when its receiver is
#             an allow-listed data sink (_shq_sinks_ok). Otherwise the raw
#             command is returned unchanged.

# --- quoted mode: data-sink allow-list (#1805, AgDR-0262) -----------------
# CEO decision 2026-10-20: strip a quoted body only when the command that
# receives it is a known data sink. These helpers share state through
# dynamic scope with _shq_sinks_ok. Each one returns 1 on any doubt.

# Split $1 into words in _SHQ_T. Words keep their quotes. A separator
# (`|`, `;`, `&`, or a doubled one) is its own word. A comment ends the
# text. Return 1 on an open quote, a substitution, a backquote or a paren.
_shq_split() {
  local s="$1" i=0 n c nc w="" inw=0 q=""
  _SHQ_T=()
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    nc="${s:i+1:1}"
    if [ -n "$q" ]; then
      w+="$c"
      if [ "$q" = '"' ]; then
        case "$c" in
          \\) w+="$nc"; i=$((i + 2)); continue ;;
          '`') return 1 ;;
          '$') [ "$nc" != '(' ] || return 1 ;;
        esac
      fi
      [ "$c" != "$q" ] || q=""
      i=$((i + 1))
      continue
    fi
    case "$c" in
      ' '|"$_shq_tab"|"$_shq_nl")
        if [ "$inw" -eq 1 ]; then _SHQ_T+=("$w"); w=""; inw=0; fi
        ;;
      \'|\") q="$c"; w+="$c"; inw=1 ;;
      \\) w+="$c$nc"; inw=1; i=$((i + 2)); continue ;;
      '`'|'('|')') return 1 ;;
      '$') [ "$nc" != '(' ] || return 1; w+="$c"; inw=1 ;;
      '#')
        [ "$inw" -eq 1 ] || break
        w+="$c"
        ;;
      ';'|'&'|'|')
        # `2>&1` and `>|` belong to the redirection word.
        case "$w" in
          *'>'|*'<')
            if [ "$c" != ';' ]; then w+="$c"; i=$((i + 1)); continue; fi
            ;;
        esac
        if [ "$inw" -eq 1 ]; then _SHQ_T+=("$w"); w=""; inw=0; fi
        if [ "$nc" = "$c" ]; then
          _SHQ_T+=("$c$c")
          i=$((i + 2))
          continue
        fi
        _SHQ_T+=("$c")
        ;;
      *) w+="$c"; inw=1 ;;
    esac
    i=$((i + 1))
  done
  [ -z "$q" ] || return 1
  if [ "$inw" -eq 1 ]; then _SHQ_T+=("$w"); fi
  return 0
}

# 0 when $1 starts with an output or input redirection operator. Sets
# _SHQ_RFD (fd digits), _SHQ_ROP (operator) and _SHQ_RTGT (glued target).
_shq_redir() {
  local re='^([0-9]*)(&>>|&>|>>|>[|]|>&|>|<<<|<&|<)(.*)$'
  [[ "$1" =~ $re ]] || return 1
  _SHQ_RFD="${BASH_REMATCH[1]}"
  _SHQ_ROP="${BASH_REMATCH[2]}"
  _SHQ_RTGT="${BASH_REMATCH[3]}"
  return 0
}

# Check one file target word and record its base name in _SHQ_FILES.
# /dev/null, /dev/stdout and /dev/stderr are not files.
_shq_target() {
  local t="$1" b
  case "$t" in ''|*\\*) return 1 ;; esac
  t="${t//\"/}"
  t="${t//\'/}"
  case "$t" in
    /dev/null|/dev/stdout|/dev/stderr) return 0 ;;
    /dev/*|/proc/*|.git/*|*/.git/*|hooks/*|*/hooks/*) return 1 ;;
  esac
  b="${t##*/}"
  [[ "$b" =~ ^[A-Za-z0-9._+%@,=-]+$ ]] || return 1
  case "$b" in .|..) return 1 ;; esac
  _SHQ_FILES+=("$b")
  return 0
}

# Consume the redirection word at _SHQ_T[_SHQ_J] and its target.
# $1 = 1: stdout may go to a file. $1 = 0: only /dev/null or an fd copy.
_shq_take_redir() {
  local tok="${_SHQ_T[_SHQ_J]-}" tgt
  _shq_redir "$tok" || return 1
  case "$_SHQ_ROP" in '>'|'>>'|'>|'|'>&') ;; *) return 1 ;; esac
  tgt="$_SHQ_RTGT"
  if [ -z "$tgt" ]; then
    _SHQ_J=$((_SHQ_J + 1))
    tgt="${_SHQ_T[_SHQ_J]-}"
    [ -n "$tgt" ] || return 1
    if _shq_redir "$tgt"; then return 1; fi
    case "$tgt" in '|'|'||'|';'|';;'|'&'|'&&') return 1 ;; esac
  fi
  _SHQ_J=$((_SHQ_J + 1))
  if [ "$_SHQ_ROP" = '>&' ]; then
    case "${_SHQ_RFD:-1}:$tgt" in
      1:2|2:1) [ "${_SHQ_RFD:-1}" != 1 ] || _SHQ_OUT=1; return 0 ;;
    esac
    return 1
  fi
  case "${_SHQ_RFD:-1}" in
    1)
      _SHQ_OUT=1
      [ "$tgt" != /dev/null ] || return 0
      [ "$1" = 1 ] || return 1
      _shq_target "$tgt"
      return
      ;;
    2) [ "$tgt" = /dev/null ]; return ;;
  esac
  return 1
}

# tee arguments from _SHQ_J: -a, file words, and redirections.
_shq_tee_args() {
  local n=${#_SHQ_T[@]} tok
  while [ "$_SHQ_J" -lt "$n" ]; do
    tok="${_SHQ_T[_SHQ_J]}"
    case "$tok" in
      -a|--append) _SHQ_J=$((_SHQ_J + 1)); continue ;;
    esac
    if _shq_redir "$tok"; then
      _shq_take_redir 1 || return 1
      continue
    fi
    case "$tok" in -*|'|'|'||'|';'|';;'|'&'|'&&') return 1 ;; esac
    _shq_target "$tok" || return 1
    _SHQ_J=$((_SHQ_J + 1))
  done
  return 0
}

# Arguments of git or a host CLI from _SHQ_J. One option in $1 must take
# `-` (stdin) as its value. $2 lists options that open an editor or change
# config, which this receiver must not have.
_shq_cli_args() {
  local opts="$1" deny="$2" n=${#_SHQ_T[@]} tok prev="" o stdin=0
  while [ "$_SHQ_J" -lt "$n" ]; do
    tok="${_SHQ_T[_SHQ_J]}"
    case "$tok" in '|'|'||'|';'|';;'|'&'|'&&') return 1 ;; esac
    for o in $deny; do
      case "$tok" in "$o"|"$o"=*) return 1 ;; esac
    done
    if _shq_redir "$tok"; then
      _shq_take_redir 0 || return 1
      prev=""
      continue
    fi
    case "$tok" in *'<'*|*'>'*) return 1 ;; esac
    for o in $opts; do
      if { [ "$prev" = "$o" ] && [ "$tok" = - ]; } || [ "$tok" = "$o=-" ]; then
        stdin=1
      fi
    done
    case " $opts :$tok" in *' -F '*:-F-) stdin=1 ;; esac
    prev="$tok"
    _SHQ_J=$((_SHQ_J + 1))
  done
  [ "$stdin" -eq 1 ]
}

# 0 when the receiver words ($1 before the heredoc operator, $2 after the
# delimiter) are an allow-listed data sink:
#   cat [> | >> | >| file] [| tee [-a] file...]
#   tee [-a] file... [> file]
#   git [-C dir] commit|notes ... -F - | --file=-
#   gh pr|issue|release|api ... --body-file - | -F - | --input - | --notes-file -
#   glab mr|issue ... --description -
_shq_receiver_ok() {
  local seg="$1" rest="$2" n
  # A digit before `<<` feeds another fd, not stdin.
  case "$seg" in *[0-9]) return 1 ;; esac
  _shq_split "$seg $rest" || return 1
  n=${#_SHQ_T[@]}
  [ "$n" -gt 0 ] || return 1
  _SHQ_J=1
  _SHQ_OUT=0
  case "${_SHQ_T[0]}" in
    cat)
      while [ "$_SHQ_J" -lt "$n" ]; do
        if [ "${_SHQ_T[_SHQ_J]}" = '|' ]; then
          [ "$_SHQ_OUT" -eq 0 ] || return 1
          [ "${_SHQ_T[_SHQ_J+1]-}" = tee ] || return 1
          _SHQ_J=$((_SHQ_J + 2))
          _shq_tee_args
          return
        fi
        _shq_take_redir 1 || return 1
      done
      return 0
      ;;
    tee)
      _shq_tee_args
      return
      ;;
    git)
      while [ "${_SHQ_T[_SHQ_J]-}" = -C ]; do
        case "${_SHQ_T[_SHQ_J+1]-}" in ''|-*|'|'*|';'*|'&'*|*'<'*|*'>'*) return 1 ;; esac
        _SHQ_J=$((_SHQ_J + 2))
      done
      case "${_SHQ_T[_SHQ_J]-}" in commit|notes) ;; *) return 1 ;; esac
      _SHQ_J=$((_SHQ_J + 1))
      _shq_cli_args '-F --file' '-c -e --edit -t --template'
      return
      ;;
    gh)
      case "${_SHQ_T[1]-}" in pr|issue|release|api) ;; *) return 1 ;; esac
      _SHQ_J=2
      _shq_cli_args '--body-file -F --input --notes-file' '-e --editor'
      return
      ;;
    glab)
      case "${_SHQ_T[1]-}" in mr|issue) ;; *) return 1 ;; esac
      _SHQ_J=2
      _shq_cli_args '--description' '-e --editor'
      return
      ;;
  esac
  return 1
}

# End the current word. Track compound commands at a command position.
_shq_word_end() {
  local w="$_shq_word"
  _shq_word=""
  [ -n "$w" ] || return 0
  [ "$_shq_cmdstart" -eq 1 ] || return 0
  case "$w" in
    if|while|until|for|select|case) _shq_k=$((_shq_k + 1)) ;;
    fi|done|'esac')
      _shq_k=$((_shq_k - 1))
      [ "$_shq_k" -ge 0 ] || return 1
      _shq_cmdstart=0
      ;;
    then|do|else|elif|'!'|time) ;;
    function|coproc) return 1 ;;
    [A-Za-z_]*=*) ;;
    *) _shq_cmdstart=0 ;;
  esac
  return 0
}

# Scan one piece of visible text (text outside the stripped bodies).
# Track quotes, substitutions, groups and the current top-level command
# (_shq_seg). Text of finished top-level commands goes to _shq_out.
# Return 1 on parse doubt: a heredoc this mode does not strip, an
# unbalanced `)`, or a function keyword.
_shq_scan() {
  local s="$1" i=0 n c nc top
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    nc="${s:i+1:1}"
    if [ -n "$_shq_sq" ]; then
      _shq_seg+="$c"
      if [ "$_shq_sq" = A ] && [ "$c" = \\ ]; then
        _shq_seg+="$nc"
        i=$((i + 2))
        continue
      fi
      [ "$c" != "'" ] || _shq_sq=""
      i=$((i + 1))
      continue
    fi
    top="${_shq_stk: -1}"
    if [ "$top" = D ] || [ "$top" = E ]; then
      # Inside "..." or ${...}.
      _shq_seg+="$c"
      case "$c" in
        \\) _shq_seg+="$nc"; i=$((i + 2)); continue ;;
        \") if [ "$top" = D ]; then _shq_stk="${_shq_stk%?}"; else _shq_stk+=D; fi ;;
        \') [ "$top" = D ] || _shq_sq=S ;;
        '}') [ "$top" = D ] || _shq_stk="${_shq_stk%?}" ;;
        '`') _shq_stk+=B ;;
        '$')
          case "$nc" in
            '(') _shq_stk+=C; _shq_seg+="$nc"; i=$((i + 2)); continue ;;
            '{') _shq_stk+=E; _shq_seg+="$nc"; i=$((i + 2)); continue ;;
          esac
          ;;
      esac
      i=$((i + 1))
      continue
    fi
    # Command context: top level, $(...), `...`, (...) or { ...; }.
    case "$c" in
      \\)
        if [ "$nc" = "$_shq_nl" ]; then
          _shq_word_end || return 1
          _shq_seg+=" "
        else
          _shq_seg+="$c$nc"
          _shq_word+="$c$nc"
        fi
        i=$((i + 2))
        continue
        ;;
      \') _shq_sq=S; _shq_seg+="$c"; _shq_word+="$c" ;;
      \") _shq_stk+=D; _shq_seg+="$c"; _shq_word+="$c" ;;
      '`')
        if [ "$top" = B ]; then _shq_stk="${_shq_stk%?}"; else _shq_stk+=B; fi
        _shq_seg+="$c"
        _shq_word+="$c"
        ;;
      '$')
        case "$nc" in
          '('|'{'|\')
            case "$nc" in
              '(') _shq_stk+=C ;;
              '{') _shq_stk+=E ;;
              *) _shq_sq=A ;;
            esac
            _shq_seg+="$c$nc"
            _shq_word+="$c$nc"
            i=$((i + 2))
            continue
            ;;
        esac
        _shq_seg+="$c"
        _shq_word+="$c"
        ;;
      '(') _shq_stk+=P; _shq_seg+="$c"; _shq_word+="$c" ;;
      ')')
        case "$top" in C|P) _shq_stk="${_shq_stk%?}" ;; *) return 1 ;; esac
        _shq_seg+="$c"
        _shq_word+="$c"
        ;;
      '{')
        if [ -z "$_shq_word" ] && [ "$_shq_cmdstart" -eq 1 ]; then
          case "$nc" in
            ' '|"$_shq_tab"|"$_shq_nl"|'')
              _shq_stk+=G
              _shq_seg+="$c"
              i=$((i + 1))
              continue
              ;;
          esac
        fi
        _shq_seg+="$c"
        _shq_word+="$c"
        ;;
      '}')
        if [ -z "$_shq_word" ] && [ "$top" = G ]; then
          _shq_stk="${_shq_stk%?}"
          _shq_cmdstart=0
        else
          _shq_word+="$c"
        fi
        _shq_seg+="$c"
        ;;
      '#')
        if [ -z "$_shq_word" ]; then
          while [ "$i" -lt "$n" ] && [ "${s:i:1}" != "$_shq_nl" ]; do
            i=$((i + 1))
          done
          continue
        fi
        _shq_seg+="$c"
        _shq_word+="$c"
        ;;
      '<')
        if [ "$nc" = '<' ]; then
          # A here-string is a word. Any other `<<` is a heredoc that this
          # mode did not strip, so its body is not parsed: doubt.
          [ "${s:i+2:1}" = '<' ] || return 1
          _shq_seg+='<<<'
          _shq_word+='<<<'
          i=$((i + 3))
          continue
        fi
        _shq_seg+="$c"
        _shq_word+="$c"
        ;;
      ';'|'&'|'|'|"$_shq_nl")
        case "$_shq_word" in
          *'>'|*'<')
            if [ "$c" = '&' ] || [ "$c" = '|' ]; then
              _shq_seg+="$c"
              _shq_word+="$c"
              i=$((i + 1))
              continue
            fi
            ;;
        esac
        _shq_word_end || return 1
        if [ -z "$_shq_stk" ]; then
          _shq_out+="$_shq_seg$c"
          _shq_seg=""
        else
          _shq_seg+="$c"
        fi
        _shq_cmdstart=1
        ;;
      ' '|"$_shq_tab")
        _shq_word_end || return 1
        _shq_seg+="$c"
        ;;
      *) _shq_seg+="$c"; _shq_word+="$c" ;;
    esac
    i=$((i + 1))
  done
  return 0
}

# 0 when every use of file base name $2 in flat text $1 is a data input:
# the value of --body-file, -F, --file, --input or --notes-file of gh, git
# or glab, or an rm argument.
_shq_file_uses_ok() {
  local text="$1" b="$2" seg tok prev first val
  local -a words
  case "$text" in *"$b"*) ;; *) return 0 ;; esac
  text="${text//;/$_shq_nl}"
  text="${text//&/$_shq_nl}"
  while IFS= read -r seg; do
    case "$seg" in *"$b"*) ;; *) continue ;; esac
    read -r -a words <<< "$seg" || :
    first="${words[0]-}"
    case "$first" in gh|git|glab|rm) ;; *) return 1 ;; esac
    [ "$first" != rm ] || continue
    prev=""
    for tok in "${words[@]}"; do
      case "$tok" in
        *"$b"*)
          case "$tok" in
            --body-file=*|--file=*|--input=*|--notes-file=*) val="${tok#*=}" ;;
            -F?*) val="${tok#-F}" ;;
            *)
              case "$prev" in --body-file|-F|--file|--input|--notes-file) ;; *) return 1 ;; esac
              val="$tok"
              ;;
          esac
          [ "$val" = "$b" ] || [ "${val%/"$b"}" != "$val" ] || return 1
          ;;
      esac
      prev="$tok"
    done
  done <<EOF_SHQ_SEGMENTS
$text
EOF_SHQ_SEGMENTS
  return 0
}

# 0 when every stripped quoted heredoc feeds an allow-listed data sink and
# nothing else in the visible text can reach that body. Reads the arrays of
# strip_heredoc_bodies through dynamic scope. Fails closed (returns 1) on
# any doubt.
_shq_sinks_ok() {
  local LC_ALL=C
  local _shq_nl=$'\n' _shq_tab
  _shq_tab="$(printf '\t')"
  local _shq_out="" _shq_seg="" _shq_stk="" _shq_sq="" _shq_word=""
  local _shq_cmdstart=1 _shq_k=0 total=0 idx text flat np b
  local env_re='(^|[^[:alnum:]_])(alias|unalias|function|exec|enable|hash|builtin|command|trap|eval|source|PATH|BASH_ENV)([^[:alnum:]_]|$)'
  _SHQ_FILES=()
  for ((idx = 0; idx < n; idx++)); do
    [ "${skip[idx]}" -eq 0 ] || continue
    if [ "${is_start[idx]}" -eq 1 ]; then
      text="${prefix[idx]}"
    else
      text="${lines[idx]}$_shq_nl"
    fi
    # Bound the per-character scan. Long visible text keeps the raw command.
    total=$((total + ${#text}))
    [ "${#text}" -le 4096 ] && [ "$total" -le 16384 ] || return 1
    _shq_scan "$text" || return 1
    [ "${is_start[idx]}" -eq 1 ] || continue
    _shq_word_end || return 1
    # The receiver must be a plain top-level command: not inside quotes, a
    # substitution, a group, a function body or a compound command whose
    # output a later word can redirect.
    [ -z "$_shq_sq" ] && [ -z "$_shq_stk" ] && [ "$_shq_k" -eq 0 ] || return 1
    _shq_receiver_ok "$_shq_seg" "${hrest[idx]}" || return 1
    _shq_seg=""
    _shq_cmdstart=1
  done
  _shq_word_end || return 1
  [ -z "$_shq_sq" ] && [ -z "$_shq_stk" ] && [ "$_shq_k" -eq 0 ] || return 1
  _shq_out+="$_shq_seg"
  # The rest of the command must not reach a body through an expansion, a
  # glob, a pipe, a process substitution, or a changed command lookup.
  flat="${_shq_out//\"/}"
  flat="${flat//\'/}"
  flat="${flat//\\/}"
  case "$flat" in
    *'$'*|*'`'*|*'*'*|*'?'*|*'['*|*'{'*|*'<('*|*'>('*) return 1 ;;
  esac
  np="${_shq_out//||/}"
  np="${np//>|/}"
  case "$np" in *'|'*) return 1 ;; esac
  if [[ "$_shq_out" =~ $env_re ]]; then return 1; fi
  if [[ "$_shq_out" =~ \([[:space:]]*\) ]]; then return 1; fi
  # A file that a sink wrote may be used only as data input (#1805: a
  # script written and run in the same command keeps the raw command).
  for b in ${_SHQ_FILES[@]+"${_SHQ_FILES[@]}"}; do
    _shq_file_uses_ok "$flat" "$b" || return 1
  done
  return 0
}

strip_heredoc_bodies() {
  local cmd="$1"
  local mode="${2:-all}"
  local stripped_any=0
  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done <<< "$cmd"

  local n=${#lines[@]}
  local -a skip=()
  local -a is_start=()
  local -a prefix=()
  local -a hrest=()
  local idx
  for ((idx = 0; idx < n; idx++)); do
    skip[idx]=0
    is_start[idx]=0
    prefix[idx]=""
    hrest[idx]=""
  done

  local tab
  tab="$(printf '\t')"

  local i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${skip[i]}" -eq 1 ]; then
      i=$((i + 1))
      continue
    fi

    local cur="${lines[i]}"
    local marker=""
    case "$cur" in
      *'<<<'*) marker="" ;; # here-string on this line — never a heredoc start
      *'<<'*)
        marker=$(echo "$cur" \
          | grep -oE '<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?' \
          | head -1)
        ;;
    esac

    if [ -z "$marker" ]; then
      i=$((i + 1))
      continue
    fi

    # #1780: routing may ask for quoted delimiters only.
    if [ "$mode" = quoted ]; then
      case "$marker" in
        *\'*|*\") ;;
        *) i=$((i + 1)); continue ;;
      esac
    fi

    # --- Anchor check -------------------------------------------------
    # Everything after the matched delimiter word, on the SAME line, must
    # be empty / a comment / a plain redirection. Anything else (a closing
    # quote followed by more text, `&&`, `||`, `;`, a bare pipe, another
    # `<<`) means this `<<` was not actually in redirect position.
    local rest rest_trimmed anchor_ok
    rest="${cur#*"$marker"}"
    rest_trimmed="${rest#"${rest%%[![:space:]]*}"}"
    anchor_ok=0
    case "$rest_trimmed" in
      '') anchor_ok=1 ;;
      '#'*) anchor_ok=1 ;;
      '>'*) anchor_ok=1 ;;
      '&>'*) anchor_ok=1 ;;
      [0-9]'>'*) anchor_ok=1 ;;
      # quoted mode: `cat <<'EOF' | tee f`. _shq_sinks_ok checks the rest.
      '|'*) [ "$mode" != quoted ] || anchor_ok=1 ;;
    esac

    if [ "$anchor_ok" -ne 1 ]; then
      i=$((i + 1))
      continue
    fi

    # --- Compute the delimiter word -----------------------------------
    local strip_tabs terminator
    strip_tabs=0
    case "$marker" in
      '<<-'*) strip_tabs=1 ;;
    esac
    terminator="${marker#<<}"
    terminator="${terminator#-}"
    terminator="${terminator#"${terminator%%[![:space:]]*}"}"
    case "$terminator" in
      \"*\") terminator="${terminator#\"}"; terminator="${terminator%\"}" ;;
      \'*\') terminator="${terminator#\'}"; terminator="${terminator%\'}" ;;
    esac

    # --- Confirm termination by scanning FORWARD ----------------------
    local j found check_line
    found=0
    for ((j = i + 1; j < n; j++)); do
      check_line="${lines[j]}"
      if [ "$strip_tabs" -eq 1 ]; then
        while [ "${check_line:0:1}" = "$tab" ]; do
          check_line="${check_line:1}"
        done
      fi
      if [ "$check_line" = "$terminator" ]; then
        found=1
        break
      fi
    done

    if [ "$found" -ne 1 ]; then
      # Unterminated (or a delimiter shape we can't compute exactly, so it
      # will never match) — do NOT strip. Move past just this candidate;
      # everything from here on is left completely untouched.
      i=$((i + 1))
      continue
    fi

    # Confirmed: lines i+1..j are body+terminator — drop them. Line i keeps
    # only whatever precedes the heredoc operator (it may hold a real
    # command, e.g. `cd foo && cat > x.txt <<EOF`).
    prefix[i]="${cur%%<<*}"
    hrest[i]="$rest"
    is_start[i]=1
    stripped_any=1
    local k
    for ((k = i + 1; k <= j; k++)); do
      skip[k]=1
    done
    i=$((j + 1))
  done

  local out=""
  for ((idx = 0; idx < n; idx++)); do
    if [ "${skip[idx]}" -eq 1 ]; then
      continue
    fi
    if [ "${is_start[idx]}" -eq 1 ]; then
      out+="${prefix[idx]}"$'\n'
    else
      out+="${lines[idx]}"$'\n'
    fi
  done

  # #1780 / #1805 (AgDR-0262): in quoted mode, keep the stripped text only
  # when every stripped body feeds an allow-listed data sink. Any other
  # receiver, or any parse doubt, returns the raw command (fail closed).
  if [ "$mode" = quoted ] && [ "$stripped_any" -eq 1 ]; then
    if ! _shq_sinks_ok; then
      printf '%s' "$cmd"
      return 0
    fi
  fi

  printf '%s' "$out"
}
