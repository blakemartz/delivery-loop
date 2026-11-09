#!/usr/bin/env bash
# graph.sh <op> [args] — the graph seam (docs/delivery_graph_spec.md §3, §6.1).
#
# Skills and engine scripts read the work graph through this, never `gh issue`
# directly (§3 rule 3). It resolves the config, validates the combination once
# (`delivery-config.sh --check` semantics, §11) before any I/O, loads nodes from
# backends/graph-$GRAPH_BACKEND.sh, runs validate_node on every backend output
# (fail fast on drift, §4.1) and applies the lib/*.jq policy core (§3 rule 1:
# backends store, they never decide).
#
# Ops:
#   ready                       the ready set, best first, one JSON line each
#                               (lib/ready.jq: {id, title, unblocks, size,
#                               started, epic, module, target_branch}).
#   list                        every node, open and closed, as one compact
#                               JSON array.
#   show <id> [--format json|md] [--events]
#                               one node (json, the default), or its title and
#                               body as markdown for agent prompts. The markdown
#                               is rendered here from the validated node, so
#                               every backend gets it. Without --events stdout
#                               is exactly that one node, the §6.1 contract
#                               callers parse (task-worktree.sh does), and
#                               nothing else is printed.
#                               --events (local backend, §6.3): the node's last
#                               10 journal events follow it on stdout, one JSON
#                               object per line. Opt-in, so the hot read stays
#                               quiet; an unreadable journal is then an error
#                               (exit 1), and a backend with no journal refuses
#                               it (exit 1).
#   export                      every node as pretty-printed JSON, for backup
#                               and debugging.
#   create <node-json>|-  ·  update <id> <patch-json>|-  ·  link <id> <dep-id> [via]
#   ·  flag <id> needs-human on|off  ·  release <id> <reason>  ·  comment <id> <text>|-
#                               routed unchanged (args, stdin, stdout, exit
#                               status) to the backend primitive (§6.1), which
#                               validates its input. A nonzero id-less create
#                               may still have created the node: look it up by
#                               plan_ref/title before retrying.
#   claim <id> <actor> [--run <run>]  ·  claim <id> --human <name>
#                               policy pre-check (the node is valid, ready ->
#                               claimed is legal for the actor kind, no claim,
#                               and an agent never claims a needs_human node),
#                               then the backend's atomic claim (§6.3, GC21).
#                               The run defaults to <host>-<pid>-<epoch>; a
#                               human claim has none. Exit 0 = owned, 1 = lost
#                               or not claimable.
#   transition <id> <to> [--actor agent|human|promote] [--human <name>]
#                               validates (from, to, actor) with
#                               lib/transitions.jq (actor default agent;
#                               `--human <name>` is the human actor, passed to
#                               the backend's update as `--actor <name>` so the
#                               write records who made it) and exits 2
#                               on an illegal move without writing (GC8, GC47:
#                               only a human cancels); an `external` node takes
#                               no transition (exit 2). A legal move is the
#                               backend's `update <id> {"status": <to>}`.
#   reconcile [--fix]           lib/reconcile.jq over every node and the forge's
#                               PRs: `forge.sh pr-list --state open` plus
#                               `--state merged --since <oldest open node's
#                               created_at>` (§5, §6.2, §6.3). Warnings go to
#                               stderr as `warn: …`. Without --fix the fix
#                               records are printed, one JSON object per line,
#                               and nothing is written. With --fix each record
#                               is applied through the backend's `reconcile`
#                               primitive, a compare-and-set against the node as
#                               the plan saw it, and printed as
#                               `fix: <op> <id> <from> -> <to>: <reason>`.
#                               Records cascade (x -> done, so its dependent ->
#                               ready), so applying stops at the first record
#                               not applied: the rest of the plan rests on it.
#                               Each unapplied record is a `warn: not applied`
#                               line. A record the board outran (backend exit
#                               4) exits 4, "board changed; re-run reconcile";
#                               a backend that could not take its lock in
#                               time (exit 75) exits 75, "busy; retry"; any
#                               other backend failure exits 1. The next pass
#                               re-plans from fresh state. Wrappers treat 4
#                               and 75 as retryable.
#   migrate [--apply]           github only (§6.2, GC48): for every open task,
#                               a native blocked-by for each legacy
#                               `Depends-on:` ref and the native parent from
#                               `Part of epic #E` (the backend's migrate-plan).
#                               Text lines stay in place. Without --apply it is
#                               a dry run: each planned edit is printed as one
#                               JSON object per line ({op: "link", id, dep} or
#                               {op: "parent", id, epic}) and nothing is
#                               written. With --apply each edit goes through
#                               the backend's idempotent `link` / `parent` and
#                               is printed as `migrate: link <id> blocked-by
#                               <dep>` / `migrate: parent <id> -> <epic>`, so a
#                               second run plans and issues 0 edits. Before any
#                               write (dry run too), an issue that would exceed
#                               50 blockers (GitHub's per-relationship cap), or
#                               a dep that would block more than 50 issues, is
#                               named and the run exits 1 with nothing
#                               written. A ref GitHub would reject (not an
#                               issue in this repo, a PR, cross-repo
#                               `owner/repo#N`, a self edge) is never planned,
#                               so --apply cannot wedge on it. A plan warning
#                               goes to stderr as `warn: …`; the summary line
#                               goes to stderr.
#
# Exit codes: 0 ok · 1 failed / invalid config / not claimable · 2 usage · 3
# the backend list reached LIST_LIMIT · 4 reconcile --fix: the board changed
# since the plan (stopped; re-run reconcile) · 5 a backend emitted a node that
# fails validate_node · 75 the backend's lock was busy (reconcile --fix, claim;
# retry). A routed write op exits with its backend's status; transition exits 2
# on an illegal move.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

usage() {
  echo "usage: graph.sh ready | list | show <id> [--format json|md] [--events] | export | create <node-json> | update <id> <patch-json> | link <id> <dep-id> [via] | flag <id> needs-human on|off | claim <id> <actor> [--run <run>] | claim <id> --human <name> | release <id> <reason> | comment <id> <text> | transition <id> <to> [--actor agent|human|promote] [--human <name>] | reconcile [--fix] | migrate [--apply] (docs/delivery_graph_spec.md §6.1)" >&2
  exit 2
}

op="${1:-}"
[ $# -eq 0 ] || shift
case "$op" in
  ready|list|export) [ $# -eq 0 ] || usage ;;
  reconcile) [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --fix ]; } || usage ;;
  migrate) [ $# -eq 0 ] || { [ $# -eq 1 ] && [ "$1" = --apply ]; } || usage ;;
  show|claim|transition|create|update|link|flag|release|comment) : ;;
  *) usage ;;
esac

[ "$op" != migrate ] || [ "$GRAPH_BACKEND" = github ] || {
  echo "graph.sh: migrate is github only (GRAPH_BACKEND=$GRAPH_BACKEND has no legacy text edges, §6.2)" >&2; exit 1; }

backend="$SCRIPT_DIR/backends/graph-$GRAPH_BACKEND.sh"
[ -f "$backend" ] || { echo "graph.sh: no backend for GRAPH_BACKEND=$GRAPH_BACKEND ($backend missing)" >&2; exit 1; }

# Plain writes are the backend's primitives verbatim: exec, so stdin (`-`),
# stdout and the exit status pass straight through (§6.1). They exec BEFORE the
# temp dir exists; below it, never exec: exec replaces the shell and skips the
# EXIT trap, leaking the dir. Run the backend and exit with its status instead.
case "$op" in
  create|update|link|flag|release|comment) exec bash "$backend" "$op" "$@" ;;
esac

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# pjq <filter> <file> [jq args…]: run a policy filter; any jq failure (a node
# failing validate_node, or output that is not JSON) is shape drift: exit 5.
pjq() {
  local filter="$1" file="$2"; shift 2
  jq -L "$SCRIPT_DIR/lib" "$@" "$filter" "$file" 2> "$tmp/jq.err" || {
    sed 's/^jq: error (at [^)]*): //' "$tmp/jq.err" >&2
    echo "graph.sh: backend $GRAPH_BACKEND emitted invalid nodes (§4.1)" >&2
    exit 5
  }
}

ALL='include "node";
  if type != "array" then error("backend list must emit a JSON array (got \(type))")
  else map(validate_node) end'

# The backend's exit status (3 for LIST_LIMIT) passes through unchanged.
load_all() { bash "$backend" list > "$tmp/nodes.json" || exit $?; }

case "$op" in
  ready)
    load_all
    pjq 'include "ready"; ready' "$tmp/nodes.json" -c ;;
  list)
    load_all
    pjq "$ALL" "$tmp/nodes.json" -c ;;
  export)
    load_all
    pjq "$ALL" "$tmp/nodes.json" ;;
  show)
    id="" format=json events=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --format) format="${2:-}"; [ $# -ge 2 ] || usage; shift 2 ;;
        --events) events=1; shift ;;
        -*) usage ;;
        *) [ -z "$id" ] || usage; id="$1"; shift ;;
      esac
    done
    [ -n "$id" ] || usage
    case "$format" in json|md) : ;; *) usage ;; esac
    # The journal is the local store's audit trail (§6.3); github's history is
    # the issue timeline, which no primitive reads yet.
    [ -z "$events" ] || [ "$GRAPH_BACKEND" = local ] || {
      echo "graph.sh: show --events: backend $GRAPH_BACKEND has no journal" >&2; exit 1; }
    bash "$backend" show "$id" > "$tmp/node.json" || exit $?
    if [ "$format" = md ]; then
      pjq 'include "node"; validate_node | "# \(.title)\n\n\(.body)"' "$tmp/node.json" -r
    else
      pjq 'include "node"; validate_node' "$tmp/node.json" -c
    fi
    # The backend's show already read this journal (pinged_at derives from it)
    # and warned about anything unparsable, so the journal read's own copy of
    # that warning is kept only if the read fails.
    if [ -n "$events" ]; then
      bash "$backend" journal "$id" 10 2> "$tmp/journal.err" || {
        cat "$tmp/journal.err" >&2
        echo "graph.sh: show --events: cannot read the journal of $id" >&2
        exit 1
      }
    fi ;;
  claim)
    id="${1:-}" actor="" run="" by=agent
    [ -n "$id" ] && [ "${id#-}" = "$id" ] || usage
    shift
    case "${1:-}" in
      --human) [ $# -eq 2 ] && [ -n "$2" ] || usage; actor="$2" by=human ;;
      ''|-*) usage ;;
      *) actor="$1"; shift
         case $# in
           0) : ;;
           2) [ "$1" = --run ] && [ -n "$2" ] || usage; run="$2" ;;
           *) usage ;;
         esac ;;
    esac
    [ "$by" = human ] || [ -n "$run" ] || run="$(uname -n)-$$-$(date +%s)"
    bash "$backend" show "$id" > "$tmp/node.json" || exit $?
    why=$(pjq 'include "node"; include "transitions"; validate_node
      | transition_error("claimed"; $by) as $e
      | if $e != null then $e
        elif .claim != null then "\(.id | tojson) is already claimed by \(.claim.actor)"
        elif $by == "agent" and .needs_human then "\(.id | tojson) is needs-human"
        else empty end' "$tmp/node.json" -r --arg by "$by")
    [ -z "$why" ] || { echo "graph.sh: not claimable: $why" >&2; exit 1; }
    rc=0
    bash "$backend" claim "$id" "$actor" "${run:--}" "$by" || rc=$?
    exit "$rc" ;;
  transition)
    id="${1:-}" to="${2:-}" actor=agent name=""
    [ -n "$id" ] && [ "${id#-}" = "$id" ] && [ -n "$to" ] && [ "${to#-}" = "$to" ] || usage
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --actor) [ $# -ge 2 ] || usage
                 case "$2" in agent|human|promote) actor="$2" ;; *) usage ;; esac; shift 2 ;;
        --human) [ $# -ge 2 ] && [ -n "$2" ] || usage; actor=human name="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    # The node as the backend stores it. A backend's `show` serves its delivery
    # nodes; an id it refuses may still be an `external` node of the list.
    rc=0
    bash "$backend" show "$id" > "$tmp/node.json" 2> "$tmp/show.err" || rc=$?
    if [ "$rc" -ne 0 ]; then
      load_all
      pjq "$ALL"' | map(select(.id == $id)) | first // empty' "$tmp/nodes.json" -c --arg id "$id" > "$tmp/node.json"
      if [ ! -s "$tmp/node.json" ]; then cat "$tmp/show.err" >&2; exit "$rc"; fi
    fi
    why=$(pjq 'include "node"; include "transitions"; validate_node | transition_error($to; $actor) // empty' \
      "$tmp/node.json" -r --arg to "$to" --arg actor "$actor")
    [ -z "$why" ] || { echo "graph.sh: transition refused: $why" >&2; exit 2; }
    rc=0
    jq -cn --arg to "$to" '{status: $to}' > "$tmp/patch.json"
    # A named human is recorded as the write's actor (local: the journal;
    # github: a TRANSITIONED comment).
    set -- update "$id" "$(cat "$tmp/patch.json")"
    [ -z "$name" ] || set -- "$@" --actor "$name"
    bash "$backend" "$@" < /dev/null || rc=$?
    exit "$rc" ;;
  migrate)
    # GitHub links at most 50 issues per relationship type (changelog
    # 2025-08-21; not in the REST reference, so enforced defensively, §6.2).
    cap=50
    bash "$backend" migrate-plan > "$tmp/migrate.json" || exit $?
    jq -e 'type == "array"' "$tmp/migrate.json" > /dev/null 2>&1 || {
      echo "graph.sh: migrate: backend $GRAPH_BACKEND emitted no plan array" >&2; exit 1; }
    jq -r '.[].warnings[] | "warn: \(.)"' "$tmp/migrate.json" >&2
    over=$(jq -r --argjson cap "$cap" '.[] | select(.links != [] and .blockers > $cap)
      | "graph.sh: migrate: #\(.id) would have \(.blockers) blockers; GitHub links at most \($cap) per issue"' "$tmp/migrate.json")
    # The cap likely binds the blocking side too: refuse a dep that would block
    # more than $cap issues (the backend's `blocking` count; a lower bound).
    over_b=$(jq -r --argjson cap "$cap" '[ .[] | (.blocking // {}) | to_entries[] | select(.value > $cap) ]
      | unique_by(.key | tonumber)[]
      | "graph.sh: migrate: #\(.key) would block \(.value) issues; GitHub links at most \($cap) per issue"' "$tmp/migrate.json")
    over=$(printf '%s\n%s' "$over" "$over_b" | sed '/^$/d')
    if [ -n "$over" ]; then
      printf '%s\n' "$over" >&2
      echo "graph.sh: migrate: refusing to exceed $cap blockers / blocked issues per issue; split those dependencies, then re-run (nothing written)" >&2
      exit 1
    fi
    jq -c '.[] | (.id as $id | (.links[] | {op: "link", id: $id, dep: .}),
                 (select(.parent != null) | {op: "parent", id: $id, epic: .parent}))' \
      "$tmp/migrate.json" > "$tmp/edits.jsonl"
    edits=$(wc -l < "$tmp/edits.jsonl" | tr -d ' ')
    if [ $# -eq 0 ]; then
      cat "$tmp/edits.jsonl"
      echo "graph.sh: migrate: $edits edit(s) planned (dry run; pass --apply to write them)" >&2
      exit 0
    fi
    done_n=0
    while IFS= read -r e; do
      id=$(jq -r .id <<<"$e")
      case "$(jq -r .op <<<"$e")" in
        link) dep=$(jq -r .dep <<<"$e")
              bash "$backend" link "$id" "$dep" < /dev/null || {
                echo "graph.sh: migrate: link $id blocked-by $dep failed after $done_n of $edits edit(s); re-run (it is idempotent)" >&2; exit 1; }
              echo "migrate: link $id blocked-by $dep" ;;
        parent) epic=$(jq -r .epic <<<"$e")
              bash "$backend" parent "$id" "$epic" < /dev/null || {
                echo "graph.sh: migrate: parent $id -> $epic failed after $done_n of $edits edit(s); re-run (it is idempotent)" >&2; exit 1; }
              echo "migrate: parent $id -> $epic" ;;
      esac
      done_n=$((done_n + 1))
    done < "$tmp/edits.jsonl"
    echo "graph.sh: migrate: $done_n edit(s) applied" >&2 ;;
  reconcile)
    load_all
    pjq "$ALL" "$tmp/nodes.json" -c > "$tmp/valid.json"
    # Ground truth (§6.2, §6.3): the open PRs, plus every PR merged since the
    # oldest open node was created (none open: no merged read is needed).
    bash "$SCRIPT_DIR/forge.sh" pr-list --state open > "$tmp/open.json" || exit $?
    since=$(jq -r -L "$SCRIPT_DIR/lib" 'include "graph";
      [.[] | select(is_open)] | if length == 0 then empty
      else min_by(.created_at | iso_epoch) | .created_at end' "$tmp/valid.json")
    if [ -n "$since" ]; then
      bash "$SCRIPT_DIR/forge.sh" pr-list --state merged --since "$since" > "$tmp/merged.json" || exit $?
    else
      echo '[]' > "$tmp/merged.json"
    fi
    jq -n -L "$SCRIPT_DIR/lib" --slurpfile nodes "$tmp/valid.json" \
      --slurpfile open "$tmp/open.json" --slurpfile merged "$tmp/merged.json" \
      --argjson now "$(date -u +%s)" 'include "reconcile"; include "graph";
      ($nodes[0] | index_by_id) as $idx
      | {nodes: $nodes[0], prs: ($open[0] + $merged[0] | unique_by(.number)), now: $now}
      | reconcile_plan
      | .records |= map(. + {updated_at: $idx[.id].updated_at})' > "$tmp/plan.json" 2> "$tmp/jq.err" || {
      sed 's/^jq: error (at [^)]*): //' "$tmp/jq.err" >&2
      echo "graph.sh: reconcile: cannot plan over the board and the forge's PRs" >&2
      exit 1
    }
    jq -r '.warnings[] | "warn: \(.)"' "$tmp/plan.json" >&2
    if [ $# -eq 0 ]; then
      jq -c '.records[] | del(.updated_at)' "$tmp/plan.json"
      exit 0
    fi
    jq -c '.records[]' "$tmp/plan.json" > "$tmp/records.jsonl"
    # Backend-generic (B2 reuses it). reconcile_plan runs over a working copy,
    # so a record may rest on an earlier one (x -> done, then dep -> ready
    # because x is done), while the backend's compare-and-set checks only the
    # record's own node. Once one record is not applied the rest of the plan is
    # untrusted: stop, list what was not applied, and let the next pass re-plan.
    status=0
    while IFS= read -r rec; do
      line=$(jq -r '"\(.op) \(.id) \(.from) -> \(.to): \(.reason)"' <<<"$rec")
      if [ "$status" -ne 0 ]; then
        echo "warn: not applied $line (the plan is stale)" >&2
        continue
      fi
      rc=0
      bash "$backend" reconcile "$rec" < /dev/null 2> "$tmp/apply.err" || rc=$?
      case "$rc" in
        0) echo "fix: $line" ;;
        4) echo "warn: not applied $line: $(cat "$tmp/apply.err")" >&2; status=4 ;;
        75) echo "warn: not applied $line: $(cat "$tmp/apply.err")" >&2; status=75 ;;
        *) cat "$tmp/apply.err" >&2
           echo "graph.sh: reconcile: failed to apply $line (exit $rc)" >&2; status=1 ;;
      esac
    done < "$tmp/records.jsonl"
    case "$status" in
      4) echo "graph.sh: reconcile: board changed since the plan; stopped applying, re-run reconcile" >&2 ;;
      75) echo "graph.sh: reconcile: the backend is busy (lock not acquired); stopped applying, retry" >&2 ;;
      1) echo "graph.sh: reconcile: stopped applying after a failed record; fix it, then re-run reconcile" >&2 ;;
    esac
    exit "$status" ;;
esac
