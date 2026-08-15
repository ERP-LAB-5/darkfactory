#!/usr/bin/env bash
#
# Link darkfactory's shared skills into the projects that use them.
#
#   ./link-skills.sh            create or repair every link
#   ./link-skills.sh --check    report only, change nothing (exit 1 if drifted)
#
# Idempotent. Refuses to touch anything that is not already a symlink, so a real
# skill directory sitting in a project is reported rather than silently replaced.

set -euo pipefail

# skill : target — where the link is created.
#   <name>   a sibling project directory; the link lands in <name>/.claude/skills/
#   ~        the user-level ~/.claude/skills/, loaded in every session on this box
LINKS=(
  "sap-cc-operations      : sap-cc-operator"
  "sap-di-rms-api         : sap-di-autopilot"
  "erplab5-cli-design     : sap-cc-operator"
  "erplab5-cli-design     : sap-di-autopilot"
  "erplab5-security-audit : sap-cc-operator"
  "erplab5-security-audit : sap-di-autopilot"
  "git-commit             : ~"
)

DF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$DF")"          # ~/ERP-LAB-5
CHECK=0
[[ ${1:-} == --check ]] && CHECK=1

rc=0
ok()   { printf '  ok      %s\n' "$1"; }
act()  { printf '  %-7s %s\n' "$1" "$2"; }
fail() { printf '  FAIL    %s\n' "$1"; rc=1; }

printf 'darkfactory skills -> %s\n' "$([[ $CHECK == 1 ]] && echo 'checking' || echo 'linking')"

for entry in "${LINKS[@]}"; do
  skill="$(echo "${entry%%:*}" | xargs)"
  target="$(echo "${entry##*:}" | xargs)"
  src="$DF/skills/$skill"

  if [[ ! -d $src ]]; then
    fail "$skill: no such skill in $DF/skills"
    continue
  fi

  if [[ $target == "~" ]]; then
    dir="$HOME/.claude/skills"
    want="$src"                                     # absolute: crosses out of the tree
  else
    dir="$ROOT/$target/.claude/skills"
    if [[ ! -d $ROOT/$target ]]; then
      fail "$skill: target project $ROOT/$target does not exist"
      continue
    fi
    want="../../../darkfactory/skills/$skill"       # relative: survives a move
  fi

  link="$dir/$skill"
  label="$skill -> ${target}"

  if [[ -L $link ]]; then
    have="$(readlink "$link")"
    if [[ $have == "$want" ]]; then
      ok "$label"
      continue
    fi
    if [[ $CHECK == 1 ]]; then
      fail "$label: points at $have, expected $want"
      continue
    fi
    ln -sfn "$want" "$link"
    act relinked "$label"
    continue
  fi

  if [[ -e $link ]]; then
    fail "$label: $link exists and is not a symlink — move it aside by hand"
    continue
  fi

  if [[ $CHECK == 1 ]]; then
    fail "$label: missing"
    continue
  fi

  mkdir -p "$dir"
  ln -s "$want" "$link"
  act created "$label"
done

# A dangling link is worse than a missing one: Claude Code shows the name and
# then cannot read it.
for entry in "${LINKS[@]}"; do
  skill="$(echo "${entry%%:*}" | xargs)"
  target="$(echo "${entry##*:}" | xargs)"
  [[ $target == "~" ]] && link="$HOME/.claude/skills/$skill" \
                       || link="$ROOT/$target/.claude/skills/$skill"
  if [[ -L $link && ! -e $link ]]; then
    fail "$skill -> $target: link is dangling"
  fi
done

exit $rc
