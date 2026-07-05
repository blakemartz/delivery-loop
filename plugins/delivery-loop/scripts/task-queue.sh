#!/usr/bin/env bash
# task-queue.sh — print the READY set as JSON lines, best task first.
#
# A task is READY iff: open, labeled `task`, every issue referenced by a
# `Depends-on: #N #M` line in its body is CLOSED, it has zero assignees,
# it is not size:L (L = "split me", never claimable), and it is not
# `needs-human` (an escalated task awaits a human — never auto-claimable).
#
# Ordering: tasks whose epic is already in progress (>=1 child task closed)
# first, then unblocks the most open tasks, then size:S before size:M, then
# oldest first. The started-epic bias finishes partway-done epics before opening
# new ones, so stragglers aren't stranded when fresh epics arrive.
#
# --fix additionally reconciles derived state (labels are a cache, ground
# truth is issue/PR state — see docs/agentic_delivery_spec.md §5.1):
#   * status:blocked -> status:ready when all deps have closed
#   * status:ready   -> status:blocked when deps are actually unmet
#   * stale AGENT claims (claim:agent, no open PR referencing the issue,
#     no activity for 4h) are released back to status:ready
#   * stale HUMAN claims (assignee, no claim:agent, inactive 72h) get one
#     comment ping — never auto-reclaimed
#   * fully-delivered EPICS are closed: an open `epic` issue every one of
#     whose child tasks is closed (and which has >=1 child) is done. Children
#     are the union of tasks whose body says "Part of epic #E" and the `#N`
#     refs in the epic's own "- [ ] #N" checklist.
set -euo pipefail

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

open_tasks=$(gh issue list --label task --state open --limit 500 \
  --json number,title,labels,assignees,body,createdAt,updatedAt)
all_states=$(gh issue list --state all --limit 1000 --json number,state)
open_prs=$(gh pr list --state open --json number,body,title 2>/dev/null || echo '[]')

# Annotate every open task with deps / depsClosed / labelNames / staleness.
annotated=$(jq -c --argjson states "$all_states" --argjson prs "$open_prs" '
  ($states | map({key: (.number|tostring), value: .state}) | from_entries) as $st
  | map(
      .labelNames = ([.labels[].name])
      | .deps = ([ (.body // "")
                   | capture("Depends-on:(?<line>[^\n]*)"; "g").line
                   | scan("#[0-9]+") | ltrimstr("#") | tonumber ] | unique)
      | .depsClosed = ([.deps[] as $d | ($st[$d|tostring] // "OPEN") == "CLOSED"] | all)
      | .epic = ([ (.body // "") | scan("[Ee]pic #([0-9]+)") | .[0] | tonumber ] | first // null)
      | .number as $n
      | .hasOpenPr = ([$prs[] | select((.body + " " + .title) | test("#\($n)\\b"))] | length > 0)
      | .idleSeconds = (now - (.updatedAt | fromdateiso8601))
      | {number, title, labelNames, deps, depsClosed, epic, hasOpenPr, idleSeconds,
         createdAt, assignees: [.assignees[].login]}
    )' <<<"$open_tasks")

if [ "$FIX" = 1 ]; then
  # blocked -> ready (never un-freeze a needs-human task)
  jq -r '.[] | select(.depsClosed and (.labelNames | index("status:blocked"))
                and ((.labelNames | index("needs-human")) | not))
         | .number' <<<"$annotated" | while read -r n; do
    gh issue edit "$n" --add-label "status:ready" --remove-label "status:blocked" >/dev/null
    echo "fix: #$n blocked -> ready" >&2
  done
  # ready -> blocked (deps actually unmet)
  jq -r '.[] | select((.depsClosed | not) and (.labelNames | index("status:ready")))
         | .number' <<<"$annotated" | while read -r n; do
    gh issue edit "$n" --add-label "status:blocked" --remove-label "status:ready" >/dev/null
    echo "fix: #$n ready -> blocked (unmet deps)" >&2
  done
  # stale agent claims: 4h idle, claimed by an agent, no open PR
  jq -r '.[] | select((.labelNames | index("claim:agent"))
                and (.hasOpenPr | not)
                and (.idleSeconds > 4*3600)
                and ((.labelNames | index("needs-human")) | not))
         | [.number, (.assignees | join(","))] | @tsv' <<<"$annotated" \
  | while IFS=$'\t' read -r n logins; do
    for login in ${logins//,/ }; do
      gh issue edit "$n" --remove-assignee "$login" >/dev/null
    done
    gh issue edit "$n" --add-label "status:ready" \
      --remove-label "status:claimed" --remove-label "claim:agent" >/dev/null
    gh issue comment "$n" --body \
      "RECLAIMED: agent claim was idle >4h with no open PR; task is ready again." >/dev/null
    echo "fix: #$n stale agent claim reclaimed" >&2
  done
  # stale human claims: ping once, never reclaim
  jq -r '.[] | select((.assignees | length > 0)
                and ((.labelNames | index("claim:agent")) | not)
                and (.idleSeconds > 72*3600))
         | .number' <<<"$annotated" | while read -r n; do
    pings=$(gh issue view "$n" --json comments \
      --jq '[.comments[] | select(.body | startswith("STALE-CLAIM-PING"))] | length')
    if [ "$pings" = "0" ]; then
      gh issue comment "$n" --body \
        "STALE-CLAIM-PING: this claim has been inactive for 72h — still on it? (Human claims are never auto-reclaimed.)" >/dev/null
      echo "fix: #$n stale human claim pinged" >&2
    fi
  done
  # fully-delivered epics -> closed. An open `epic` issue is done once every
  # child task is closed; children are the union of tasks whose body says
  # "Part of epic #E" and the `#N` refs in the epic's own "- [ ] #N" checklist.
  # The >=1-child guard keeps a freshly-created epic (tasks not filed yet) from
  # closing itself vacuously.
  gh issue list --state all --limit 1000 --json number,state,body,labels --jq '
    map(.labelNames = [.labels[].name]) as $all
    | ($all | map({key:(.number|tostring), value:.state}) | from_entries) as $st
    | $all[]
    | select((.labelNames | index("epic")) and .state == "OPEN")
    | .number as $e
    | ([ (.body // "") | scan("(?im)^[ \t]*[-*] \\[[ xX]\\][ \t]*#([0-9]+)") | .[0] | tonumber ]) as $checklist
    | ([ $all[] | select((.body // "") | test("Part of epic #\($e)([^0-9]|$)")) | .number ]) as $tasks
    | (($checklist + $tasks) | unique) as $children
    | select(($children | length) > 0)
    | select([ $children[] | ($st[(.|tostring)] // "OPEN") == "CLOSED" ] | all)
    | "\($e)\t\($children | length)"' \
  | while IFS=$'\t' read -r e count; do
    gh issue close "$e" --reason completed --comment \
      "AUTO-CLOSE: epic fully delivered — all $count child tasks are closed. (Reconciled by scripts/task-queue.sh --fix.)" >/dev/null
    echo "fix: #$e epic fully delivered -> closed" >&2
  done
  # re-fetch after mutations so the printed ready set reflects the fixes
  open_tasks=$(gh issue list --label task --state open --limit 500 \
    --json number,title,labels,assignees,body,createdAt,updatedAt)
  annotated=$(jq -c --argjson states "$all_states" --argjson prs "$open_prs" '
    ($states | map({key: (.number|tostring), value: .state}) | from_entries) as $st
    | map(
        .labelNames = ([.labels[].name])
        | .deps = ([ (.body // "")
                     | capture("Depends-on:(?<line>[^\n]*)"; "g").line
                     | scan("#[0-9]+") | ltrimstr("#") | tonumber ] | unique)
        | .depsClosed = ([.deps[] as $d | ($st[$d|tostring] // "OPEN") == "CLOSED"] | all)
        | .epic = ([ (.body // "") | scan("[Ee]pic #([0-9]+)") | .[0] | tonumber ] | first // null)
        | {number, title, labelNames, deps, depsClosed, epic, createdAt,
           assignees: [.assignees[].login]}
      )' <<<"$open_tasks")
fi

# Epics that are "in progress" — at least one child task is already CLOSED.
# Children are the union of the epic checklist's "#N" refs and every task whose
# body backlinks it via "epic #N". The `[Ee]pic #N` match also catches the older
# "Part of epic #N" phrasing (that string contains "epic #N"), so both decompose
# conventions count — deliberately broader than the auto-close reconciler's
# `Part of epic`-only arm, so a started epic is detected whichever convention its
# children use. A task's epic inherits this flag; the ready set then finishes
# started epics before opening new ones. Computed after --fix so it reflects
# just-reconciled closures.
all_issues=$(gh issue list --state all --limit 1000 --json number,state,body,labels)
started_epics=$(jq -c '
  (map(.labelNames = [.labels[].name])) as $all
  | ($all | map({key: (.number|tostring), value: .state}) | from_entries) as $st
  | [ $all[]
      | select(.labelNames | index("epic"))
      | .number as $e
      | ([ (.body // "") | scan("(?im)^[ \t]*[-*] \\[[ xX]\\][ \t]*#([0-9]+)") | .[0] | tonumber ]) as $checklist
      | ([ $all[] | select((.body // "") | test("[Ee]pic #\($e)([^0-9]|$)")) | .number ]) as $tasks
      | (($checklist + $tasks) | unique) as $children
      | select([ $children[] | ($st[(.|tostring)] // "OPEN") == "CLOSED" ] | any)
      | $e ]' <<<"$all_issues")

# The ready set, best first.
jq -c --argjson started "$started_epics" '
  . as $all
  | [ .[]
      | select(.assignees == []
               and .depsClosed
               and ((.labelNames | index("needs-human")) | not)
               and ((.labelNames | index("size:L")) | not))
      | .number as $n
      | .unblocks = ([$all[] | select(.deps | index($n))] | length)
      | .sizeRank = (if (.labelNames | index("size:S")) then 0 else 1 end)
      | (.epic) as $ep
      | .epicStartedRank = (if ($ep != null) and (($started | index($ep)) != null) then 0 else 1 end)
    ]
  | sort_by([.epicStartedRank, -.unblocks, .sizeRank, .createdAt])
  | .[]
  | {number, title, unblocks, size: (if .sizeRank == 0 then "S" else "M" end),
     started: (.epicStartedRank == 0), epic: .epic,
     module: ([.labelNames[] | select(startswith("module:"))] | first // "none")}
' <<<"$annotated"
