#!/bin/sh
# gate-helper.sh: deterministic helper for the /gate skill.
#
# Uses read-only git commands only. Writes plain files under
# <git-dir>/agent-review/, ~/.agent-review/profiles/ and the relay
# directory the user names (never commits). Output is KEY=VALUE lines.
#
# Subcommands:
#   range [COMMIT | A..B]            review range and mode
#   changed-lines BASE TARGET        changed line ranges on the TARGET side (file<TAB>start<TAB>end)
#   in-changed BASE TARGET FILE:LINE ...   is each location inside a changed hunk? (pre-check)
#   mark-pass FROM TARGET            record FROM..TARGET as passed (with patch-ids)
#   status                           last result, whether HEAD passed, what the next run will do
#   export COMMIT DIR                extract a commit with git archive (for verification)
#   report-path TIER                 new report path plus the other record files
#   paths                            print the paths in use
#   profile-init                     create the project profile from the template if missing
#   relay DIR [COMMIT | A..B]        relay directory: its task, the state of each doc, the next step
#   relay-init DIR TIER yes|no [COMMIT | A..B]
#                                    create DIR/task.md; yes|no: is a security review needed
#   relay-seal DIR ROLE [SRC]        seal DIR/ROLE.md (reviewer, security-reviewer, refuter, report);
#                                    with SRC, copy SRC there first (used for the final report)
set -u
# Git for Windows: when usr/bin/sh.exe is started directly (e.g. from PowerShell),
# awk/sed/grep are not on PATH yet. Appending keeps any user-installed tools first.
PATH="${PATH:+$PATH:}/usr/bin:/bin"; export PATH

die() { printf 'ERROR=%s\n' "$*"; exit 2; }
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
gitq() { git -c core.quotePath=false -c diff.noprefix=false -c diff.mnemonicPrefix=false "$@"; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"

TOP=$(git rev-parse --show-toplevel)
GIT_DIR_ABS=$(git rev-parse --absolute-git-dir)
STATE_DIR="$GIT_DIR_ABS/agent-review"
PASSED="$STATE_DIR/passed"
LAST="$STATE_DIR/last.json"
REPO_NAME=$(basename "$TOP")
PROFILE="${AGENT_REVIEW_HOME:-$HOME/.agent-review}/profiles/$REPO_NAME.yml"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SKILL_DIR=$(dirname -- "$SCRIPT_DIR")
# Read stdin: Git for Windows gets "/dev/null" as "nul" and resolves it inside a subdirectory.
EMPTY_TREE=$(git hash-object -t tree --stdin </dev/null)

need_head() { git rev-parse -q --verify HEAD >/dev/null 2>&1 || die "the repository has no commits yet"; }

json_get() {  # json_get KEY: string value from last.json (one key per line)
  [ -f "$LAST" ] || return 0
  tr -d '\r' < "$LAST" | sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

is_merge() {
  n=$(git rev-list --parents -n 1 "$1" | wc -w)
  [ $((n + 0)) -gt 2 ]
}

patch_id() {  # patch-id of a commit; "-" for merges and empty commits
  if is_merge "$1"; then echo "-"; return 0; fi
  pid=$(git show --no-color --no-ext-diff --pretty=format: "$1" | git patch-id --stable | awk 'NR == 1 { print $1 }')
  echo "${pid:--}"
}

passed_sha() { [ -f "$PASSED" ] && grep -q "^$1 " "$PASSED"; }
passed_pid() { [ "$1" != "-" ] && [ -f "$PASSED" ] && grep -q " $1\$" "$PASSED"; }

fork_point() {  # fork point of HEAD and the upstream (or the remote default branch); empty if none
  for ref in '@{upstream}' 'refs/remotes/origin/HEAD'; do
    if git rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
      mb=$(git merge-base HEAD "$ref" 2>/dev/null) || mb=""
      if [ -n "$mb" ]; then echo "$mb"; return 0; fi
    fi
  done
  return 0
}

parent_or_empty() { git rev-parse -q --verify "$1^1" 2>/dev/null || echo "$EMPTY_TREE"; }

worktree_clean() { git diff --quiet HEAD -- 2>/dev/null; }

compute_range() {  # sets MODE BASE TARGET PASS_FROM HEAD_SHA
  arg=${1:-}
  HEAD_SHA=$(git rev-parse HEAD)
  MODE=full
  if [ -z "$arg" ] && [ "$(json_get result)" = "needs_fix" ]; then
    BASE=$(json_get target)
    [ -n "$BASE" ] || die "last.json has no target"
    git rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || die "last reviewed commit $BASE not found"
    TARGET=$HEAD_SHA
    PASS_FROM=$(json_get base)
    [ -n "$PASS_FROM" ] || PASS_FROM=$BASE
    if [ "$BASE" = "$HEAD_SHA" ]; then MODE=recheck_pending; else MODE=recheck; fi
    return 0
  fi
  if [ -n "$arg" ]; then
    case "$arg" in
      *..*)
        BASE=$(git rev-parse -q --verify "${arg%%..*}^{commit}" 2>/dev/null) || die "bad range start: ${arg%%..*}"
        TARGET=$(git rev-parse -q --verify "${arg#*..}^{commit}" 2>/dev/null) || die "bad range end: ${arg#*..}" ;;
      *)
        TARGET=$(git rev-parse -q --verify "$arg^{commit}" 2>/dev/null) || die "bad commit: $arg"
        BASE=$(parent_or_empty "$TARGET") ;;
    esac
    PASS_FROM=$BASE
    return 0
  fi
  TARGET=$HEAD_SHA
  BASE=""
  for c in $(git rev-list --first-parent -n 500 HEAD); do
    if passed_sha "$c"; then BASE=$c; break; fi
  done
  if [ -n "$BASE" ]; then
    if [ "$BASE" = "$HEAD_SHA" ]; then MODE=already_passed; fi
    PASS_FROM=$BASE
    return 0
  fi
  fork=$(fork_point)
  if [ -n "$fork" ] && [ "$fork" != "$HEAD_SHA" ]; then
    # After a rebase the commit ids change; commits whose patch-id already passed need no new review.
    BASE=$fork
    all_known=1
    for c in $(git rev-list --reverse "$fork..HEAD"); do
      if passed_pid "$(patch_id "$c")"; then BASE=$c; else all_known=0; break; fi
    done
    if [ "$all_known" = 1 ]; then BASE=$fork; MODE=verify_only; fi
  else
    BASE=$(parent_or_empty "$HEAD_SHA")
  fi
  PASS_FROM=$BASE
}

commit_list() {  # one line per commit in BASE..TARGET (just TARGET for a root commit)
  if [ "$BASE" = "$EMPTY_TREE" ]; then
    git log --oneline --no-decorate -n 1 "$TARGET"
  else
    git log --oneline --no-decorate -n 50 "$BASE..$TARGET"
  fi
}

cmd_range() {
  need_head
  compute_range "${1:-}"
  print_range
}

print_range() {  # prints the variables set by compute_range or relay_use_task
  if [ "$BASE" = "$EMPTY_TREE" ]; then commits=1; else commits=$(git rev-list --count "$BASE..$TARGET" 2>/dev/null || echo 0); fi
  if worktree_clean; then clean=yes; else clean=no; fi
  if [ "$TARGET" = "$HEAD_SHA" ] && [ "$clean" = yes ]; then read_from=worktree; else read_from=git-show; fi
  echo "MODE=$MODE"
  echo "BASE=$BASE"
  echo "TARGET=$TARGET"
  echo "PASS_FROM=$PASS_FROM"
  echo "HEAD=$HEAD_SHA"
  echo "COMMITS=$commits"
  gitq diff --numstat --no-ext-diff "$BASE" "$TARGET" | awk -F '\t' '{ f++; if ($1 != "-") l += $1 + $2 } END { printf "FILES=%d\nLINES=%d\n", f, l }'
  echo "READ_FROM=$read_from"
  echo "WORKTREE_CLEAN=$clean"
  echo "STATE_DIR=$(native "$STATE_DIR")"
  echo "PROFILE=$(native "$PROFILE")"
  if [ -f "$PROFILE" ]; then echo "PROFILE_EXISTS=yes"; else echo "PROFILE_EXISTS=no"; fi
  echo "COMMIT_LIST<<EOF"
  commit_list
  echo "EOF"
}

cmd_changed_lines() {
  [ $# -ge 2 ] || die "usage: changed-lines BASE TARGET"
  gitq diff -U0 --no-color --no-ext-diff "$1" "$2" | awk '
    /^\+\+\+ / { f = substr($0, 5); sub(/\t$/, "", f); sub(/^b\//, "", f); next }
    /^@@ / {
      split($3, p, ",")
      s = substr(p[1], 2) + 0
      n = (p[2] == "") ? 1 : p[2] + 0
      if (n > 0 && f != "/dev/null") printf "%s\t%d\t%d\n", f, s, s + n - 1
    }'
}

cmd_in_changed() {
  [ $# -ge 3 ] || die "usage: in-changed BASE TARGET FILE:LINE ..."
  base=$1; target=$2; shift 2
  hunks=$(cmd_changed_lines "$base" "$target")
  top_native=$(native "$TOP")
  for item in "$@"; do
    spec=$(printf '%s' "$item" | tr '\\' '/')
    file=${spec%:*}; line=${spec##*:}; line=${line%%-*}
    file=${file#"$top_native"/}; file=${file#"$TOP"/}; file=${file#./}
    case "$line" in ''|*[!0-9]*) printf '%s\tinvalid\n' "$item"; continue ;; esac
    if printf '%s\n' "$hunks" | awk -F '\t' -v f="$file" -v l="$line" '$1 == f && l + 0 >= $2 + 0 && l + 0 <= $3 + 0 { found = 1 } END { exit found ? 0 : 1 }'; then
      printf '%s\tchanged\n' "$item"
    else
      printf '%s\tunchanged\n' "$item"
    fi
  done
}

cmd_mark_pass() {
  [ $# -ge 2 ] || die "usage: mark-pass FROM TARGET"
  target=$(git rev-parse -q --verify "$2^{commit}" 2>/dev/null) || die "bad target: $2"
  mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
  if [ "$1" = "$EMPTY_TREE" ]; then
    list=$target
  else
    list=$(git rev-list "$1..$target" 2>/dev/null) || die "bad range: $1..$target"
  fi
  [ -n "$list" ] || list=$target
  n=0
  for c in $list; do
    if passed_sha "$c"; then continue; fi
    printf '%s %s\n' "$c" "$(patch_id "$c")" >> "$PASSED"
    n=$((n + 1))
  done
  echo "MARKED=$n"
  echo "PASSED_FILE=$(native "$PASSED")"
}

cmd_status() {
  need_head
  HEAD_SHA=$(git rev-parse HEAD)
  echo "HEAD=$HEAD_SHA"
  r=$(json_get result)
  echo "LAST_RESULT=${r:-none}"
  echo "LAST_TARGET=$(json_get target)"
  echo "LAST_REPORT=$(json_get report)"
  if passed_sha "$HEAD_SHA"; then echo "HEAD_PASSED=yes"; else echo "HEAD_PASSED=no"; fi
  compute_range ""
  echo "NEXT_MODE=$MODE"
  case "$MODE" in
    already_passed) n=0 ;;
    *) if [ "$BASE" = "$EMPTY_TREE" ]; then n=1; else n=$(git rev-list --count "$BASE..$TARGET" 2>/dev/null || echo 0); fi ;;
  esac
  echo "UNREVIEWED_COMMITS=$n"
  if git rev-parse -q --verify '@{upstream}' >/dev/null 2>&1; then
    echo "UNPUSHED_COMMITS=$(git rev-list --count '@{upstream}..HEAD')"
  else
    echo "UNPUSHED_COMMITS=unknown"
  fi
}

cmd_export() {
  [ $# -ge 2 ] || die "usage: export COMMIT DIR"
  git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1 || die "bad commit: $1"
  mkdir -p "$2" || die "cannot create $2"
  git archive --format=tar "$1" | tar -xf - -C "$2" || die "export failed"
  echo "EXPORTED_TO=$(native "$2")"
}

cmd_report_path() {
  tier=${1:-T1}
  mkdir -p "$STATE_DIR/reports" || die "cannot create $STATE_DIR/reports"
  echo "REPORT=$(native "$STATE_DIR/reports/$(date +%Y%m%d-%H%M%S)-$tier.md")"
  echo "LAST_JSON=$(native "$LAST")"
  echo "BACKLOG=$(native "$STATE_DIR/backlog.md")"
  echo "LOG=$(native "$STATE_DIR/log.jsonl")"
  echo "NOW=$(date +%Y-%m-%dT%H:%M:%S%z)"
}

cmd_paths() {
  echo "REPO_ROOT=$(native "$TOP")"
  echo "STATE_DIR=$(native "$STATE_DIR")"
  echo "PROFILE=$(native "$PROFILE")"
  if [ -f "$PROFILE" ]; then echo "PROFILE_EXISTS=yes"; else echo "PROFILE_EXISTS=no"; fi
  echo "SKILL_DIR=$(native "$SKILL_DIR")"
}

cmd_profile_init() {
  if [ -f "$PROFILE" ]; then
    echo "PROFILE_CREATED=no"
  else
    mkdir -p "$(dirname "$PROFILE")" || die "cannot create $(dirname "$PROFILE")"
    cp "$SKILL_DIR/templates/review-profile.example.yml" "$PROFILE" || die "cannot create $PROFILE"
    echo "PROFILE_CREATED=yes"
  fi
  echo "PROFILE=$(native "$PROFILE")"
}

# ---- relay directory --------------------------------------------------------
# Lets each role run in a different tool or session. Files in the directory:
#   task.md                range, tier, security flag, intent       (relay-init)
#   reviewer.md, security-reviewer.md, refuter.md   role results    (relay-seal)
#   report.md              copy of the final report      (relay-seal DIR report SRC)
#   previous-report.md     the last report, for recheck tasks       (relay-init)
# Every file starts with a front matter block: "---", "key: value" lines, "---".
# relay-seal writes the keys below and keeps the others (harness, model, ...).
# A doc's inputs are the docs it was built from, as NAME@<hash of their body>,
# so a doc whose inputs changed later shows up as stale.
SEAL_KEYS='^(gate-relay|role|mode|base|target|inputs|result|sealed)$'
BOM=$(printf '\357\273\277')

short() { printf '%.7s' "$1"; }

abs_path() {  # absolute POSIX path; accepts C:\x, C:/x, ~/x and relative paths
  p=$(printf '%s' "$1" | tr '\\' '/')
  case "$p" in '~') p=$HOME ;; '~/'*) p="$HOME/${p#??}" ;; esac
  if command -v cygpath >/dev/null 2>&1; then p=$(cygpath -u "$p"); fi
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "$p" != / ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  printf '%s\n' "$p"
}

# The fm_* readers ignore a UTF-8 BOM and CR line ends.
fm_has() {  # does FILE start with a front matter block?
  awk -v bom="$BOM" '
    { sub(/\r$/, "") }
    NR == 1 && bom != "" && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
    NR == 1 { found = ($0 == "---"); exit }
    END { exit !found }' "$1"
}

fm_closed() {  # false when FILE opens a front matter block that never closes
  awk -v bom="$BOM" '
    { sub(/\r$/, "") }
    NR == 1 && bom != "" && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
    NR == 1 { if ($0 != "---") exit; open = 1; next }
    $0 == "---" { open = 0; exit }
    END { exit open }' "$1"
}

fm_get() {  # fm_get FILE KEY: the value of a top-level KEY in the front matter
  awk -v k="$2" -v bom="$BOM" -v q="'" '
    { sub(/\r$/, "") }
    NR == 1 && bom != "" && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^[^ \t]/ {
      i = index($0, ":"); if (i == 0) next
      key = substr($0, 1, i - 1); sub(/[ \t]+$/, "", key)
      if (key != k) next
      v = substr($0, i + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
      f = substr(v, 1, 1)
      if (length(v) >= 2 && (f == "\"" || f == q) && substr(v, length(v), 1) == f) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$1"
}

fm_extra() {  # the front matter lines relay-seal keeps (everything but SEAL_KEYS)
  awk -v bom="$BOM" -v keys="$SEAL_KEYS" '
    { sub(/\r$/, "") }
    NR == 1 && bom != "" && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^[ \t]*$/ { next }
    /^[^ \t]/ { i = index($0, ":"); key = i ? substr($0, 1, i - 1) : $0; sub(/[ \t]+$/, "", key); drop = (key ~ keys) }
    !drop { print }' "$1"
}

fm_body() {  # the text after the front matter (the whole file when there is none)
  awk -v bom="$BOM" '
    { sub(/\r$/, "") }
    NR == 1 && bom != "" && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm { if ($0 == "---") fm = 0; next }
    { print }' "$1"
}

body_id() { fm_body "$1" | git hash-object --stdin | cut -c1-12; }

count_candidates() {  # [Important] / [Nit] / [Pre-existing] lines in a review doc
  fm_body "$1" | grep -cE '^[[:space:]>*-]*([0-9]+[.)][[:space:]]*)?\[(Important|Nit|Pre-existing)\]'
}

inputs_of() {  # inputs_of NAME ID ...: "NAME@ID" for every non-empty ID
  io_out=""
  while [ $# -ge 2 ]; do
    if [ -n "$2" ]; then io_out="$io_out $1@$2"; fi
    shift 2
  done
  printf '%s\n' "${io_out# }"
}

canon() {  # one spelling per location, for comparing paths
  # Git for Windows mounts some folders twice (e.g. /tmp and /c/Users/.../Temp), so compare
  # the Windows form, case-folded.
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$(abs_path "$1")" | tr 'A-Z' 'a-z'; else abs_path "$1"; fi
}

in_worktree() {  # in_worktree PATH: inside the work tree, and not inside the git dir?
  iw_p=$(canon "$1"); iw_top=$(canon "$TOP"); iw_git=$(canon "$GIT_DIR_ABS")
  case "$iw_p/" in "$iw_git"/*) return 1 ;; "$iw_top"/*) return 0 ;; esac
  return 1
}

relay_load() {  # relay_load DIR: sets RD, TASK_FILE, TASK (missing | incomplete | ready) and T_*
  RD=$(abs_path "$1")
  if [ -e "$RD" ] && [ ! -d "$RD" ]; then die "$(native "$RD") is not a directory"; fi
  TASK_FILE="$RD/task.md"
  T_MODE=""; T_BASE=""; T_TARGET=""; T_PASS_FROM=""; T_TIER=""; T_SECURITY=""
  if [ ! -f "$TASK_FILE" ]; then TASK=missing; return 0; fi
  fm_closed "$TASK_FILE" || die "the front matter of $(native "$TASK_FILE") is not closed"
  if [ "$(fm_get "$TASK_FILE" gate-relay)" != 1 ] || [ "$(fm_get "$TASK_FILE" role)" != task ]; then
    die "$(native "$TASK_FILE") is not a /gate relay task"
  fi
  T_MODE=$(fm_get "$TASK_FILE" mode)
  T_BASE=$(fm_get "$TASK_FILE" base)
  T_TARGET=$(fm_get "$TASK_FILE" target)
  T_PASS_FROM=$(fm_get "$TASK_FILE" pass_from)
  T_TIER=$(fm_get "$TASK_FILE" tier)
  T_SECURITY=$(fm_get "$TASK_FILE" security)
  case "$T_MODE" in full|recheck) ;; *) die "bad mode in $(native "$TASK_FILE"): $T_MODE" ;; esac
  if [ -z "$T_BASE" ] || [ -z "$T_TARGET" ]; then die "$(native "$TASK_FILE") has no base or target"; fi
  [ -n "$T_PASS_FROM" ] || T_PASS_FROM=$T_BASE
  for rl_c in "$T_TARGET" "$T_BASE" "$T_PASS_FROM"; do
    if [ "$rl_c" != "$EMPTY_TREE" ] && ! git rev-parse -q --verify "$rl_c^{commit}" >/dev/null 2>&1; then
      die "commit $rl_c from $(native "$TASK_FILE") is not in this repository (wrong repository, or fetch it first)"
    fi
  done
  TASK=ready
  case "$T_TIER" in T0|T1|T2|T3) ;; *) TASK=incomplete ;; esac
  case "$T_SECURITY" in yes|no) ;; *) TASK=incomplete ;; esac
  if fm_body "$TASK_FILE" | grep -qE 'TODO-(INTENT|TIER-REASON)'; then TASK=incomplete; fi
}

relay_use_task() {  # relay_use_task [COMMIT | A..B]: take the range from task.md; an argument must agree
  if [ -n "${1:-}" ]; then
    compute_range "$1"
    if [ "$BASE" != "$T_BASE" ] || [ "$TARGET" != "$T_TARGET" ]; then
      die "$(native "$TASK_FILE") is for $(short "$T_BASE")..$(short "$T_TARGET"), not $1; use another directory for another range"
    fi
  fi
  HEAD_SHA=$(git rev-parse HEAD)
  MODE=$T_MODE; BASE=$T_BASE; TARGET=$T_TARGET; PASS_FROM=$T_PASS_FROM
}

doc_state() {  # doc_state NAME: missing | done | invalid:<reason>, judged from the file alone
  ds_f="$RD/$1.md"
  if [ ! -f "$ds_f" ]; then echo missing; return 0; fi
  if ! fm_closed "$ds_f"; then echo "invalid:the front matter is not closed"; return 0; fi
  if [ "$(fm_get "$ds_f" gate-relay)" != 1 ]; then echo "invalid:not sealed, run relay-seal"; return 0; fi
  if [ "$(fm_get "$ds_f" role)" != "$1" ]; then echo "invalid:its role is not $1"; return 0; fi
  if [ "$(fm_get "$ds_f" base)" != "$T_BASE" ] || [ "$(fm_get "$ds_f" target)" != "$T_TARGET" ]; then
    echo "invalid:it is for another range than task.md"; return 0
  fi
  echo done
}

relay_scan() {  # sets S_REV S_SEC S_REF S_REP, IN_REFUTER, IN_REPORT, CANDS
  S_REV=$(doc_state reviewer)
  S_SEC=$(doc_state security-reviewer)
  ID_REV=""; ID_SEC=""; ID_REF=""
  if [ "$S_REV" = done ]; then ID_REV=$(body_id "$RD/reviewer.md"); fi
  if [ "$S_SEC" = done ]; then ID_SEC=$(body_id "$RD/security-reviewer.md"); fi
  IN_REFUTER=$(inputs_of reviewer "$ID_REV" security-reviewer "$ID_SEC")
  S_REF=$(doc_state refuter)
  if [ "$S_REF" = done ]; then
    if [ "$(fm_get "$RD/refuter.md" inputs)" = "$IN_REFUTER" ]; then ID_REF=$(body_id "$RD/refuter.md"); else S_REF=stale; fi
  fi
  IN_REPORT=$(inputs_of reviewer "$ID_REV" security-reviewer "$ID_SEC" refuter "$ID_REF")
  S_REP=$(doc_state report)
  if [ "$S_REP" = done ] && [ "$(fm_get "$RD/report.md" inputs)" != "$IN_REPORT" ]; then S_REP=stale; fi
  CANDS=0
  if [ "$S_REV" = done ]; then CANDS=$((CANDS + $(count_candidates "$RD/reviewer.md"))); fi
  if [ "$S_SEC" = done ]; then CANDS=$((CANDS + $(count_candidates "$RD/security-reviewer.md"))); fi
}

relay_next() {  # the suggested next step, from relay_scan
  if [ "$TASK" = incomplete ]; then echo task; return 0; fi
  if [ "$S_REP" = done ]; then echo done; return 0; fi
  if [ "$T_MODE" = full ]; then
    if [ "$T_TIER" != T0 ]; then
      if [ "$S_REV" != done ]; then echo reviewer; return 0; fi
      if [ "$T_SECURITY" = yes ] && [ "$S_SEC" != done ]; then echo security-reviewer; return 0; fi
    fi
    if [ "$CANDS" -gt 0 ] && [ "$S_REF" != done ]; then echo refuter; return 0; fi
  fi
  echo finish
}

print_doc() {  # print_doc KEY STATE
  echo "DOC_$1=${2%%:*}"
  case "$2" in invalid:*) echo "DOC_$1_NOTE=${2#invalid:}" ;; esac
}

print_relay() {
  echo "RELAY_DIR=$(native "$RD")"
  echo "TASK=$TASK"
  echo "TASK_FILE=$(native "$TASK_FILE")"
  if in_worktree "$RD"; then echo "WARNING=the relay directory is inside the work tree; keep its files out of your commits"; fi
  if [ "$TASK" = missing ]; then
    case "$MODE" in full|recheck) echo "NEXT=init" ;; *) echo "NEXT=none" ;; esac
    return 0
  fi
  echo "TIER=$T_TIER"
  echo "SECURITY=$T_SECURITY"
  if [ "$T_MODE" = recheck ]; then
    if [ -f "$RD/previous-report.md" ]; then echo "PREVIOUS_REPORT=$(native "$RD/previous-report.md")"; else echo "PREVIOUS_REPORT=missing"; fi
  fi
  relay_scan
  print_doc REVIEWER "$S_REV"
  print_doc SECURITY_REVIEWER "$S_SEC"
  print_doc REFUTER "$S_REF"
  print_doc REPORT "$S_REP"
  case "$S_REP" in done|stale) echo "REPORT_RESULT=$(fm_get "$RD/report.md" result)" ;; esac
  echo "CANDIDATES=$CANDS"
  echo "NEXT=$(relay_next)"
}

cmd_relay() {
  [ $# -ge 1 ] || die "usage: relay DIR [COMMIT | A..B]"
  need_head
  relay_load "$1"
  if [ "$TASK" = missing ]; then compute_range "${2:-}"; else relay_use_task "${2:-}"; fi
  print_range
  print_relay
}

cmd_relay_init() {
  [ $# -ge 3 ] || die "usage: relay-init DIR TIER yes|no [COMMIT | A..B]"
  need_head
  ri_tier=$2; ri_sec=$3
  case "$ri_tier" in T0|T1|T2|T3) ;; *) die "bad tier: $ri_tier (use T0, T1, T2 or T3)" ;; esac
  case "$ri_sec" in yes|no) ;; *) die "bad security flag: $ri_sec (use yes or no)" ;; esac
  if [ "$ri_tier" = T3 ]; then ri_sec=yes; fi
  relay_load "$1"
  [ "$TASK" = missing ] || die "$(native "$TASK_FILE") already exists; read it with relay"
  compute_range "${4:-}"
  case "$MODE" in full|recheck) ;; *) die "nothing to review: MODE=$MODE" ;; esac
  mkdir -p "$RD" || die "cannot create $(native "$RD")"
  ri_prev=""
  if [ "$MODE" = recheck ]; then
    ri_last=$(json_get report)
    if [ -n "$ri_last" ] && [ -f "$ri_last" ] && cp "$ri_last" "$RD/previous-report.md"; then ri_prev=previous-report.md; fi
  fi
  ( set -C
    {
      echo '---'
      echo 'gate-relay: 1'
      echo 'role: task'
      echo "repo: $REPO_NAME"
      echo "mode: $MODE"
      echo "base: $BASE"
      echo "target: $TARGET"
      echo "pass_from: $PASS_FROM"
      echo "tier: $ri_tier"
      echo "security: $ri_sec"
      if [ "$MODE" = recheck ]; then echo "previous_report: ${ri_prev:-missing}"; fi
      echo "created: $(date +%Y-%m-%dT%H:%M:%S%z)"
      echo '---'
      echo
      echo '# /gate 接力任务'
      echo
      echo '范围、档位（tier）和是否需要安全审查（security）以上面的文件头为准。'
      echo
      echo '## 提交'
      echo
      commit_list | sed 's/^/- /'
      echo
      echo '## 意图'
      echo
      echo 'TODO-INTENT'
      echo
      echo '## 判档理由'
      echo
      echo 'TODO-TIER-REASON'
    } > "$TASK_FILE"
  ) 2>/dev/null || die "cannot create $(native "$TASK_FILE")"
  relay_load "$1"
  relay_use_task ""
  print_range
  print_relay
}

cmd_relay_seal() {
  [ $# -ge 2 ] || die "usage: relay-seal DIR ROLE [SRC]"
  need_head
  relay_load "$1"
  case "$TASK" in
    missing) die "no task.md in $(native "$RD"); create it with relay-init" ;;
    incomplete) die "$(native "$TASK_FILE") is incomplete: fill in tier, security, TODO-INTENT and TODO-TIER-REASON" ;;
  esac
  rs_role=$2
  case "$rs_role" in
    reviewer|report) ;;
    security-reviewer|refuter) [ "$T_MODE" = full ] || die "a recheck task has no $rs_role step" ;;
    *) die "unknown role: $rs_role (use reviewer, security-reviewer, refuter or report)" ;;
  esac
  rs_doc="$RD/$rs_role.md"
  rs_src=$rs_doc
  if [ $# -ge 3 ]; then rs_src=$(abs_path "$3"); fi
  [ -f "$rs_src" ] || die "missing $(native "$rs_src")"
  fm_closed "$rs_src" || die "the front matter of $(native "$rs_src") is not closed"
  relay_scan
  rs_mark=""; rs_inputs=""; rs_result=""
  case "$rs_role:$T_MODE" in
    reviewer:recheck) rs_mark='复查' ;;
    reviewer:full|security-reviewer:full) rs_mark='候选' ;;
    refuter:full)
      rs_mark='复核'
      [ -n "$IN_REFUTER" ] || die "there is no sealed reviewer.md or security-reviewer.md to refute"
      rs_inputs=$IN_REFUTER ;;
    report:*)
      rs_inputs=$IN_REPORT
      rs_result=$(fm_body "$rs_src" | awk 'NF { print; exit }' | grep -oE 'needs_decision|needs_fix|verify_failed|pass' | head -n 1)
      [ -n "$rs_result" ] || die "the first line of the report must give the result: pass, needs_fix, needs_decision or verify_failed"
      if [ "$rs_result" != verify_failed ] && [ "$T_MODE" = full ] && [ "$CANDS" -gt 0 ] && [ "$S_REF" != done ]; then
        die "refuter.md is ${S_REF%%:*}: refute the candidates before sealing the report"
      fi ;;
  esac
  if [ -n "$rs_mark" ] && ! fm_body "$rs_src" | grep -qE "^[[:space:]>*_-]*$rs_mark[*_]*[[:space:]]*(:|：)"; then
    die "$(native "$rs_src") has no line starting with $rs_mark：; paste the role's whole final message"
  fi
  rs_tmp="$rs_doc.tmp$$"
  if {
    echo '---'
    echo 'gate-relay: 1'
    echo "role: $rs_role"
    echo "mode: $T_MODE"
    echo "base: $T_BASE"
    echo "target: $T_TARGET"
    case "$rs_role" in refuter|report) echo "inputs:${rs_inputs:+ $rs_inputs}" ;; esac
    if [ -n "$rs_result" ]; then echo "result: $rs_result"; fi
    echo "sealed: $(date +%Y-%m-%dT%H:%M:%S%z)"
    fm_extra "$rs_src"
    echo '---'
    fm_has "$rs_src" || echo
    fm_body "$rs_src"
  } > "$rs_tmp" && mv -f "$rs_tmp" "$rs_doc"; then :; else
    rm -f "$rs_tmp"
    die "cannot write $(native "$rs_doc")"
  fi
  echo "SEALED=$(native "$rs_doc")"
  echo "ID=$(body_id "$rs_doc")"
  if [ -n "$rs_inputs" ]; then echo "INPUTS=$rs_inputs"; fi
  if [ -n "$rs_result" ]; then echo "RESULT=$rs_result"; fi
  relay_scan
  echo "NEXT=$(relay_next)"
}

cmd=${1:-}
if [ $# -gt 0 ]; then shift; fi
case "$cmd" in
  range) cmd_range "$@" ;;
  changed-lines) cmd_changed_lines "$@" ;;
  in-changed) cmd_in_changed "$@" ;;
  mark-pass) cmd_mark_pass "$@" ;;
  status) cmd_status ;;
  export) cmd_export "$@" ;;
  report-path) cmd_report_path "$@" ;;
  paths) cmd_paths ;;
  profile-init) cmd_profile_init ;;
  relay) cmd_relay "$@" ;;
  relay-init) cmd_relay_init "$@" ;;
  relay-seal) cmd_relay_seal "$@" ;;
  *) awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 2 ;;
esac
