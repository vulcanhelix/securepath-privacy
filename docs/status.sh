#!/usr/bin/env bash
# docs/status.sh — derive backlog state from GitHub issues + git, not hand edits.
# State per backlog ID:
#   MERGED   : claude/<id> branch merged into origin/main (or issue closed with merged PR)
#   IN-FLIGHT: worktree or branch exists, issue open
#   BLOCKED-EXT: issue carries blocked-ext label
#   TODO     : issue open, no branch
# Usage: docs/status.sh [W1-02 ...]   (default: all IDs in BACKLOG.md)
set -euo pipefail
cd "$(dirname "$0")/.."
git fetch origin --quiet 2>/dev/null || true

declare -A ISSUE=(
[W0-00]=9  [W0-01]=10 [W0-02]=11 [W0-03]=12 [W0-04]=13 [W0-05]=14
[W1-01]=15 [W1-02]=16 [W1-03]=17 [W1-04]=18 [W1-05]=19 [W1-06]=20 [W1-07]=21 [W1-08]=22 [W1-09]=23
[W2-00]=24 [W2-01]=25 [W2-02]=26 [W2-03]=27 [W2-15]=28 [W2-04]=29 [W2-05]=30 [W2-06]=31 [W2-07]=32
[W2-08]=33 [W2-09]=34 [W2-10]=35 [W2-11]=36 [W2-12]=37 [W2-13]=38 [W2-14]=39 [W2-16]=40 [W2-17]=41
[W3-01]=42 [W3-02]=43 [W3-03]=44 [W3-04]=45 [W3-05]=46
[W4-00]=47 [W4-01]=48 [W4-02]=49 [W4-03]=50 [W4-04]=51 [W4-05]=52 [W4-06]=53 [W4-07]=54 [W4-08]=55 [W4-09]=56
[W5-01]=57 [W5-02]=58
)

ids=("$@")
[ ${#ids[@]} -eq 0 ] && ids=($(printf '%s\n' "${!ISSUE[@]}" | sort -t- -k1,1 -k2,2n))

# one gh call: state + labels for the milestone
json=$(gh issue list --milestone release-1 --limit 100 --state all --json number,state,labels 2>/dev/null || echo '[]')

printf '%-7s %-12s %-7s %-20s %s\n' ID STATE ISSUE BRANCH NOTES
for id in "${ids[@]}"; do
  n="${ISSUE[$id]:-?}"
  branch="claude/${id,,}"
  istate=$(echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((i['state'] for i in d if i['number']==$n),'?'))" 2>/dev/null || echo '?')
  labels=$(echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(l['name'] for i in d if i['number']==$n for l in i['labels']))" 2>/dev/null || echo '')

  state="TODO"; notes=""
  [ "$istate" = "CLOSED" ] && state="CLOSED"
  echo "$labels" | grep -q 'blocked-ext' && notes="blocked-ext"
  if git worktree list 2>/dev/null | grep -qi "${id}" || git rev-parse --verify "$branch" >/dev/null 2>&1 || git rev-parse --verify "origin/$branch" >/dev/null 2>&1; then
    state="IN-FLIGHT"
  fi
  for ref in "origin/$branch" "$branch"; do
    if git rev-parse --verify "$ref" >/dev/null 2>&1 && git merge-base --is-ancestor "$ref" origin/main 2>/dev/null; then
      state="MERGED"; notes="${notes:+$notes,}branch on main"; break
    fi
  done
  printf '%-7s %-12s %-7s %-20s %s\n' "$id" "$state" "#$n" "$branch" "$notes"
done
