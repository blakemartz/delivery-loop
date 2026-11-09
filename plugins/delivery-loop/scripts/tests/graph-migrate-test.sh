#!/usr/bin/env bash
# Tests for `graph.sh migrate` (docs/delivery_graph_spec.md §6.2, §12 GC48, §17
# row B3) and the github backend's `migrate-plan` / `parent` primitives behind it.
#
# GC48: the first run adds native edges and leaves the `Depends-on:` text in the
# body; the second run issues 0 edits; an issue needing 51 blockers exits 1
# naming the issue. Also: the default is a dry run that writes nothing, only open
# tasks are migrated, and the run refuses a non-github backend and a gh without
# native relations.
#
# Offline: the recording, stateful gh shim of the write-path tests
# (fixtures/graph-github-write/gh-shim.sh, reused unchanged) sits first on PATH;
# the board is fixtures/graph-migrate/board.json. Runs in a throwaway git repo so
# the host repo's .claude/delivery.conf never leaks in.
#
# bash 3.2: no jq filter containing `{a, b}` goes inside an `expect` (eval)
# string, where 3.2 brace-expands it; compute such values first, then `eq`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
graph="$scripts/graph.sh"
backend="$scripts/backends/graph-github.sh"
fx="$here/fixtures/graph-migrate"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-migrate-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$here/fixtures/graph-github-write/gh-shim.sh" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
st="$tmp/state"

# load <board.json>: a fresh shim state.
load() {
  rm -rf "$st"; mkdir -p "$st"
  cp "$1" "$st/board.json"
  echo '[]' > "$st/prs.json"
  : > "$st/log"
}

# run [VAR=value …] -- <script> <args…>: sets $rc, $out, $err.
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  # shellcheck disable=SC2086
  (cd "$tmp" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REPO -u GH_HOST \
     -u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u LIST_LIMIT -u BASE_BRANCH \
     -u GITLAB_TOKEN -u GITEA_TOKEN -u STATE_DIR -u LOCK_WAIT_SECONDS -u SHIM_GH_VERSION \
     -u CLAIM_GRACE_SECONDS \
     PATH="$tmp/bin:$PATH" SHIM_STATE="$st" $envs \
     bash "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}
g() { local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift; run ${e[@]+"${e[@]}"} -- "$graph" "$@"; }

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
log_has()   { grep -qF -- "$1" "$st/log"; }
log_count() { grep -cF -- "$1" "$st/log" || true; }
# writes: every mutating gh call in the shim log.
writes() { grep -cE '^gh issue (edit|comment|close|create) ' "$st/log" || true; }
issue() { jq -c --argjson n "$1" ".[] | select(.number == \$n) | $2" "$st/board.json"; }
native() { issue "$1" '[.blockedBy.nodes[].number] | sort'; }

# --- dry run (the default) -----------------------------------------------------------
load "$fx/board.json"
cp "$st/board.json" "$tmp/before.json"
g -- migrate
eq "dry run: exit 0" 0 "$rc"
want=$(printf '%s\n' \
  '{"op":"link","id":"2","dep":"3"}' \
  '{"op":"link","id":"2","dep":"9"}' \
  '{"op":"parent","id":"2","epic":"1"}' \
  '{"op":"link","id":"4","dep":"3"}')
eq "dry run: one JSON edit per line; only open tasks; native edges and parents are skipped" "$want" "$out"
eq "dry run: nothing is written" 0 "$(writes)"
expect "dry run: the board is unchanged" 'cmp -s "$tmp/before.json" "$st/board.json"'
expect "dry run: the summary names the count and --apply" \
  'grep -qF "4 edit(s) planned (dry run; pass --apply to write them)" <<<"$err"'
expect "a self edge is warned about, never linked" \
  'grep -qF "warn: #7 Depends-on: itself; not linked" <<<"$err"'
expect "a Part of epic line the node does not read as its epic is warned about, not set" \
  'grep -qF "warn: #8 reads epic #6 but has \`Part of epic #1\`; parent not set" <<<"$err"'

# --- GC48: first --apply run ------------------------------------------------------------
g -- migrate --apply
eq "GC48 first run: exit 0" 0 "$rc"
want=$(printf '%s\n' 'migrate: link 2 blocked-by 3' 'migrate: link 2 blocked-by 9' \
  'migrate: parent 2 -> 1' 'migrate: link 4 blocked-by 3')
eq "GC48 first run: each edit is printed as applied" "$want" "$out"
eq "GC48 first run: #2 gets native blocked-by #3 and #9" '[3,9]' "$(native 2)"
eq "GC48 first run: #2 gets native parent #1" '1' "$(issue 2 .parent.number)"
eq "GC48 first run: #4 keeps #2 and gains #3" '[2,3]' "$(native 4)"
eq "GC48 first run: #2's Depends-on / Part of epic text stays in the body" \
  "$(jq -c '.[] | select(.number == 2) | .body' "$tmp/before.json")" "$(issue 2 .body)"
eq "GC48 first run: #4's text (with its via) stays in the body" \
  "$(jq -c '.[] | select(.number == 4) | .body' "$tmp/before.json")" "$(issue 4 .body)"
expect "GC48 first run: edits go through gh issue edit --add-blocked-by / --parent only" \
  '[ "$(log_count "gh issue edit 2 --add-blocked-by 3")" = 1 ] && [ "$(log_count "gh issue edit 2 --parent 1")" = 1 ] && [ "$(writes)" = 4 ]'
eq "the closed task, the epic and the unlabelled issues are untouched" \
  "$(jq -c '[.[] | select(.number == 5 or .number == 6 or .number == 7 or .number == 8 or .number == 10)]' "$tmp/before.json")" \
  "$(jq -c '[.[] | select(.number == 5 or .number == 6 or .number == 7 or .number == 8 or .number == 10)
             | .updatedAt = "2026-01-02T00:00:00Z"]' "$st/board.json")"
g -- show 2
eq "the migrated node reads the same deps and epic" '[["3","9"],"1"]' "$(jq -c '[[.deps[].id], .epic]' <<<"$out")"

# --- GC48: second run ---------------------------------------------------------------------
: > "$st/log"
cp "$st/board.json" "$tmp/after1.json"
g -- migrate --apply
eq "GC48 second run: exit 0, nothing printed" "0:" "$rc:$out"
eq "GC48 second run: 0 edits" 0 "$(writes)"
expect "GC48 second run: the summary says 0 applied" 'grep -qF "0 edit(s) applied" <<<"$err"'
expect "GC48 second run: the board is unchanged" 'cmp -s "$tmp/after1.json" "$st/board.json"'
g -- migrate
eq "GC48 second run: a dry run plans nothing" "0:" "$rc:$out"

# --- GC48: an issue needing 51 blockers ----------------------------------------------------
# #100 has 51 legacy refs, #101 exactly 50 (the cap itself is fine), #102 49 native
# + 2 text (51 after migration).
jq '. + [
  (.[1] | .number = 100 | .title = "51 deps" | .parent = null
   | .body = ([range(200; 251) | "Depends-on: #\(.)"] | join("\n"))),
  (.[1] | .number = 101 | .title = "50 deps" | .parent = null
   | .body = ([range(200; 250) | "Depends-on: #\(.)"] | join("\n"))),
  (.[1] | .number = 102 | .title = "49 native + 2 text" | .parent = null
   | .blockedBy = {nodes: [range(300; 349) | {number: ., state: "OPEN"}], totalCount: 49}
   | .body = "Depends-on: #400\nDepends-on: #401") ]
  | . + [ (.[8]) as $u | (range(200; 251), range(300; 349), 400, 401) as $n | $u | .number = $n ]' \
  "$fx/board.json" > "$tmp/cap.json"
load "$tmp/cap.json"
g -- migrate --apply
eq "GC48: an issue needing 51 blockers exits 1" 1 "$rc"
expect "GC48: the offender is named" 'grep -qF "#100 would have 51 blockers" <<<"$err"'
expect "GC48: every offender is named, natives counted" 'grep -qF "#102 would have 51 blockers" <<<"$err"'
expect "GC48: exactly 50 is not an offender" '! grep -qF "#101 " <<<"$err"'
eq "GC48: nothing is written (the check precedes every edit)" 0 "$(writes)"
g -- migrate
eq "GC48: the dry run refuses too" 1 "$rc"

# --- the blocking side of the cap ------------------------------------------------------------
# #500 already blocks 45 issues natively (#600-#644); 6 tasks (#700-#705) name it
# in text, so it would block 51. #501 is named by exactly 50 tasks (allowed).
jq '(.[1] | .parent = null | .body = "x") as $t | (.[8]) as $u
  | [ .[0] ]
  + [ (500, 501) as $n | $u | .number = $n ]
  + [ range(600; 645) as $n | $u | .number = $n | .blockedBy = {nodes: [{number: 500, state: "OPEN"}], totalCount: 1} ]
  + [ range(700; 706) as $n | $t | .number = $n | .body = "Depends-on: #500" ]
  + [ range(800; 850) as $n | $t | .number = $n | .body = "Depends-on: #501" ]' \
  "$fx/board.json" > "$tmp/hub.json"
load "$tmp/hub.json"
g -- migrate --apply
eq "cap, blocking side: a dep that would block 51 issues exits 1" 1 "$rc"
expect "cap, blocking side: the dep is named once, natives counted" \
  '[ "$(grep -cF "#500 would block 51 issues" <<<"$err")" = 1 ]'
expect "cap, blocking side: exactly 50 is not an offender" '! grep -qF "#501 " <<<"$err"'
eq "cap, blocking side: nothing is written" 0 "$(writes)"
jq '[ .[] | select(.number < 700 or .number > 705) ]' "$tmp/hub.json" > "$tmp/hub50.json"
load "$tmp/hub50.json"
g -- migrate
eq "cap, blocking side: 50 blocked issues plan fine" 0:50 "$rc:$(wc -l <<<"$out" | tr -d ' ')"

# --- a ref that is not an issue of the repo (GC7 unknown dep, a PR, a deleted issue) -----------
# The review's repro: before the fix, --apply failed at link 2→999 on every
# re-run and #4's link was never applied.
jq '(.[1] | .parent = null) as $t
  | [ .[2] | .parent = null | .body = "x" ]
  + [ $t | .number = 2 | .body = "Depends-on: #3 #999" ]
  + [ $t | .number = 4 | .body = "Depends-on: #3" ]' "$fx/board.json" > "$tmp/unknown.json"
load "$tmp/unknown.json"
echo '[{"number": 50, "state": "OPEN", "baseRefName": "main", "headRefName": "x"}]' > "$st/prs.json"
g -- migrate
want=$(printf '%s\n' '{"op":"link","id":"2","dep":"3"}' '{"op":"link","id":"4","dep":"3"}')
eq "unknown dep: the dry run plans only the valid links" "0:$want" "$rc:$out"
expect "unknown dep: warned about, not linked" \
  'grep -qF "warn: #2 Depends-on: #999, which is not an issue in this repo; not linked" <<<"$err"'
g -- migrate --apply
eq "unknown dep: --apply links every valid dep" "0:[3]:[3]" "$rc:$(native 2):$(native 4)"
eq "unknown dep: no edit names #999" 0 "$(log_count "--add-blocked-by 999")"
: > "$st/log"
g -- migrate --apply
eq "unknown dep: a second run issues 0 edits and exits 0" "0:0" "$rc:$(writes)"
expect "unknown dep: the second run still warns" 'grep -qF "warn: #2 Depends-on: #999" <<<"$err"'
jq '(.[1] | .parent = null) as $t | . + [ $t | .number = 6 | .body = "Depends-on: #50" ]' \
  "$tmp/unknown.json" > "$tmp/unknown-pr.json"
load "$tmp/unknown-pr.json"
echo '[{"number": 50, "state": "OPEN", "baseRefName": "main", "headRefName": "x"}]' > "$st/prs.json"
g -- migrate
expect "a PR number dep is not linked" \
  '[ "$rc" = 0 ] && ! grep -qF "\"dep\":\"50\"" <<<"$out" && grep -qF "warn: #6 Depends-on: #50, which is not an issue in this repo" <<<"$err"'

# --- cross-repo refs, parent drift, an unknown epic ----------------------------------------------
jq '(.[1] | .parent = null) as $t
  | [ .[0], (.[2] | .parent = null | .body = "x"), (.[8] | .number = 5) ]
  + [ $t | .number = 2 | .body = "Depends-on: other/repo#5, #3\nDepends-on: o.rg/r_e-po#3" ]
  + [ $t | .number = 4 | .parent = {number: 1} | .body = "Part of epic #6" ]
  + [ $t | .number = 6 | .labels = [{name: "epic"}] | .body = "" ]
  + [ $t | .number = 7 | .body = "Part of epic #999" ]' "$fx/board.json" > "$tmp/misc.json"
load "$tmp/misc.json"
g -- migrate
eq "cross-repo: only the local ref is linked; no parent for drift or an unknown epic" \
  '0:{"op":"link","id":"2","dep":"3"}' "$rc:$out"
expect "cross-repo: each cross-repo ref is warned about" \
  'grep -qF "warn: #2 Depends-on: other/repo#5 is in another repo; not linked" <<<"$err" && grep -qF "warn: #2 Depends-on: o.rg/r_e-po#3 is in another repo" <<<"$err"'
expect "parent drift: a native parent that differs from the text is warned about" \
  'grep -qF "warn: #4 has native parent #1 but \`Part of epic #6\`; parent left as is (fix the body)" <<<"$err"'
expect "an epic that is not an issue is warned about, not set" \
  'grep -qF "warn: #7 Part of epic #999, which is not an issue in this repo; parent not set" <<<"$err"'
g -- migrate --apply
eq "cross-repo: --apply writes only the local link" "0:1:[3]" "$rc:$(writes):$(native 2)"

# --- refusals ---------------------------------------------------------------------------------
load "$fx/board.json"
run SHIM_GH_VERSION=2.90.0 -- "$graph" migrate --apply
expect "gh < 2.94: refused (native relations are the point), nothing written" \
  '[ "$rc" = 1 ] && grep -qF "needs gh >= 2.94.0" <<<"$err" && [ "$(writes)" = 0 ]'
run GRAPH_BACKEND=local -- "$graph" migrate
expect "a non-github backend is refused" '[ "$rc" = 1 ] && grep -qF "migrate is github only" <<<"$err"'
g -- migrate --fix
eq "an unknown flag is a usage error" 2 "$rc"
g -- migrate --apply extra
eq "extra arguments are a usage error" 2 "$rc"

# --- the parent primitive -----------------------------------------------------------------------
load "$fx/board.json"
run -- "$backend" parent 3 1
expect "parent: the same parent again is a no-op" '[ "$rc" = 0 ] && [ "$(writes)" = 0 ]'
run -- "$backend" parent 3 6
expect "parent: refuses to re-parent, nothing written" \
  '[ "$rc" = 1 ] && grep -qF "already has parent #1" <<<"$err" && [ "$(writes)" = 0 ]'
run -- "$backend" parent 7 7
eq "parent: refuses a self parent" 1 "$rc"
run -- "$backend" parent 7 1
eq "parent: sets the native parent" '0:1' "$rc:$(issue 7 .parent.number)"

[ "$fails" = 0 ] || { echo "graph-migrate-test: FAILED" >&2; exit 1; }
echo "graph-migrate-test: all passed"
