#!/usr/bin/env bash
# Tests for graph.sh (ready/list/show/export) + backends/graph-github.sh list/show
# (docs/delivery_graph_spec.md §4.1, §6.1, §6.2, §11): golden cases GC5 (github
# fixture), GC9, GC10, GC11, GC44 (`pinged_at` derivation), GC45 (checklist
# normalization), GC56, GC64 and GC59 (`graph.sh` part) — §17 row B1 — plus
# GC72's `applied_prs` derivation and GC74 (comments past gh's 100-per-issue
# list cap) (§17 row A5b, issue #52), the trailer-block rule (issue #77), and
# `show --events` over the comment thread (issue #92, §4.4).
#
# Offline: a recording gh shim (fixtures/graph-github/gh-shim.sh) sits first on
# PATH, answering from boards in the `gh issue list --json …` shape. Runs in a
# throwaway git repo so the host repo's .claude/delivery.conf never leaks in.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
graph="$here/../graph.sh"
lib="$here/../lib"
fx="$here/fixtures/graph-github"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-github-read-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q
mkdir -p "$tmp/bin" "$tmp/state"
printf '#!/usr/bin/env bash\nexec bash "%s" "$@"\n' "$fx/gh-shim.sh" > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

reset() { rm -rf "$tmp/state"; mkdir -p "$tmp/state"; : > "$tmp/state/log"; }

# run [VAR=value …] -- <graph.sh args…>: sets $rc, $out (stdout), $err (stderr).
run() {
  local envs=""
  while [ "$1" != -- ]; do envs="$envs $1"; shift; done
  shift
  reset
  # shellcheck disable=SC2086
  (cd "$tmp" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_REPO -u GH_HOST \
     -u GRAPH_BACKEND -u FORGE -u FORGE_URL -u FORGE_REPO -u LIST_LIMIT -u BASE_BRANCH \
     -u GITLAB_TOKEN -u GITEA_TOKEN -u SHIM_BOARD -u SHIM_GH_VERSION \
     PATH="$tmp/bin:$PATH" SHIM_FX="$fx" SHIM_STATE="$tmp/state" $envs \
     bash "$graph" "$@" >"$tmp/out" 2>"$tmp/err") && rc=0 || rc=$?
  out=$(cat "$tmp/out"); err=$(cat "$tmp/err")
}

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done
         echo "        rc=$rc stdout: $out" >&2; echo "        stderr: $err" >&2; fails=1; }
log_has()   { grep -qF -- "$1" "$tmp/state/log"; }
log_count() { grep -cF -- "$1" "$tmp/state/log" || true; }
# expect <name> '<condition>': pass when the shell condition (eval'd) succeeds.
expect() { if eval "$2"; then ok "$1"; else fail "$1" "condition failed: $2"; fi; }
# eq <name> <want> <got>
eq() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
# node <id> <jq>: a field expression over node <id> of the last `list` output.
node() { jq -c --arg id "$1" ".[] | select(.id == \$id) | $2" <<<"$out"; }

# --- GC5: v0.1.4-parity ready order over the github fixture --------------------
# gc5-issues.json is the board behind fixtures/ready/gc5-nodes.json, in the raw
# `gh issue list` shape (labels, state/stateReason, Depends-on / Part of epic
# text). Normalizing it must give exactly those nodes, and `graph.sh ready`,
# projected onto the v0.1.4 line shape, must reproduce the captured v0.1.4 output.
run SHIM_BOARD=gc5-issues.json -- list
expect "GC5: list exits 0" '[ "$rc" = 0 ]'
if [ "$(jq -cS 'sort_by(.id | tonumber)' <<<"$out")" = "$(jq -cS 'sort_by(.id | tonumber)' "$here/fixtures/ready/gc5-nodes.json")" ]; then
  ok "GC5: the github board normalizes to fixtures/ready/gc5-nodes.json"
else
  fail "GC5: normalized nodes differ from gc5-nodes.json" \
    "$(diff <(jq -S 'sort_by(.id | tonumber)' "$here/fixtures/ready/gc5-nodes.json") <(jq -S 'sort_by(.id | tonumber)' <<<"$out") || true)"
fi

run SHIM_BOARD=gc5-issues.json -- ready
expect "GC5: ready exits 0" '[ "$rc" = 0 ]'
got=$(jq -c '{number: (.id | tonumber), title, unblocks,
              size: (if .size == "S" then "S" else "M" end), started,
              epic: (.epic | if . == null then null else tonumber end),
              module: (if .module == null then "none" else "module:\(.module)" end)}' <<<"$out")
eq "GC5: graph.sh ready reproduces the captured v0.1.4 order and fields" \
  "$(cat "$here/fixtures/ready/gc5-v014.jsonl")" "$got"
eq "GC5: ready lines carry target_branch = BASE_BRANCH by default" '["main"]' \
  "$(jq -sc 'map(.target_branch) | unique' <<<"$out")"
# closedByPullRequestsReferences (B2, GC75) rides with the native relations.
expect "GC5: one paginated list of all issues with the §6.2 field set and an explicit limit" \
  'log_has "gh issue list --state all --json number,title,state,stateReason,labels,assignees,body,createdAt,updatedAt,comments,blockedBy,parent,closedByPullRequestsReferences --limit 5000" && [ "$(log_count "gh issue list")" = 1 ]'

run SHIM_BOARD=gc5-issues.json BASE_BRANCH=release/y -- ready
eq "target_branch defaults to the configured BASE_BRANCH" '["release/y"]' \
  "$(jq -sc 'map(.target_branch) | unique' <<<"$out")"

# --- the per-case board ----------------------------------------------------------
run -- list
expect "cases: list exits 0" '[ "$rc" = 0 ]'
if jq -e -L "$lib" 'include "node"; map(validate_node) | length > 0' <<<"$out" >/dev/null; then
  ok "cases: every listed node passes validate_node"
else
  fail "cases: validate_node rejected list output"
fi
eq "list returns ALL delivery nodes, open and closed; an issue with no task/epic/promote label is not a node" \
  '["3","4","5","6","30","31","32","33","34","40","41","42","43","44","45","46","48"]' \
  "$(jq -c 'map(.id) | sort_by(tonumber)' <<<"$out")"

# GC9: closed state + stateReason -> done / cancelled.
eq "GC9: CLOSED+COMPLETED -> done" '"done"' "$(node 31 .status)"
eq "GC9: CLOSED+NOT_PLANNED -> cancelled" '"cancelled"' "$(node 32 .status)"
eq "GC9: CLOSED+DUPLICATE -> cancelled" '"cancelled"' "$(node 33 .status)"
eq "open status comes from the status:* label" '"blocked"' "$(node 34 .status)"
eq "open status: the most advanced of two status labels wins" '"claimed"' "$(node 48 .status)"
eq "open status: no status label -> ready (a cache reconcile repairs)" '"ready"' "$(node 30 .status)"

# GC11: native blockedBy ∪ legacy Depends-on text, deduplicated.
eq "GC11: body Depends-on #3 + native blockedBy #3,#4 -> deps [3,4]" '["3","4"]' "$(node 34 '[.deps[].id]')"
eq "legacy Depends-on lines: every #N, with (via: …) naming its edge" \
  '[{"id":"3","via":"shared config"},{"id":"4","via":null},{"id":"6","via":null}]' "$(node 46 .deps)"

# GC64: totalCount 3 > 2 returned nodes -> re-read via gh issue view --json blockedBy.
expect "GC64: the short blockedBy connection is re-read with gh issue view --json blockedBy" \
  'log_has "gh issue view 5 --json blockedBy" && [ "$(log_count "gh issue view")" = 1 ]'
eq "GC64: deps has all 3 ids after the re-read" '["3","4","6"]' "$(node 5 '[.deps[].id]')"

# GC44: pinged_at = the newest STALE-CLAIM-PING comment, else null.
eq "GC44: pinged_at is the newest STALE-CLAIM-PING comment" '"2026-10-06T00:00:00Z"' "$(node 40 .pinged_at)"
eq "GC44: no STALE-CLAIM-PING comment -> pinged_at null" 'null' "$(node 41 .pinged_at)"

# GC45: the epic's checklist; a checklist-only child keeps epic null (parity).
eq "GC45: epic checklist = its - [ ]/- [x]/* [X] #N ids, ordered, deduplicated" '["31","32","33"]' "$(node 30 .checklist)"
eq "GC45: the checklist-only child's own epic stays null" 'null' "$(node 32 .epic)"
eq "epic from the 'Part of epic #E' body backlink" '"30"' "$(node 31 .epic)"
eq "epic from native parent.number" '"30"' "$(node 33 .epic)"
eq "checklist is empty on non-epic nodes" '[]' "$(jq -c '[.[] | select(.kind != "epic") | .checklist[]]' <<<"$out")"
eq "GC45: children(epic) counts the checklist-only child; every child done/cancelled" \
  '{"ids":["31","32","33"],"closed":true}' \
  "$(jq -c -L "$lib" 'include "graph"; children("30") | {ids: (map(.id) | sort), closed: all(.status == "done" or .status == "cancelled")}' <<<"$out")"

# Claims (§4.1): assignee + claim:agent + the winning live CLAIM comment.
eq "agent claim: the earliest live CLAIM after the latest RECLAIMED wins" \
  '{"actor":"agent-1","run":"host-2-200","at":"2026-10-01T07:00:01Z","by":"agent"}' "$(node 42 .claim)"
eq "agent claim: claim:agent with no assignee and no live CLAIM -> claim null (drift)" 'null' "$(node 43 .claim)"
eq "agent claim: claim:agent with an assignee but no CLAIM -> actor = assignee, run/at null" \
  '{"actor":"shim-user","run":null,"at":null,"by":"agent"}' "$(node 44 .claim)"
eq "human claim: assignee without claim:agent -> by human, run/at null" \
  '{"actor":"ann","run":null,"at":null,"by":"human"}' "$(node 40 .claim)"
eq "unassigned, no claim:agent -> claim null" 'null' "$(node 4 .claim)"

# Labels and body trailers.
eq "kind, size, module, needs_human from labels (bare module: label -> null)" \
  '["task","L",null,true]' "$(node 48 '[.kind, .size, .module, .needs_human]')"
eq "promote node: Delivery-Target / Delivery-Promote-To / Delivery-Plan body lines" \
  '["promote","release/x","main","v2/promote"]' "$(node 45 '[.kind, .target_branch, .promote_to, .plan_ref]')"
eq "task: Delivery-Target / Delivery-Plan body lines; promote_to stays null" \
  '["release/x",null,"v2/t46"]' "$(node 46 '[.target_branch, .promote_to, .plan_ref]')"

# The ready set over the per-case board (policy applied by graph.sh, not the backend).
run -- ready
# 43 (claim:agent, no assignee, no CLAIM) normalizes to claim null, so it is
# ready, as in v0.1.4 (zero assignees); reconcile owns that drift.
eq "ready over the cases board: lib/ready.jq applied to the normalized nodes" '["4","6","43"]' \
  "$(jq -sc 'map(.id)' <<<"$out")"

# --- several size:* labels: L first, then S, then M (v0.1.4 parity) ---------------
# v0.1.4 excluded any issue carrying size:L and ranked S only on size:S, so a
# double-sized issue must read L if it has size:L, else S if it has size:S.
jq '[ .[] | select(.number == 6) ] as [$t]
    | def sized($n; $sizes): $t | .number = $n | .title = "sizes \($sizes | join("+"))"
        | .labels = ([.labels[] | select(.name | startswith("size:") | not)]
                     + [$sizes[] | {id: "LA_size_\(.)", name: "size:\(.)", description: "", color: "EDEDED"}]);
    [ sized(1; ["S","L"]), sized(2; ["M","L"]), sized(3; ["S","M"]), sized(4; ["M"]) ]' \
  "$fx/cases-issues.json" > "$tmp/sizes.json"
run SHIM_FX="$tmp" SHIM_BOARD=sizes.json -- list
eq "size precedence: S+L -> L, M+L -> L, S+M -> S, M -> M" '["L","L","S","M"]' \
  "$(jq -c 'sort_by(.id | tonumber) | map(.size)' <<<"$out")"
run SHIM_FX="$tmp" SHIM_BOARD=sizes.json -- ready
eq "size precedence: an S+L (or M+L) task is not ready; S+M ranks as S ahead of M" '["3","4"]' \
  "$(jq -sc 'map(.id)' <<<"$out")"

# --- GC72: applied_prs from AUTO-CLOSE: PR #<n> comments (§4.1) ---------------------
# Only a comment that starts with the marker, with the number right after it,
# names a PR; v0.1.4's epic AUTO-CLOSE comment names none.
jq '[ .[] | select(.number == 6) ] as [$t]
    | def c($b): {body: $b, createdAt: "2026-10-01T00:00:00Z"};
    [ ($t | .number = 1 | .state = "OPEN"
      | .comments = [c("AUTO-CLOSE: PR #12 merged into release/x (closing keywords only fire on the default branch). (Reconciled by scripts/task-queue.sh --fix.)"),
                     c("AUTO-CLOSE: PR #9 merged into release/x"), c("AUTO-CLOSE: PR #12 merged again"),
                     c("AUTO-CLOSE: epic fully delivered — all 2 child tasks are closed."),
                     c("see AUTO-CLOSE: PR #99"), c("AUTO-CLOSE: PR #x\n55"), c("AUTO-CLOSE: PR #0")]),
      ($t | .number = 2) ]' "$fx/cases-issues.json" > "$tmp/applied.json"
run SHIM_FX="$tmp" SHIM_BOARD=applied.json -- list
expect "GC72: list exits 0" '[ "$rc" = 0 ]'
eq "GC72: applied_prs = the AUTO-CLOSE: PR #<n> comment numbers, ascending, deduplicated" '[9,12]' "$(node 1 .applied_prs)"
eq "GC72: no AUTO-CLOSE comment -> applied_prs []" '[]' "$(node 2 .applied_prs)"
eq "GC72: every node of the cases board carries applied_prs" true \
  "$(run -- list; jq -c 'all(.[]; .applied_prs == [])' <<<"$out")"

# --- GC74: comments past `gh issue list`'s 100-per-issue cap -------------------------
# The shim, like gh 2.96.0, returns only an issue's first 100 comments on `issue
# list`; `issue view` returns them all. Issue 1 has 105 comments, its AUTO-CLOSE
# marker the 103rd, its newest STALE-CLAIM-PING the 104th and the RECLAIMED that
# voids its early CLAIM the 105th. Issue 2 has exactly 100 (complete, but
# unprovable: gh exposes no total), issue 3 has 99 (provably complete).
jq '[ .[] | select(.number == 6) ] as [$t]
    | def c($i; $b): {body: $b, createdAt: ("2026-10-01T00:00:00Z" | fromdate + $i | todate)};
      def filler($n): [ range(1; $n + 1) as $i | c($i; "chatter \($i)") ];
    [ ($t | .number = 1
      | .labels += [{id: "LA_claim", name: "claim:agent", description: "", color: "EDEDED"}]
      | .assignees = []
      | .comments = ([c(0; "CLAIM agent-1 host-1-100 2026-10-01T00:00:00Z")] + filler(101)
                     + [c(200; "AUTO-CLOSE: PR #77 merged into release/x"),
                        c(201; "STALE-CLAIM-PING @agent-1"),
                        c(202; "RECLAIMED agent-1")])),
      ($t | .number = 2 | .comments = filler(100)),
      ($t | .number = 3 | .comments = filler(99)) ]' "$fx/cases-issues.json" > "$tmp/long.json"
eq "GC74: fixture: issue 1 has 105 comments, the AUTO-CLOSE marker at 103" '[105,103]' \
  "$(jq -c '.[0].comments | [length, (map(.body) | index("AUTO-CLOSE: PR #77 merged into release/x") + 1)]' "$tmp/long.json")"
run SHIM_FX="$tmp" SHIM_BOARD=long.json -- list
expect "GC74: list exits 0" '[ "$rc" = 0 ]'
expect "GC74: an issue with >= 100 listed comments is re-read with gh issue view --json comments" \
  'log_has "gh issue view 1 --json comments" && log_has "gh issue view 2 --json comments"'
expect "GC74: an issue with < 100 comments is not re-read" '! log_has "gh issue view 3"'
eq "GC74: applied_prs holds the AUTO-CLOSE marker past comment 100" '[77]' "$(node 1 .applied_prs)"
eq "GC74: pinged_at is the STALE-CLAIM-PING past comment 100" \
  "$(jq -c '.[0].comments[103].createdAt' "$tmp/long.json")" "$(node 1 .pinged_at)"
eq "GC74: a RECLAIMED past comment 100 voids the early CLAIM (claim null)" 'null' "$(node 1 .claim)"
list1=$(node 1 .)
run SHIM_FX="$tmp" SHIM_BOARD=long.json -- show 1
eq "GC74: list and show agree on the long-thread node" "$list1" "$(jq -c . <<<"$out")"
run SHIM_FX="$tmp" SHIM_BOARD=long.json SHIM_GH_VERSION=2.93.0 -- list
expect "GC74: comments are re-read on gh < 2.94.0 too (no blockedBy requested)" \
  '[ "$rc" = 0 ] && log_has "gh issue view 1 --json comments" && ! log_has blockedBy && [ "$(node 1 .applied_prs)" = "[77]" ]'
jq '.[0]._view = {blockedBy: {nodes: [{number: 3}, {number: 4}], totalCount: 2}}
    | .[0].blockedBy = {nodes: [{number: 3}], totalCount: 2}' "$tmp/long.json" > "$tmp/long-bb.json"
run SHIM_FX="$tmp" SHIM_BOARD=long-bb.json -- list
expect "GC64+GC74: an issue short on both is re-read once, for both fields" \
  'log_has "gh issue view 1 --json blockedBy,comments" && [ "$(log_count "gh issue view 1 ")" = 1 ]'
eq "GC64+GC74: both re-read fields land" '[["3","4"],[77]]' "$(node 1 '[[.deps[].id], .applied_prs]')"

# --- #77: machine keys only from the trailer block; Depends-on at line start --------
# The trailer block (§6.2) is the leading run of trailer lines (a `Delivery-*:`
# key line at column 0, or a `Depends-on:` / `Part of epic #E` line with the
# edge parser's line lead) of the body's last paragraph that opens with a key
# line; lines after the run and paragraphs below that don't open with a key
# line are ignored. A key line anywhere else is prose: it must not steal plan_ref
# (re-apply would duplicate), retarget the node or name its promotion; and prose
# appended below the block must not lose it (the same harm). `Depends-on:` is
# read on any line, but only at line start (indent / bullet / bold allowed): the
# issue #77 criterion that mentioned it mid-line made the v0.1.4 queue block #77
# on #1.
mid='- [ ] verify `Depends-on: #1` handling'
jq --arg mid "$mid" '[ .[] | select(.number == 6) ] as [$t]
    | def t($n; $body): $t | .number = $n | .title = "trailer \($n)" | .body = $body;
    [ t(1; "## Context\nDelivery-Plan: other/x\nDelivery-Target: main\n\n## Acceptance criteria\n- [ ] x\n\nDelivery-Target: release/x\nDelivery-Plan: v2/t1"),
      t(2; "## Context\nDelivery-Plan: other/x\nDelivery-Target: main\n\n- [ ] x"),
      t(3; "Delivery-Target: main\nDelivery-Plan: other/x\n\nThanks!"),
      t(4; "x\n\nDelivery-Target: release/x\nDelivery-Plan: v2/t4\nsee above"),
      t(5; "x\r\n\r\nDelivery-Target: release/x\r\nDepends-on: #3 (via: shared config)\r\nDelivery-Plan: v2/t5\r\nDelivery-Task: t5\r\n\r\n  \n"),
      t(6; "Delivery-Target: release/x\nDelivery-Plan: v2/t6\nDelivery-Plan: other/x"),
      t(7; "## Acceptance criteria\n\($mid)\n- [ ] see Depends-on: #10 too\n> Depends-on: #10\n  Depends-on: #5\nDepends-on: #3"),
      t(8; "Part of epic #30\n\n\($mid)"),
      (t(9; "Delivery-Promote-To: other\n\nDelivery-Target: release/x\nDelivery-Promote-To: main\nDelivery-Plan: v2/promote")
        | .labels = [{id: "LA_promote", name: "promote", description: "", color: "EDEDED"}]),
      (t(10; "an unlabelled issue") | .labels = []),
      t(11; "x\n\nDelivery-Target: release/x\nDelivery-Plan: v2/t11\n\nUpdate: discussed in standup, see #3.\nDelivery-Plan: other/x"),
      t(12; "x\n\nDelivery-Target: release/x\nDelivery-Plan: v2/t12\n\nDepends-on: #4\n\nPart of epic #30\n\n\u00a0\n"),
      t(13; "x\n\nDelivery-Target: release/x\u00a0\nPart of epic #30 (the queue)\nDelivery-Plan: v2/t13 \t\n\u00a0"),
      t(14; "- Depends-on: #3\n**Depends-on:** #4\n* **Depends-on**: #5 (via: a b)\n  Depends-on: #6\n\tDepends-on: #7\n+ Depends-on: #8\n> Depends-on: #10\n- [ ] Depends-on: #10\n`Depends-on: #10`\nnot Depends-on: #10\n1. Depends-on: #9\n2) Depends-on: #11\n1. [ ] Depends-on: #10"),
      # #77 review A′: a line appended directly into the block paragraph (no
      # blank line first) ends the run, or joins it as an edge; either way the
      # keys survive.
      ( [ "\nUpdate: standup, see #3.", "\n- [ ] also handle X", "\n- Depends-on: #4", "\n  Depends-on: #4",
          "\n**Depends-on:** #4", "\n1. Depends-on: #4", "\n\u2003\nlater", "\n\u200b\nlater",
          "\nDepends-on: #4\nDelivery-Plan: other/x", "\n\nDepends-on: #4\nDelivery-Plan: other/x",
          "\n\n```\nDelivery-Plan: other/x\n```" ]
        | to_entries[] | t(.key + 15; "x\n\nDelivery-Target: release/x\nDelivery-Plan: v2/t\(.key + 15)" + .value) ) ]' \
  "$fx/cases-issues.json" > "$tmp/trailer.json"
run SHIM_FX="$tmp" SHIM_BOARD=trailer.json BASE_BRANCH=release/y -- list
expect "#77: list exits 0" '[ "$rc" = 0 ]'
tb() { node "$1" '[.target_branch, .plan_ref]'; }
eq "#77: human Delivery-Plan / Delivery-Target lines above the trailer block: the trailer's values win" \
  '["release/x","v2/t1"]' "$(tb 1)"
eq "#77: key lines in a paragraph with prose are prose: no trailer -> BASE_BRANCH, plan_ref null" \
  '["release/y",null]' "$(tb 2)"
eq "#77: a key-only paragraph followed by prose is the trailer block (the last one wins; §6.2 trade-off)" \
  '["main","other/x"]' "$(tb 3)"
eq "#77 review A′: prose typed directly under the block ends its run; the keys above it survive" '["release/x","v2/t4"]' "$(tb 4)"
eq "#77: trailer block with CRLF, a Depends-on and a Delivery-Task line, trailing blank lines" \
  '["release/x","v2/t5"]' "$(tb 5)"
eq "#77: … and its Depends-on line still names the edge" '[{"id":"3","via":"shared config"}]' "$(node 5 .deps)"
eq "#77: within the block the first line of a key wins (parity with the pre-#77 read)" '["release/x","v2/t6"]' "$(tb 6)"
eq "#77: Depends-on only at line start: the mid-line criterion, prose and a quote add no edge; an indented line does" \
  '["3","5"]' "$(node 7 '[.deps[].id]')"
eq "#77: the literal #77 criterion string adds no edge" '[]' "$(node 8 '[.deps[].id]')"
eq "#77: … and Part of epic at line start still names the epic" '"30"' "$(node 8 .epic)"
eq "#77: promote: Delivery-Promote-To above the trailer is prose" '["promote","release/x","main","v2/promote"]' \
  "$(node 9 '[.kind, .target_branch, .promote_to, .plan_ref]')"
eq "#77: an unlabelled issue named only by a mid-line / quoted / checklist Depends-on is not a referenced external" \
  "$(jq -cn '[range(1; 26) | select(. != 10) | tostring]')" "$(jq -c 'map(.id) | sort_by(tonumber)' <<<"$out")"
eq "#77 review A: prose appended below the trailer block keeps it (plan_ref and target survive; a key line in the prose is prose)" \
  '["release/x","v2/t11"]' "$(tb 11)"
eq "#77 review A: key-less trailer-line paragraphs and an NBSP-only line below the block are skipped" \
  '["release/x","v2/t12"]' "$(tb 12)"
eq "#77 review A: … and their Depends-on line still names the edge" '["4"]' "$(node 12 '[.deps[].id]')"
eq "#77: trailing NBSP/whitespace and a 'Part of epic #E (…)' line inside the block" \
  '["release/x","v2/t13"]' "$(tb 13)"
eq "#77 review C (§2 exception 7): bullet / ordered / bold / indented Depends-on lines count; quote, checklist item, code span, mid-line do not" \
  '[["3",null],["4",null],["5","a b"],["6",null],["7",null],["8",null],["9",null],["11",null]]' "$(node 14 '[.deps[] | [.id, .via]]')"
i=15
for what in 'prose ("Update: …")' 'a checklist item' 'a bulleted Depends-on' 'an indented Depends-on' 'a bold Depends-on' \
            'an ordered-list Depends-on' 'an em-space-only line, then prose' 'a ZWSP-only line, then prose' \
            'a Depends-on then a key line (in the run: the first key wins)' \
            'a paragraph opening with Depends-on, then a key line (skipped)' 'a fenced example key paragraph (not key-first: skipped)'; do
  eq "#77 review A′: appended $what: target and plan_ref survive" "[\"release/x\",\"v2/t$i\"]" "$(tb $i)"
  i=$((i + 1))
done
eq "#77 review A′: … and the appended bulleted / indented / bold / ordered Depends-on lines are edges" \
  '[["4"],["4"],["4"],["4"]]' "$(jq -c '[.[] | select(.id | IN("17", "18", "19", "20")) | [.deps[].id]]' <<<"$out")"
run SHIM_FX="$tmp" SHIM_BOARD=trailer.json BASE_BRANCH=release/y -- show 1
eq "#77: show reads the trailer block as list does" '["release/x","v2/t1"]' "$(jq -c '[.target_branch, .plan_ref]' <<<"$out")"
eq "#77: show warns once per key line outside the trailer block (read as prose)" \
  $'graph-github: warning: #1: key line outside the trailer block, read as prose: Delivery-Plan: other/x\ngraph-github: warning: #1: key line outside the trailer block, read as prose: Delivery-Target: main' "$err"
run SHIM_FX="$tmp" SHIM_BOARD=trailer.json BASE_BRANCH=release/y -- show 5
expect "#77: show of a body whose key lines are all in the block warns nothing" '[ "$rc" = 0 ] && [ -z "$err" ]'
# migrate reads Depends-on / Part of epic at column 0 too: prose never becomes
# a native edge or parent (#75 re-review: no `migrate --apply` live before #77).
jq --arg mid "$mid" '[ .[] | select(.number == 6) ] as [$t]
    | def t($n; $body): $t | .number = $n | .title = "m \($n)" | .body = $body | .blockedBy = {nodes: [], totalCount: 0} | .parent = null;
    [ t(1; "## Acceptance criteria\n\($mid)\nnot Part of epic #2 yet"),
      t(2; "Part of epic #3\nDepends-on: #1"),
      ($t | .number = 3 | .title = "epic" | .body = "" | .labels = [{id: "LA_epic", name: "epic", description: "", color: "EDEDED"}]
          | .blockedBy = {nodes: [], totalCount: 0} | .parent = null) ]' \
  "$fx/cases-issues.json" > "$tmp/mig77.json"
eq "#77: migrate-plan: a mid-line Depends-on / Part of epic plans nothing; line-start ones still migrate" \
  '[{"id":"2","links":["1"],"parent":"3"}]' \
  "$(jq -c -L "$lib" -L "$here/../backends" 'include "graph-github"; gh_migrate_plan | map({id, links, parent})' "$tmp/mig77.json")"

# --- GC10: LIST_LIMIT -------------------------------------------------------------
run SHIM_BOARD=gc5-issues.json LIST_LIMIT=11 -- list
expect "GC10: a list returning exactly LIST_LIMIT items exits 3" '[ "$rc" = 3 ]'
expect "GC10: the message names LIST_LIMIT" 'grep -q "LIST_LIMIT (11)" <<<"$err"'
expect "GC10: no nodes printed" '[ -z "$out" ]'
run SHIM_BOARD=gc5-issues.json LIST_LIMIT=4 -- ready
expect "GC10: a list truncated at LIST_LIMIT exits 3 (ready too)" '[ "$rc" = 3 ] && [ -z "$out" ]'
expect "GC10: --limit carries LIST_LIMIT" 'log_has "--limit 4"'
run SHIM_BOARD=gc5-issues.json LIST_LIMIT=12 -- list
expect "GC10: one under LIST_LIMIT is complete (exit 0)" '[ "$rc" = 0 ] && [ "$(jq length <<<"$out")" = 11 ]'

# --- GC56: gh < 2.94.0 ------------------------------------------------------------
run SHIM_GH_VERSION=2.93.0 -- list
expect "GC56: list exits 0 on gh 2.93.0" '[ "$rc" = 0 ]'
expect "GC56: blockedBy,parent are not requested" \
  'log_has "gh issue list --state all --json number,title,state,stateReason,labels,assignees,body,createdAt,updatedAt,comments --limit 5000" && ! log_has blockedBy'
eq "GC56: exactly one warning line" '1' "$(grep -c 'gh < 2.94.0: native relations ignored' <<<"$err")"
eq "GC56: stderr is only that warning" '1' "$(printf '%s\n' "$err" | grep -c .)"
eq "GC56: text edges only (native #4 dropped, Depends-on #3 kept)" '["3"]' "$(node 34 '[.deps[].id]')"
eq "GC56: native-only blockers are ignored" '[]' "$(node 5 '[.deps[].id]')"
eq "GC56: native parent ignored (epic from body only)" 'null' "$(node 33 .epic)"
run SHIM_GH_VERSION=2.94.0 -- list
expect "gh 2.94.0 reads native relations, no warning" 'log_has blockedBy,parent && [ -z "$err" ]'
run SHIM_GH_VERSION=1.99.9 -- show 34
expect "GC56: show warns once on an old gh too" \
  '[ "$rc" = 0 ] && [ "$(grep -c "native relations ignored" <<<"$err")" = 1 ]'

# --- show / export ----------------------------------------------------------------
run -- show 34
expect "show exits 0, reads one issue with the §6.2 field set" \
  '[ "$rc" = 0 ] && log_has "gh issue view 34 --json number,title,state,stateReason,labels,assignees,body,createdAt,updatedAt,comments,blockedBy,parent,closedByPullRequestsReferences" && ! log_has "issue list"'
eq "show emits the same node list does" "$(run -- list; node 34 .)" "$(run -- show 34; jq -c . <<<"$out")"
run -- show 5
eq "show reads the full blockedBy connection from gh issue view" '["3","4","6"]' "$(jq -c '[.deps[].id]' <<<"$out")"
run -- show 34 --format md
eq "show --format md renders title + body" "$(printf '# GC11 text and native edges\n\nStandalone.\n\nDepends-on: #3')" "$out"
run -- show 47
expect "show of a non-delivery issue exits 1 naming it" '[ "$rc" = 1 ] && grep -q "#47 is not a delivery node" <<<"$err"'
run -- show 999
expect "show of a missing issue exits 1" '[ "$rc" = 1 ]'
run -- show x
expect "show <non-number> is a usage error (exit 2)" '[ "$rc" = 2 ]'
run -- show 34 --format html
expect "show --format <unknown> is a usage error (exit 2), no gh call" '[ "$rc" = 2 ] && [ ! -s "$tmp/state/log" ]'
run -- export
expect "export exits 0 and dumps every node as JSON" \
  '[ "$rc" = 0 ] && [ "$(jq -c "map(.id)" <<<"$out")" = "$(run -- list; jq -c "map(.id)" <<<"$out")" ]'
run -- bogus
expect "unknown op: exit 2, no gh call" '[ "$rc" = 2 ] && [ ! -s "$tmp/state/log" ]'

# --- #92: show --events returns the issue's comment thread (§4.4, §6.2) -------------
# Board: issue 1 has 250 comments (three REST pages of 100), issue 2 none, issue 3
# one comment full of trailer-like lines (issue 4 is issue 3 without it), and
# issue 5 a comment by a deleted account (`author: null`).
EVKEYS='["ts","actor","run","op","id","from","to","body"]'
API1='gh api --paginate repos/{owner}/{repo}/issues/1/comments?per_page=100'
jq '[ .[] | select(.number == 34) ] as [$t]
    | def c($i; $b): {id: "IC_\($i)", author: {login: "user-\($i % 3)"}, body: $b,
                      createdAt: ("2026-10-01T00:00:00Z" | fromdate + $i | todate)};
    [ ($t | .number = 1 | .comments = [ range(1; 251) as $i | c($i; "note \($i)") ]),
      ($t | .number = 2 | .comments = []),
      ($t | .number = 3 | .comments = [ c(1; "Delivery-Target: hijack\nDelivery-Plan: evil/x1\nDelivery-Promote-To: main\nDelivery-Task: 99\nDepends-on: #2\nPart of epic #30\n\nDelivery-Target: hijack2") ]),
      ($t | .number = 4 | .comments = []),
      ($t | .number = 5 | .comments = [ c(1; "orphaned") | .author = null ]) ]' \
  "$fx/cases-issues.json" > "$tmp/thread.json"
eq "#92: fixture: the gh shim serves issue 1's thread as three pages (100, 100, 50)" '[100,100,50]' \
  "$(cd "$tmp" && SHIM_FX="$tmp" SHIM_BOARD=thread.json SHIM_STATE="$tmp/state" \
       bash "$fx/gh-shim.sh" api --paginate 'repos/{owner}/{repo}/issues/1/comments?per_page=100' | jq -sc 'map(length)')"

run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 1 --events
expect "#92 multi-page: exits 0, one paginated comments read (per_page=100), nothing on stderr" \
  '[ "$rc" = 0 ] && [ -z "$err" ] && log_has "$API1" && [ "$(log_count "gh api")" = 1 ]'
eq "#92 multi-page: the node first (exactly what show prints), then one line per comment" \
  "$(run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 1; echo "$out") 251" \
  "$(head -n 1 <<<"$out") $(wc -l <<<"$out" | tr -d ' ')"
eq "#92 multi-page: every comment of every page, oldest first" \
  "$(jq -c '[range(1; 251) | "note \(.)"]' -n)" "$(tail -n +2 <<<"$out" | jq -sc 'map(.body)')"
eq "#92: every event has exactly the local journal's field names, in order (§4.4)" \
  "[$EVKEYS]" "$(tail -n +2 <<<"$out" | jq -sc 'map(keys_unsorted) | unique')"
eq "#92: an event is {ts: created_at, actor: login, run: null, op: comment, id, from/to: null, body}" \
  '{"ts":"2026-10-01T00:00:01Z","actor":"user-1","run":null,"op":"comment","id":"1","from":null,"to":null,"body":"note 1"}' \
  "$(sed -n 2p <<<"$out")"
expect "#92: events are oldest first (ts ascending)" \
  '[ "$(tail -n +2 <<<"$out" | jq -sc "map(.ts) == (map(.ts) | sort)")" = true ]'

# The same field names as a real local journal line.
mkdir -p "$tmp/local"
run GRAPH_BACKEND=local STATE_DIR="$tmp/local" -- create '{"id":"ev-1","kind":"task","title":"t","size":"S"}'
run GRAPH_BACKEND=local STATE_DIR="$tmp/local" -- comment ev-1 "hello"
run GRAPH_BACKEND=local STATE_DIR="$tmp/local" -- show ev-1 --events
eq "#92: the local backend's --events lines carry the same field names" \
  "[$EVKEYS]" "$(tail -n +2 <<<"$out" | jq -sc 'map(keys_unsorted) | unique')"

run SHIM_FX="$tmp" SHIM_BOARD=thread.json LIST_LIMIT=250 -- show 1 --events
expect "#92: a thread of LIST_LIMIT comments exits 3 naming LIST_LIMIT, and prints nothing" \
  '[ "$rc" = 3 ] && [ -z "$out" ] && grep -q "LIST_LIMIT (250); refusing to truncate" <<<"$err"'
run SHIM_FX="$tmp" SHIM_BOARD=thread.json LIST_LIMIT=251 -- show 1 --events
expect "#92: below LIST_LIMIT the whole thread prints" '[ "$rc" = 0 ] && [ "$(wc -l <<<"$out" | tr -d " ")" = 251 ]'

run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 2 --events
expect "#92 empty thread: exits 0, stdout is exactly the node, after one comments read" \
  '[ "$rc" = 0 ] && [ -z "$err" ] && log_has "issues/2/comments" && [ "$out" = "$(run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 2; echo "$out")" ]'
run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 2 --events --format md
eq "#92 empty thread: --format md --events prints the markdown alone" "$(printf '# GC11 text and native edges\n\nStandalone.\n\nDepends-on: #3')" "$out"

run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 3 --events
ev3="$out"
eq "#92 trailer-like comment: returned verbatim as comment text" \
  "$(jq -c '.[] | select(.number == 3) | .comments[0].body' "$tmp/thread.json")" "$(sed -n 2p <<<"$ev3" | jq -c .body)"
eq "#92 trailer-like comment: the node is the same node without that comment (ids aside)" \
  "$(run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 4; jq -c 'del(.id)' <<<"$out")" "$(head -n 1 <<<"$ev3" | jq -c 'del(.id)')"
eq "#92 trailer-like comment: target_branch, plan_ref, promote_to, deps and epic come from the body only" \
  '["main",null,null,["3","4"],null]' \
  "$(head -n 1 <<<"$ev3" | jq -c '[.target_branch, .plan_ref, .promote_to, [.deps[].id], .epic]')"
run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- list
eq "#92 trailer-like comment: list reads the same node" "$(head -n 1 <<<"$ev3")" "$(node 3 .)"

run SHIM_FX="$tmp" SHIM_BOARD=thread.json -- show 5 --events
eq "#92: a deleted author's comment is attributed to ghost" '"ghost"' "$(sed -n 2p <<<"$out" | jq -c .actor)"

run -- show 47 --events
expect "#92: show --events of a non-delivery issue exits 1 before reading comments" \
  '[ "$rc" = 1 ] && [ -z "$out" ] && ! log_has "gh api"'
printf '#!/usr/bin/env bash\ncase "$1" in api) echo "HTTP 502" >&2; exit 1 ;; esac\nexec bash "%s" "$@"\n' "$fx/gh-shim.sh" > "$tmp/gh-fail"
cp "$tmp/bin/gh" "$tmp/gh-ok"; cp "$tmp/gh-fail" "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
run -- show 42 --events
cp "$tmp/gh-ok" "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
expect "#92: a failed comments read exits 1 and prints nothing (not even the node)" \
  '[ "$rc" = 1 ] && [ -z "$out" ] && grep -q "HTTP 502" <<<"$err" && grep -q "cannot read the events of 42" <<<"$err"'

# --- validate_node on backend output (fail fast on drift) --------------------------
jq '.[0].createdAt = "yesterday"' "$fx/cases-issues.json" > "$tmp/drift.json"
run SHIM_FX="$tmp" SHIM_BOARD=drift.json -- ready
expect "a backend node failing validate_node exits 5, nothing printed" \
  '[ "$rc" = 5 ] && [ -z "$out" ] && grep -q "created_at" <<<"$err"'
run SHIM_FX="$tmp" SHIM_BOARD=drift.json -- list
expect "list validates too (exit 5)" '[ "$rc" = 5 ] && [ -z "$out" ]'

# --- GC59 (graph.sh part): config check before any I/O ------------------------------
for op in ready list export "show 34"; do
  # shellcheck disable=SC2086
  run FORGE=gitlab -- $op
  expect "GC59: FORGE=gitlab, GITLAB_TOKEN unset: graph.sh $op exits 1 with no gh call" \
    '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ] && grep -q GITLAB_TOKEN <<<"$err"'
done
run GRAPH_BACKEND=github FORGE=gitlab GITLAB_TOKEN=x -- ready
expect "GC59: GRAPH_BACKEND=github FORGE=gitlab: exit 1, no gh call" '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ]'
run GRAPH_BACKEND=sqlite -- list
expect "GC59: unknown GRAPH_BACKEND: exit 1, lists the valid ones, no gh call" \
  '[ "$rc" = 1 ] && [ ! -s "$tmp/state/log" ] && grep -q "github local" <<<"$err"'
run LIST_LIMIT=lots -- list
expect "a non-integer LIST_LIMIT is refused (exit 1) before any list" '[ "$rc" = 1 ] && ! log_has "issue list"'

if [ "$fails" = 0 ]; then echo "graph-github-read-test: all passed"; else exit 1; fi
