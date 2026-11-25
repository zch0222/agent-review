#!/bin/sh
# gate-helper.sh: deterministic helper for the /gate skill.
#
# Uses read-only git commands only. Writes plain files under
# <git-dir>/agent-review/ and ~/.agent-review/profiles/ (never commits).
# Output is KEY=VALUE lines.
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
EMPTY_TREE=$(git hash-object -t tree /dev/null)

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

cmd_range() {
  need_head
  compute_range "${1:-}"
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
  if [ "$BASE" = "$EMPTY_TREE" ]; then
    git log --oneline --no-decorate -n 1 "$TARGET"
  else
    git log --oneline --no-decorate -n 50 "$BASE..$TARGET"
  fi
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
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
