#!/usr/bin/env bash
# GC26 parity (docs/delivery_graph_spec.md §12, §17 row C2): one board F in the
# github fixture shape and in the local store shape gives byte-identical
# `graph.sh ready` and `tick-plan.sh` output. That is the policy-alignment
# guarantee: lib/*.jq decides, the backends only store (§3 rule 1).
#
# Board F is the merged GC5 github fixture (fixtures/graph-github/gc5-issues.json,
# 11 issues: two epics, done/cancelled/blocked/ready tasks, Depends-on and
# Part-of-epic text). fixtures/parity/local-store/ is the same board as a local
# store (epics/1.json, epics/2.json, epics/inbox.json; checklists empty, since
# local children come from `epic`). The PRs (fixtures/parity/prs.json,
# lists.json) are on the forge in both shapes: FORGE=github behind
# fixtures/parity/gh-shim.sh, which hands issue reads to the merged graph-github
# shim and PR reads to the merged forge-github shim. F2 is F after the same
# status drift is applied to each shape (labels on github, `graph.sh update` on
# local), so the review/merge rules are exercised too.
#
# Offline; runs in a throwaway git repo under ${TMPDIR:-/tmp}.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
fx="$here/fixtures/parity"
ghfx="$here/fixtures/graph-github"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-parity-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"
git init -q "$repo"
mkdir -p "$tmp/bin" "$tmp/shim" "$tmp/board"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/gh-shim.sh" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done; fails=1; }

# side <github|local> <out-file> <script> [args…]: run one entry point against
# one shape of the board; the shim log is kept per side in $tmp/<side>.log.
side() {
  local shape="$1" outf="$2" script="$3"; shift 3
  : > "$tmp/shim/log"
  local rc=0
  (cd "$repo" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REPO -u GH_HOST -u FORGE_URL -u FORGE_REPO \
     -u LIST_LIMIT -u GITLAB_TOKEN -u GITEA_TOKEN -u SHIM_GH_VERSION \
     PATH="$tmp/bin:$PATH" SHIM_STATE="$tmp/shim" SHIM_GRAPH_FX="$tmp/board" SHIM_BOARD=issues.json \
     SHIM_FORGE_FX="$fx" BASE_BRANCH=main FORGE=github GRAPH_BACKEND="$shape" STATE_DIR="$tmp/store" \
     bash "$scripts/$script" "$@" > "$outf" 2> "$outf.err") || rc=$?
  cp "$tmp/shim/log" "$tmp/$shape.log"
  [ "$rc" = 0 ] || fail "$shape: $script $* exits 0" "rc=$rc" "$(cat "$outf.err")"
}

# parity <board> <script> [args…]: both shapes, byte for byte.
parity() {
  local board="$1"; shift
  side github "$tmp/gh.out" "$@"
  side local "$tmp/lo.out" "$@"
  if [ ! -s "$tmp/gh.out" ]; then
    fail "GC26 $board: $* prints something" "empty output"
  elif cmp -s "$tmp/gh.out" "$tmp/lo.out"; then
    ok "GC26 $board: $* is byte-identical on github and local"
  else
    fail "GC26 $board: $* is byte-identical on github and local" \
      "$(diff "$tmp/gh.out" "$tmp/lo.out" || true)"
  fi
}

# --- board F --------------------------------------------------------------------
cp "$ghfx/gc5-issues.json" "$tmp/board/issues.json"
cp -R "$fx/local-store" "$tmp/store"

parity F graph.sh ready
grep -q 'gh issue list' "$tmp/github.log" && ok "F: the github side read the issues through gh" \
  || fail "F: the github side read the issues through gh" "$(cat "$tmp/github.log")"
if grep -q 'gh issue' "$tmp/local.log"; then fail "F: the local side never calls gh issue" "$(cat "$tmp/local.log")"
else ok "F: the local side never calls gh issue"; fi
lines=$(wc -l < "$tmp/gh.out" | tr -d ' ')
[ "$lines" = 5 ] && ok "F: ready holds the 5 ready tasks of the GC5 board" || fail "F: ready holds 5 tasks" "got $lines"

parity F tick-plan.sh
parity F tick-plan.sh --parallel 3 --auto-merge
grep -q 'gh pr list --state open' "$tmp/local.log" && ok "F: tick-plan.sh reads the PRs from the forge on local too" \
  || fail "F: tick-plan.sh reads the PRs from the forge on local too" "$(cat "$tmp/local.log")"
starts=$(jq -c '[.actions[] | "\(.action) \(.id // .pr)"]' "$tmp/gh.out")
[ "$starts" != '[]' ] && ok "F: the parallel plan is not empty ($starts)" || fail "F: the parallel plan is not empty" "$starts"

# Reconcile plans over the same ground truth agree too. The records are listed
# in backend order (rule by rule, nodes in list order), so they are compared as
# a sorted set.
side github "$tmp/gh.rec" graph.sh reconcile
side local "$tmp/lo.rec" graph.sh reconcile
if [ -s "$tmp/gh.rec" ] && [ "$(sort "$tmp/gh.rec")" = "$(sort "$tmp/lo.rec")" ]; then
  ok "F: graph.sh reconcile plans the same fix records on github and local"
else
  fail "F: graph.sh reconcile plans the same fix records" "$(diff <(sort "$tmp/gh.rec") <(sort "$tmp/lo.rec") || true)"
fi

# --- board F2: the same status drift on each shape --------------------------------
# 12 (open PR #204, not reviewed) -> in-review; 15 (open PR #205, reviewed at
# its head, clean, green) -> approved.
jq 'map(if .number == 12 or .number == 15 then
          (if .number == 12 then "status:in-review" else "status:approved" end) as $s
          | .labels |= map(if .name == "status:ready" then .name = $s | .id = "LA_\($s)" else . end)
        else . end)' "$ghfx/gc5-issues.json" > "$tmp/board/issues.json"
side local "$tmp/u1" graph.sh update 12 '{"status":"in-review"}'
side local "$tmp/u2" graph.sh update 15 '{"status":"approved"}'

parity F2 graph.sh ready
parity F2 tick-plan.sh
parity F2 tick-plan.sh --parallel 3 --auto-merge
acts=$(jq -c '[.actions[] | "\(.action) \(.pr // .id)"]' "$tmp/gh.out")
case "$acts" in
  *'"merge 205"'*'"review 204"'*) ok "F2: the plan merges #205 and reviews #204 ($acts)" ;;
  *) fail "F2: the plan merges #205 and reviews #204" "$acts" ;;
esac

if [ "$fails" -ne 0 ]; then
  echo "parity tests FAILED" >&2
  exit 1
fi
echo "parity tests passed"
