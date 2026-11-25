#!/bin/sh
# local-gate installer (macOS / Linux / Git Bash on Windows)
# Installs the /gate skill and its subagents for Claude Code, Codex,
# Kimi Code (kcode), ZCode and DeepSeek Harness.
#
#   sh install.sh                          install for every tool found
#   sh install.sh --target claude,codex    install for the named tools
#   sh install.sh --uninstall [--target ...]
#   sh install.sh --dry-run
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SKILL_SRC="$HERE/skills/gate"
SUB_SRC="$HERE/subagents"
ROLES="reviewer refuter security-reviewer"
MARK=".local-gate-install"
ALL_TARGETS="claude codex kcode zcode deepseek"
# Codex, Kimi Code, ZCode and DeepSeek Harness all read ~/.agents/skills,
# so they share one copy there; Claude Code gets its own copy.
SHARED_SKILL="$HOME/.agents/skills/gate"

usage() {
  cat <<'EOF'
Usage: sh install.sh [--target NAMES] [--uninstall] [--dry-run] [--force]

  --target NAMES  claude, codex, kcode (Kimi Code), zcode, deepseek (DeepSeek Harness)
                  or all. Separate several names with commas or spaces.
                  Default: auto = every tool whose config folder exists.
  --uninstall     remove what this script installed
  --dry-run       show the actions without changing anything
  --force         replace a "gate" skill or gate-* agent that this script did not install

Env overrides: CLAUDE_CONFIG_DIR, CODEX_HOME, KIMI_CODE_HOME, ZCODE_STORAGE_DIR, DSH_HOME
EOF
}

die() { echo "error: $*" >&2; exit 1; }

targets=""; action=install; dry=0; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --target|-t)
      shift
      while [ $# -gt 0 ]; do
        case "$1" in -*) break ;; esac
        targets="$targets $1"; shift
      done ;;
    --target=*) targets="$targets ${1#*=}"; shift ;;
    --uninstall) action=uninstall; shift ;;
    --dry-run) dry=1; shift ;;
    --force) force=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
targets=$(printf '%s' "$targets" | tr ',' ' ')

[ -f "$SKILL_SRC/SKILL.md" ] || die "cannot find $SKILL_SRC/SKILL.md"

home_of() {
  case "$1" in
    claude) echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" ;;
    codex) echo "${CODEX_HOME:-$HOME/.codex}" ;;
    kcode) echo "${KIMI_CODE_HOME:-$HOME/.kimi-code}" ;;
    zcode) echo "${ZCODE_STORAGE_DIR:-$HOME/.zcode}" ;;
    deepseek) echo "${DSH_HOME:-$HOME/.dsh}" ;;
  esac
}
label_of() {
  case "$1" in
    claude) echo "Claude Code" ;;
    codex) echo "Codex" ;;
    kcode) echo "Kimi Code" ;;
    zcode) echo "ZCode" ;;
    deepseek) echo "DeepSeek Harness" ;;
  esac
}
agent_kind() {
  case "$1" in
    claude) echo claude ;;
    codex) echo codex ;;
    kcode|zcode) echo markdown ;;
    *) echo none ;;
  esac
}
invoke_of() {
  case "$1" in
    codex) echo '$gate' ;;
    kcode) echo '/skill:gate' ;;
    *) echo '/gate' ;;
  esac
}
normalize() {
  case "$1" in
    claude|claude-code|claudecode) echo claude ;;
    codex) echo codex ;;
    kcode|kimi|kimi-code) echo kcode ;;
    zcode) echo zcode ;;
    deepseek|dsh|deepseek-harness) echo deepseek ;;
    all) echo all ;;
    auto) echo auto ;;
    *) echo "" ;;
  esac
}

# Paths written into SKILL.md must work from PowerShell too, so use C:/... on Windows.
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
sh_path() {
  # On Windows prefer Git's bin/sh.exe launcher: it puts awk, sed etc. on PATH
  # even when the skill runs the helper from PowerShell.
  if command -v cygpath >/dev/null 2>&1; then
    root=$(cygpath -m / 2>/dev/null); root=${root%/}
    for c in "$root/bin/sh.exe" "$root/usr/bin/sh.exe"; do
      if [ -f "$c" ]; then echo "$c"; return 0; fi
    done
    native "$(command -v sh)"
  else
    echo sh
  fi
}

fill_placeholders() {  # fill_placeholders FILE SKILL_DIR SH
  sd=$(printf '%s' "$2" | sed 's/[\\&|]/\\&/g')
  sp=$(printf '%s' "$3" | sed 's/[\\&|]/\\&/g')
  sed -e "s|{{SKILL_DIR}}|$sd|g" -e "s|{{SH}}|$sp|g" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

read_targets() {  # targets recorded in an installed copy's marker file
  if [ -f "$1/$MARK" ]; then tr -d '\r' < "$1/$MARK" | sed -n 's/^target=//p'; fi
}

install_skill() {  # install_skill DEST TARGET...
  dest=$1; shift
  echo "  skill: $dest"
  if [ -e "$dest" ] && [ ! -f "$dest/$MARK" ] && [ "$force" != 1 ]; then
    echo "  skip: $dest exists and was not installed by this script (use --force to replace it)"
    return 1
  fi
  if [ "$dry" = 1 ]; then echo "  [dry-run] copy skills/gate to $dest"; return 0; fi
  old=$(read_targets "$dest")
  rm -rf "$dest" || die "cannot remove $dest"
  mkdir -p "$(dirname "$dest")" || die "cannot create $(dirname "$dest")"
  cp -R "$SKILL_SRC" "$dest" || die "cannot copy the skill to $dest"
  fill_placeholders "$dest/SKILL.md" "$(native "$dest")" "$SH" || die "cannot update $dest/SKILL.md"
  {
    echo "installed-by=local-gate"
    for x in $old "$@"; do echo "target=$x"; done | sort -u
  } > "$dest/$MARK" || die "cannot write $dest/$MARK"
  return 0
}

remove_skill() {  # remove_skill DEST TARGET...
  dest=$1; shift
  if [ ! -f "$dest/$MARK" ]; then
    if [ -e "$dest" ]; then echo "  kept $dest (not installed by this script)"; fi
    return 0
  fi
  left=""
  for x in $(read_targets "$dest"); do
    keep=1
    for y in "$@"; do if [ "$x" = "$y" ]; then keep=0; fi; done
    if [ "$keep" = 1 ]; then left="$left $x"; fi
  done
  if [ -z "$left" ]; then
    if [ "$dry" = 1 ]; then echo "  [dry-run] remove $dest"; else rm -rf "$dest" && echo "  removed $dest"; fi
  elif [ "$dry" = 1 ]; then
    echo "  [dry-run] keep $dest, still used by:$left"
  else
    { echo "installed-by=local-gate"; for x in $left; do echo "target=$x"; done; } > "$dest/$MARK"
    echo "  kept $dest, still used by:$left"
  fi
}

write_agents() {  # write_agents TARGET
  t=$1
  kind=$(agent_kind "$t")
  if [ "$kind" = none ]; then
    echo "  subagents: none needed, the skill uses the built-in subagent tool"
    return 0
  fi
  dir="$(home_of "$t")/agents"
  if [ "$dry" != 1 ]; then mkdir -p "$dir" || die "cannot create $dir"; fi
  for r in $ROLES; do
    name="gate-$r"
    if [ "$kind" = codex ]; then
      out="$dir/$name.toml"; head="$SUB_SRC/codex/$name.head.toml"
    else
      out="$dir/$name.md"; head="$SUB_SRC/$kind/$name.head.md"
    fi
    if [ -f "$out" ] && ! grep -q "installed-by: local-gate" "$out" && [ "$force" != 1 ]; then
      echo "  skip: $out exists and was not installed by this script"
      continue
    fi
    if [ "$dry" = 1 ]; then echo "  [dry-run] write $out"; continue; fi
    {
      cat "$head"
      cat "$SKILL_SRC/roles/$r.md"
      if [ "$kind" = codex ]; then cat "$SUB_SRC/codex/tail.toml"; fi
    } > "$out" || die "cannot write $out"
    echo "  agent: $out"
  done
}

remove_agents() {  # remove_agents TARGET
  dir="$(home_of "$1")/agents"
  for r in $ROLES; do
    for out in "$dir/gate-$r.md" "$dir/gate-$r.toml"; do
      if [ -f "$out" ] && grep -q "installed-by: local-gate" "$out"; then
        if [ "$dry" = 1 ]; then echo "  [dry-run] remove $out"; else rm -f "$out" && echo "  removed $out"; fi
      fi
    done
  done
}

# ---- resolve the target list ----
has_all=0; list=""
for raw in $targets; do
  t=$(normalize "$raw")
  [ -n "$t" ] || die "unknown target: $raw"
  case "$t" in
    all) has_all=1 ;;
    auto) ;;
    *) case " $list " in *" $t "*) ;; *) list="$list $t" ;; esac ;;
  esac
done
if [ "$has_all" = 1 ]; then
  list=$ALL_TARGETS
elif [ -z "$list" ]; then
  for t in $ALL_TARGETS; do
    if [ -d "$(home_of "$t")" ]; then list="$list $t"; fi
  done
  [ -n "$list" ] || die "no supported tool found; use --target"
  echo "detected:$list"
fi

SH=$(sh_path)
CLAUDE_SKILL="$(home_of claude)/skills/gate"
has_claude=0; shared=""
for t in $list; do
  case "$t" in claude) has_claude=1 ;; *) shared="$shared $t" ;; esac
done

if [ "$action" = uninstall ]; then
  for t in $list; do
    echo "== $(label_of "$t")"
    remove_agents "$t"
  done
  if [ "$has_claude" = 1 ]; then echo "== Claude Code skill"; remove_skill "$CLAUDE_SKILL" claude; fi
  if [ -n "$shared" ]; then echo "== Shared skill"; remove_skill "$SHARED_SKILL" $shared; fi
  exit 0
fi

ok_claude=1; ok_shared=1
if [ "$has_claude" = 1 ]; then
  echo "== Claude Code skill"
  install_skill "$CLAUDE_SKILL" claude || ok_claude=0
fi
if [ -n "$shared" ]; then
  echo "== Shared skill for:$shared"
  install_skill "$SHARED_SKILL" $shared || ok_shared=0
fi
for t in $list; do
  if [ "$t" = claude ]; then ok=$ok_claude; else ok=$ok_shared; fi
  [ "$ok" = 1 ] || continue
  h=$(home_of "$t")
  echo "== $(label_of "$t") ($h)"
  if [ ! -d "$h" ]; then echo "  note: $h not found, the tool may not be installed"; fi
  write_agents "$t"
  echo "  run it with: $(invoke_of "$t")"
done
echo
echo "Done. Commit locally, then run the skill by hand in your tool."
echo "The first run creates ~/.agent-review/profiles/<repo>.yml - fill in its checks."
