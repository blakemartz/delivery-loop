#!/usr/bin/env bash
# graph-github.sh <primitive> [args] — the github graph backend (GitHub Issues
# via `gh`), behind graph.sh (docs/delivery_graph_spec.md §6.1, §6.2).
#
# Read primitives (task B1; externals and closed-by-PR evidence, task B2):
#   list        every issue (open and closed) that is a delivery node, plus every
#               unlabelled issue the graph references (a dep target or an epic
#               child) as an `external` node (§4.1, §6.2), as one JSON array.
#   show <id>   one delivery node (the issue number), as one JSON object.
#   migrate-plan
#               the native edges `graph.sh migrate` adds (task B3, §6.2): one
#               JSON array of {id, links, parent, blockers, warnings}, one entry
#               per open task with legacy `Depends-on:` / `Part of epic #E` text
#               not yet native (gh_migrate_plan). Needs native relations.
#
# Write primitives (task B2; ids are issue numbers):
#   create <node-json>|-          `gh issue create` with the kind/status/module/
#                                 size/needs-human labels, native `--parent` and
#                                 `--blocked-by`, and the `Delivery-Target:` /
#                                 `Delivery-Plan:` / `Delivery-Promote-To:` body
#                                 lines (the last on promote nodes only); a dep
#                                 with a `via` also gets its `Depends-on: #<dep>
#                                 (via: …)` line. Prints the new issue number.
#                                 Never creates an `external` node, and refuses
#                                 an `id` (GitHub numbers issues).
#   update <id> <patch-json>|- [--actor <name>]
#                                 title, body, status, needs_human, module, size.
#                                 Open statuses are label edits; done/cancelled
#                                 close the issue `completed` / `not planned`. A
#                                 closed issue takes only title/body (reopening
#                                 is a human's call). Any other key is refused.
#                                 With --actor (graph.sh transition --human), a
#                                 status change is recorded as the comment
#                                 `TRANSITIONED: <from> -> <to> by <name>
#                                 (graph.sh transition).` (in the close call when
#                                 it closes).
#   link <id> <dep-id> [via]      `gh issue edit --add-blocked-by`; a via (or a
#                                 gh without native relations) is recorded as a
#                                 `Depends-on: #<dep> (via: …)` body line.
#                                 Idempotent.
#   parent <id> <epic-id>         `gh issue edit --parent` (task B3). Idempotent;
#                                 refuses an issue that already has a different
#                                 parent (re-parenting is a human's call) and a
#                                 gh without native relations.
#   flag <id> needs-human on|off  the `needs-human` label. Idempotent.
#   claim <id> <actor> <run> [agent|human]
#                                 agent: v0.1.4's comment-ordered Lamport lock,
#                                 verbatim (pre-check, `CLAIM <actor> <run>
#                                 <ts>`, lib/claim-winner.jq arbitration, the
#                                 lib/orphan-claims.jq reap, the post-edit
#                                 sanity check), with v0.1.4's gh calls and
#                                 stderr. human: the same pre-check, then the
#                                 assignee + status:claimed (no CLAIM comment:
#                                 humans never post one). Exit 1 = lost or not
#                                 claimable.
#   release <id> <reason>         clears the claim: removes the claimant
#                                 (an agent claim: every assignee) and
#                                 `claim:agent`, moves status:claimed to
#                                 status:ready (any other status and needs-human
#                                 are kept), then voids the ledger: `CLAIM-
#                                 WITHDRAWN <actor> <run> (released: <reason>)`
#                                 for an agent claim with a run, else
#                                 `RELEASED: <reason>`. No claim: a no-op.
#   comment <id> <text>|-         an issue comment.
#   reconcile <record-json>|-     apply one reconcile fix record {op, id, from,
#                                 to, reason, updated_at[, pr]} (lib/reconcile.jq,
#                                 §5) as a compare-and-set: the issue is re-read
#                                 and must still have status `from` and the
#                                 `updatedAt` the plan saw (and, for reclaim, an
#                                 agent claim; for ping, an unpinged human
#                                 claim), else exit 4, nothing written. This is
#                                 the re-check that closes v0.1.4's plan->apply
#                                 race (a claim refreshed after the plan is
#                                 never reclaimed).
#                                 transition to an open status: label edit.
#                                 transition to done: `gh issue close --reason
#                                 completed`, then the comment `AUTO-CLOSE:
#                                 <reason>. (Reconciled by graph.sh reconcile
#                                 --fix.)`. On a task/promote node that is rule
#                                 3, whose reason must read `PR #<n> merged into
#                                 <base>` (or the record carries `pr`), so the
#                                 comment is the `AUTO-CLOSE: PR #<n> merged into
#                                 <base>` marker applied_prs reads (GC42, GC72).
#                                 reclaim: v0.1.4's release (assignees,
#                                 status:ready, claim:agent off) in one edit,
#                                 then the RECLAIMED comment (the reason,
#                                 verbatim). ping: the STALE-CLAIM-PING comment.
#
# It stores; it does not decide (§3 rule 1): normalization lives in
# backends/graph-github.jq, and graph.sh validates the output (validate_node) and
# applies lib/*.jq. Invoke it through graph.sh, which resolves the config and runs
# the `--check` validation first; this file only reads the exported keys
# (LIST_LIMIT, BASE_BRANCH, FORGE_URL, FORGE_REPO, CLAIM_GRACE_SECONDS).
#
# Exit codes: 0 ok · 1 failed (claim: lost or not claimable) · 2 usage · 3 the
# list reached LIST_LIMIT (never a silent truncation, GC10) · 4 reconcile: stale
# record (the issue changed since the plan; nothing written).
#
# Notes (§6.2):
#   - one `gh issue list --state all` with an explicit `--limit $LIST_LIMIT`;
#     gh pages internally. A result count equal to LIST_LIMIT exits 3.
#   - native relations (`blockedBy`, `parent`, and `closedByPullRequestsReferences`)
#     need gh >= 2.94.0. On an older gh the fields are not requested, only
#     `Depends-on:` text edges are read (and written), and one warning is printed
#     per invocation (GC56).
#   - a `blockedBy` connection whose `totalCount` exceeds its returned `nodes`
#     is re-read with `gh issue view <n> --json blockedBy` (GC64).
#   - `gh issue list` returns at most an issue's first 100 comments, with no
#     total; an issue with 100 is re-read with `gh issue view <n> --json comments`
#     (complete), so `applied_prs`, `pinged_at` and the claim never truncate (GC74).
#     One `gh issue view` per short issue fetches every short field at once. Only
#     delivery issues are re-read: an external's fields are fixed.
#   - GC75: an OPEN delivery issue with a closing PR reference may have been
#     closed by a PR's closing keyword and reopened. For each such issue the
#     backend reads its timeline's `ClosedEvent.closer` (`gh api graphql`) and adds
#     every closing PR of this repo to `applied_prs` (graph-github.jq header:
#     the source was verified against live reopened issues).
#   - every write reads the issue fresh (`gh issue view`, all comments) first.
#   - crash window (rule 3): the close and its AUTO-CLOSE marker are two calls,
#     close first. A close whose marker was never posted leaves the issue closed
#     with no marker; if a human then reopens it, the next reconcile closes it
#     once more (and posts the marker). The opposite order would leave a marker
#     on an open issue, which would block rule 3 for that PR forever.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib"

: "${LIST_LIMIT:=5000}"
: "${BASE_BRANCH:=main}"
: "${FORGE_URL:=}"
: "${FORGE_REPO:=}"

# FORGE_URL / FORGE_REPO override what gh derives from `origin`, as in
# forge-github.sh: issues and PRs share one host (§3 rule 5).
if [ -n "$FORGE_URL" ]; then
  _host="${FORGE_URL#*://}"; _host="${_host%%/*}"
  [ -n "$_host" ] && export GH_HOST="$_host"
fi
if [ -n "$FORGE_REPO" ]; then
  export GH_REPO="${GH_HOST:+$GH_HOST/}$FORGE_REPO"
fi

BASE_FIELDS="number,title,state,stateReason,labels,assignees,body,createdAt,updatedAt,comments"
REL_FIELDS="blockedBy,parent,closedByPullRequestsReferences"
MIN_GH="2.94.0"

# The timeline query behind GC75 (`{owner}`/`{repo}` are gh placeholders).
CLOSERS_QUERY='query($owner: String!, $name: String!, $n: Int!) {
  repository(owner: $owner, name: $name) {
    nameWithOwner
    issue(number: $n) {
      timelineItems(itemTypes: [CLOSED_EVENT], last: 100) {
        nodes { ... on ClosedEvent { closer { __typename ... on PullRequest { number repository { nameWithOwner } } } } }
      }
    }
  }
}'

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-github.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

die()   { echo "graph-github: $*" >&2; exit 1; }
usage() { echo "graph-github: usage: $*" >&2; exit 2; }
gjq()   { jq -L "$LIB" -L "$SCRIPT_DIR" "$@"; }
need_n() { case "${1:-}" in ''|*[!0-9]*|0*) usage "$2 (github ids are issue numbers)" ;; esac; }

case "$LIST_LIMIT" in
  ''|*[!0-9]*|0) die "LIST_LIMIT must be a positive integer (got '$LIST_LIMIT')" ;;
esac

# native: 1 when the installed gh supports `blockedBy`/`parent` (>= MIN_GH), else
# 0 with the one warning. An unparseable version is assumed current.
native=1
_ver=$(gh --version 2>/dev/null | sed -n '1s/^gh version \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' || true)
if [ -n "$_ver" ]; then
  _maj=${_ver%%.*}; _rest=${_ver#*.}; _min=${_rest%%.*}
  if [ "$_maj" -lt 2 ] || { [ "$_maj" -eq 2 ] && [ "$_min" -lt 94 ]; }; then
    native=0
    echo "graph-github: warning: gh < $MIN_GH: native relations ignored (gh $_ver; Depends-on: text edges only)" >&2
  fi
fi
if [ "$native" = 1 ]; then FIELDS="$BASE_FIELDS,$REL_FIELDS"; else FIELDS="$BASE_FIELDS"; fi

# --- reads ------------------------------------------------------------------------

# warn_short <issues-file>: name every issue whose blockedBy is still short.
warn_short() {
  gjq -r 'include "graph-github"; .[] | select(gh_short_blocked)
          | "graph-github: warning: #\(.number) blockedBy has \(.blockedBy.nodes | length) of \(.blockedBy.totalCount) nodes after re-read; deps may be incomplete"' \
    "$1" >&2
}

# add_closers <issues-file>: GC75. Patch `_closed_by_prs` (the PRs whose closing
# keyword closed the issue, from its timeline) into every open delivery issue
# that has a closing PR reference.
add_closers() {
  [ "$native" = 1 ] || return 0
  local n
  echo '{}' > "$tmp/closers.json"
  for n in $(gjq -r 'include "graph-github"; .[] | select(gh_needs_closers) | .number' "$1"); do
    gh api graphql -F owner='{owner}' -F name='{repo}' -F n="$n" -f query="$CLOSERS_QUERY" \
      > "$tmp/timeline.json" || die "gh api graphql (issue #$n timeline) failed"
    gjq --arg n "$n" --slurpfile t "$tmp/timeline.json" 'include "graph-github";
        .[$n] = ($t[0] | gh_timeline_closers($t[0].data.repository.nameWithOwner // ""))' \
      "$tmp/closers.json" > "$tmp/closers.next" && mv "$tmp/closers.next" "$tmp/closers.json"
  done
  jq --slurpfile c "$tmp/closers.json" \
    'map(if $c[0][.number | tostring] != null then ._closed_by_prs = $c[0][.number | tostring] else . end)' \
    "$1" > "$1.next" && mv "$1.next" "$1"
}

# read_all: every issue (complete blockedBy and comments, GC64/GC74) in
# $tmp/issues.json, or exit 3 at LIST_LIMIT (GC10).
read_all() {
  gh issue list --state all --json "$FIELDS" --limit "$LIST_LIMIT" > "$tmp/issues.json" \
    || die "gh issue list failed"
  local got
  got=$(jq 'length' "$tmp/issues.json")
  if [ "$got" -ge "$LIST_LIMIT" ]; then
    echo "graph-github: gh issue list returned $got issues = LIST_LIMIT ($LIST_LIMIT); refusing to truncate (raise LIST_LIMIT)" >&2
    exit 3
  fi
  # GC64 / GC74: re-read each issue with a short blockedBy connection or a
  # possibly-truncated comment list, then patch the complete fields in.
  gjq -r 'include "graph-github"; .[] | gh_reread_fields as $f
          | select($f != "") | "\(.number) \($f)"' "$tmp/issues.json" > "$tmp/reread.txt"
  echo '{}' > "$tmp/patch.json"
  local n fields
  while read -r n fields; do
    [ -n "$n" ] || continue
    gh issue view "$n" --json "$fields" > "$tmp/view.json" \
      || die "gh issue view $n --json $fields failed"
    jq --arg n "$n" --slurpfile v "$tmp/view.json" '.[$n] = $v[0]' \
      "$tmp/patch.json" > "$tmp/patch.next" && mv "$tmp/patch.next" "$tmp/patch.json"
  done < "$tmp/reread.txt"
  jq --slurpfile p "$tmp/patch.json" \
    'map(. + ($p[0][.number | tostring] // {}))' \
    "$tmp/issues.json" > "$tmp/issues.next" && mv "$tmp/issues.next" "$tmp/issues.json"
  [ "$native" = 0 ] || warn_short "$tmp/issues.json"
}

op_list() {
  [ $# -eq 0 ] || usage "list"
  read_all
  add_closers "$tmp/issues.json"
  gjq -c --arg base "$BASE_BRANCH" 'include "graph-github"; gh_nodes($base)' "$tmp/issues.json"
}

# migrate-plan: the native edges each open task lacks (gh_migrate_plan, §6.2,
# GC48), as one JSON array. Native relations are the point, so an older gh is
# refused rather than planned against.
op_migrate_plan() {
  [ $# -eq 0 ] || usage "migrate-plan"
  [ "$native" = 1 ] || die "migrate-plan: needs gh >= $MIN_GH (native relations)"
  read_all
  gjq -c 'include "graph-github"; gh_migrate_plan' "$tmp/issues.json"
}

# read_issue <n>: the raw issue (every comment, the complete blockedBy, the
# GC75 closers) in $tmp/issue.json.
read_issue() {
  gh issue view "$1" --json "$FIELDS" > "$tmp/issue.json" || die "gh issue view $1 failed"
  jq '[.]' "$tmp/issue.json" > "$tmp/issues.json"
  [ "$native" = 0 ] || warn_short "$tmp/issues.json"
  add_closers "$tmp/issues.json"
  jq '.[0]' "$tmp/issues.json" > "$tmp/issue.json"
}

# node_of_issue <n>: the delivery node of $tmp/issue.json (already read), or exit 1.
node_of_issue() {
  gjq -c --arg base "$BASE_BRANCH" --arg id "$1" 'include "graph-github";
      [.] | gh_nodes($base) | first
      // error("issue #\($id) is not a delivery node (no task/epic/promote label)")' \
    "$tmp/issue.json" 2> "$tmp/err" || { sed 's/^jq: error (at [^)]*): //' "$tmp/err" >&2; exit 1; }
}

op_show() {
  [ $# -eq 1 ] || usage "show <id>"
  need_n "$1" "show <id>"
  read_issue "$1"
  node_of_issue "$1"
}

# --- writes -----------------------------------------------------------------------

# read_node <n>: read issue n fresh; its node JSON goes to $tmp/node.json.
read_node() {
  read_issue "$1"
  node_of_issue "$1" > "$tmp/node.json"
}

# nget <jq>: a raw field of the node read by read_node.
nget() { jq -r "$1" "$tmp/node.json"; }

# one_object <what> <json>: refuse anything but exactly one JSON object.
one_object() {
  [ "$(jq -cs 'length == 1 and (.[0] | type) == "object"' <<<"$2" 2>/dev/null)" = true ] \
    || die "$1 must be exactly one JSON object (nothing written)"
}

# label_args <patch-json>: the `gh issue edit` label flags for a patch, one
# flag/value per line, into $tmp/label.args (empty when nothing changes).
label_args() {
  gjq -r --argjson p "$1" 'include "graph-github"; gh_label_plan($p)
     | (.add[] | "--add-label\n\(.)"), (.remove[] | "--remove-label\n\(.)")' \
    "$tmp/issue.json" > "$tmp/label.args"
}

# edit <n> <args-file>: one `gh issue edit` with the flags in args-file (one per
# line); none -> no call.
edit() {
  [ -s "$2" ] || return 0
  local a=() l
  while IFS= read -r l; do a+=("$l"); done < "$2"
  gh issue edit "$1" "${a[@]}" > /dev/null || die "gh issue edit #$1 failed"
}

# comment_file <n> <text>: post an issue comment from a file (any text).
comment_file() {
  printf '%s' "$2" > "$tmp/comment.md"
  gh issue comment "$1" --body-file "$tmp/comment.md" > /dev/null || die "gh issue comment #$1 failed"
}

# close_issue <n> <reason> [comment]: close, with the comment in the same call.
close_issue() {
  if [ $# -ge 3 ]; then
    gh issue close "$1" --reason "$2" --comment "$3" > /dev/null || die "gh issue close #$1 failed"
  else
    gh issue close "$1" --reason "$2" > /dev/null || die "gh issue close #$1 failed"
  fi
}

op_create() {
  [ $# -eq 1 ] || usage "create <node-json>|-"
  local in="$1"
  [ "$in" != - ] || in=$(cat)
  one_object "create: node-json" "$in"
  printf '%s' "$in" > "$tmp/in.json"
  gjq -e --arg base "$BASE_BRANCH" '
    def str: type == "string" and length > 0;
    def allowed: ["kind", "title", "body", "epic", "deps", "module", "size", "status",
                  "needs_human", "target_branch", "promote_to", "plan_ref"];
    if has("id") then error("create: github assigns issue numbers; drop `id`")
    elif ((keys - allowed) | length) > 0 then
      error("create: unsupported field(s) \((keys - allowed) | join(", ")) (github create takes \(allowed | join(", ")))")
    elif (.kind as $k | ["task", "epic", "promote"] | index($k)) == null then
      error("create: kind must be task|epic|promote (never external) (got \(.kind | tojson))")
    elif (.title | str | not) or (.title | test("[\r\n]")) then error("create: title must be a non-empty one-line string")
    elif .body != null and (.body | type) != "string" then error("create: body must be a string")
    elif (.status // "ready" | . as $s | ["ready", "blocked"] | index($s)) == null then
      error("create: status must be ready or blocked (got \(.status | tojson))")
    elif .epic != null and ((.epic | tostring) | test("^[1-9][0-9]*$") | not) then
      error("create: epic must be an issue number (got \(.epic | tojson))")
    elif any((.deps // [])[]; (if type == "object" then .id else . end | tostring | test("^[1-9][0-9]*$")) | not) then
      error("create: every dep must be an issue number")
    elif .module != null and ((.module | str | not) or (.module | startswith("module:"))) then
      error("create: module must be a bare module name or null")
    elif (.size as $s | ["S", "M", "L", null] | index($s)) == null then error("create: size must be S|M|L or null")
    elif .promote_to != null and .kind != "promote" then error("create: promote_to is for promote nodes only")
    elif .plan_ref != null and ((.plan_ref | type) != "string" or (.plan_ref | test("^[^/]+/[^/]+$") | not)) then
      error("create: plan_ref must be <plan>/<plan-task-id>")
    elif .target_branch != null and (.target_branch | str | not) then error("create: target_branch must be a non-empty string")
    else true end' "$tmp/in.json" > /dev/null 2> "$tmp/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$tmp/err" >&2; die "create: invalid node (nothing written)"; }
  # Body: the contract, then the trailer lines it does not already carry.
  jq -r --argjson native "$native" '
    def lines: (.body // "") | split("\n") | map(rtrimstr("\r"));
    def has_key($k): any(lines[]; test("^" + $k + ":"));
    ((.deps // []) | map(if type == "object" then {id: (.id | tostring), via: .via} else {id: tostring, via: null} end)) as $deps
    | [ (if .target_branch != null and (has_key("Delivery-Target") | not) then "Delivery-Target: \(.target_branch)" else empty end),
        (if .plan_ref != null and (has_key("Delivery-Plan") | not) then "Delivery-Plan: \(.plan_ref)" else empty end),
        (if .kind == "promote" and .promote_to != null and (has_key("Delivery-Promote-To") | not)
         then "Delivery-Promote-To: \(.promote_to)" else empty end),
        (if $native == 0 and .epic != null then "Part of epic #\(.epic)" else empty end),
        ($deps[] | select($native == 0 or .via != null)
         | "Depends-on: #\(.id)\(if .via != null then " (via: \(.via))" else "" end)") ] as $extra
    | ((.body // "") | rtrimstr("\n")) as $b
    | if $extra == [] then $b
      elif $b == "" then $extra | join("\n")
      else $b + "\n\n" + ($extra | join("\n")) end' "$tmp/in.json" > "$tmp/body.md"
  jq -r --argjson native "$native" '
    "--title", .title, "--body-file", $ARGS.named.body,
    "--label", .kind, "--label", "status:\(.status // "ready")",
    (if .module != null then "--label", "module:\(.module)" else empty end),
    (if .size != null then "--label", "size:\(.size)" else empty end),
    (if .needs_human == true then "--label", "needs-human" else empty end),
    (if $native == 1 and .epic != null then "--parent", (.epic | tostring) else empty end),
    (if $native == 1 then ((.deps // [])[] | "--blocked-by", (if type == "object" then .id else . end | tostring)) else empty end)' \
    --arg body "$tmp/body.md" "$tmp/in.json" > "$tmp/create.args"
  local a=() l url
  while IFS= read -r l; do a+=("$l"); done < "$tmp/create.args"
  url=$(gh issue create "${a[@]}") || die "gh issue create failed"
  url=$(printf '%s\n' "$url" | grep -E '/issues/[0-9]+' | tail -n 1) \
    || die "gh issue create printed no issue URL (the issue may exist: look it up by title/plan_ref before retrying)"
  printf '%s\n' "$url" | sed 's#.*/issues/\([0-9][0-9]*\).*#\1#'
}

op_update() {
  local who=""
  if [ $# -eq 4 ] && [ "$3" = --actor ] && [ -n "$4" ]; then who="$4"; set -- "$1" "$2"; fi
  [ $# -eq 2 ] || usage "update <id> <patch-json>|- [--actor <name>]"
  need_n "$1" "update <id> <patch-json>"
  local n="$1" p="$2"
  [ "$p" != - ] || p=$(cat)
  one_object "update: patch-json" "$p"
  jq -e '
    def allowed: ["title", "body", "status", "needs_human", "module", "size"];
    if ((keys - allowed) | length) > 0 then
      error("update: cannot patch \((keys - allowed) | join(", ")) on github (patchable: \(allowed | join(", ")); claims go through claim/release, edges through link)")
    elif has("title") and ((.title | type) != "string" or .title == "" or (.title | test("[\r\n]"))) then
      error("update: title must be a non-empty one-line string")
    elif has("body") and (.body | type) != "string" then error("update: body must be a string")
    elif has("status") and (.status as $s | ["blocked", "ready", "claimed", "in-review", "changes-requested", "approved", "done", "cancelled"] | index($s)) == null then
      error("update: unknown status \(.status | tojson)")
    elif has("needs_human") and (.needs_human | type) != "boolean" then error("update: needs_human must be a boolean")
    elif has("module") and .module != null and ((.module | type) != "string" or .module == "" or (.module | startswith("module:"))) then
      error("update: module must be a bare module name or null")
    elif has("size") and (.size as $s | ["S", "M", "L", null] | index($s)) == null then error("update: size must be S|M|L or null")
    else true end' <<<"$p" > /dev/null 2> "$tmp/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$tmp/err" >&2; die "update: invalid patch (nothing written)"; }
  read_node "$n"
  local cur to closed=false close_reason=""
  cur=$(nget .status)
  to=$(jq -r '.status // empty' <<<"$p")
  case "$cur" in done|cancelled) closed=true ;; esac
  if [ "$closed" = true ] && [ "$(jq -c 'del(.title, .body) | keys' <<<"$p")" != '[]' ]; then
    die "update: #$n is closed ($cur); only title/body can change (reopening is a human's call; nothing written)"
  fi
  # Label side of the patch (status only while it stays open).
  jq -c --arg cur "$cur" '{} + (if has("status") and .status != "done" and .status != "cancelled" and .status != $cur
                                then {status} else {} end)
                           + (if has("module") then {module} else {} end)
                           + (if has("size") then {size} else {} end)
                           + (if has("needs_human") then {needs_human} else {} end)' <<<"$p" > "$tmp/lp.json"
  label_args "$(cat "$tmp/lp.json")"
  if jq -e 'has("title")' <<<"$p" > /dev/null; then
    printf -- '--title\n%s\n' "$(jq -r .title <<<"$p")" >> "$tmp/label.args"
  fi
  if jq -e 'has("body")' <<<"$p" > /dev/null; then
    jq -j .body <<<"$p" > "$tmp/newbody.md"
    printf -- '--body-file\n%s\n' "$tmp/newbody.md" >> "$tmp/label.args"
  fi
  case "$to" in
    done) [ "$cur" = done ] || close_reason=completed ;;
    cancelled) [ "$cur" = cancelled ] || close_reason="not planned" ;;
  esac
  if [ "$closed" = true ] && [ -n "$close_reason" ]; then
    die "update: #$n is already closed ($cur); it cannot move to $to (nothing written)"
  fi
  # A named actor (graph.sh transition --human <name>) is recorded on a status
  # change: in the close call itself, else as a comment after the label edit.
  local note=""
  if [ -n "$who" ] && [ -n "$to" ] && [ "$to" != "$cur" ]; then
    note="TRANSITIONED: $cur -> $to by $who (graph.sh transition)."
  fi
  edit "$n" "$tmp/label.args"
  if [ -n "$close_reason" ]; then
    if [ -n "$note" ]; then close_issue "$n" "$close_reason" "$note"; else close_issue "$n" "$close_reason"; fi
  elif [ -n "$note" ]; then
    comment_file "$n" "$note"
  fi
}

op_link() {
  [ $# -eq 2 ] || [ $# -eq 3 ] || usage "link <id> <dep-id> [via]"
  need_n "$1" "link <id> <dep-id> [via]"
  need_n "$2" "link <id> <dep-id> [via]"
  [ "$1" != "$2" ] || die "link: an issue cannot block itself (#$1)"
  local n="$1" dep="$2" via=null
  [ $# -lt 3 ] || via=$(jq -cn --arg v "$3" '$v')
  [ "$via" = null ] || [ "$3" != "" ] || die "link: an empty via (omit it for a legacy edge)"
  read_node "$n"
  : > "$tmp/link.args"
  if [ "$native" = 1 ] && ! jq -e --arg d "$dep" 'any((.blockedBy.nodes // [])[]; (.number | tostring) == $d)' "$tmp/issue.json" > /dev/null; then
    printf -- '--add-blocked-by\n%s\n' "$dep" >> "$tmp/link.args"
  fi
  if [ "$via" != null ] || [ "$native" = 0 ]; then
    if ! gjq -e --arg d "$dep" --argjson v "$via" 'include "graph-github"; gh_has_text_edge($d; $v)' "$tmp/issue.json" > /dev/null; then
      gjq -j --arg d "$dep" --argjson v "$via" 'include "graph-github"; gh_link_body($d; $v)' "$tmp/issue.json" > "$tmp/linkbody.md"
      printf -- '--body-file\n%s\n' "$tmp/linkbody.md" >> "$tmp/link.args"
    fi
  fi
  edit "$n" "$tmp/link.args"
}

op_parent() {
  [ $# -eq 2 ] || usage "parent <id> <epic-id>"
  need_n "$1" "parent <id> <epic-id>"
  need_n "$2" "parent <id> <epic-id>"
  [ "$1" != "$2" ] || die "parent: an issue cannot be its own parent (#$1)"
  [ "$native" = 1 ] || die "parent: needs gh >= $MIN_GH (native relations; nothing written)"
  local n="$1" epic="$2" cur
  read_node "$n"
  cur=$(jq -r '.parent.number // empty' "$tmp/issue.json")
  [ "$cur" != "$epic" ] || return 0
  [ -z "$cur" ] || die "parent: #$n already has parent #$cur (not #$epic; nothing written)"
  printf -- '--parent\n%s\n' "$epic" > "$tmp/parent.args"
  edit "$n" "$tmp/parent.args"
}

op_flag() {
  [ $# -eq 3 ] && [ "$2" = needs-human ] || usage "flag <id> needs-human on|off"
  need_n "$1" "flag <id> needs-human on|off"
  local on
  case "$3" in on) on=true ;; off) on=false ;; *) usage "flag <id> needs-human on|off" ;; esac
  read_node "$1"
  label_args "{\"needs_human\": $on}"
  edit "$1" "$tmp/label.args"
}

# claim_agent <n> <actor> <run>: v0.1.4's claim-task.sh protocol, verbatim
# (docs/agentic_delivery_spec.md §7.2): the same gh calls, comments and stderr.
claim_agent() {
  local N="$1" ACTOR="$2" RUN_ID="$3"
  local info state n_assignees is_ready winner grace cutoff snapshot unconverted orphans key n_after me
  info=$(gh issue view "$N" --json state,assignees,labels)
  state=$(jq -r '.state' <<<"$info")
  n_assignees=$(jq '.assignees | length' <<<"$info")
  is_ready=$(jq '[.labels[].name] | index("status:ready") != null' <<<"$info")

  [ "$state" = "OPEN" ]    || { echo "not claimable: #$N is $state" >&2; exit 1; }
  [ "$n_assignees" = "0" ] || { echo "not claimable: #$N already has an assignee" >&2; exit 1; }
  [ "$is_ready" = "true" ] || { echo "not claimable: #$N is not status:ready" >&2; exit 1; }

  gh issue comment "$N" --body "CLAIM $ACTOR $RUN_ID $(date -u +%FT%TZ)" >/dev/null

  winner=$(arbitrate "$N")

  # Lost, maybe to an ORPHAN: a CLAIM whose claimant died before converting it
  # to status:claimed (the issue is STILL status:ready with zero assignees past
  # the grace window). Reap every such orphan via CLAIM-WITHDRAWN and re-arbitrate.
  if [[ "$winner" != "CLAIM $ACTOR $RUN_ID"* ]]; then
    grace=${CLAIM_GRACE_SECONDS:-90}
    cutoff=$(( $(date +%s) - grace ))
    snapshot=$(gh issue view "$N" --json assignees,labels,comments)
    unconverted=$(jq -r \
      '(.assignees | length == 0) and ([.labels[].name] | index("status:ready") != null)' \
      <<<"$snapshot")
    if [ "$unconverted" = "true" ]; then
      orphans=$(jq -r -L "$LIB" --argjson cutoffEpoch "$cutoff" \
        -f "$LIB/orphan-claims.jq" <<<"$snapshot")
      if [ -n "$orphans" ]; then
        while IFS= read -r key; do
          [ -n "$key" ] || continue
          gh issue comment "$N" --body \
            "CLAIM-WITHDRAWN $key (orphaned: claim never converted to status:claimed within ${grace}s; reaped by $ACTOR $RUN_ID)" >/dev/null
          echo "reaped orphan claim on #$N: $key" >&2
        done <<<"$orphans"
        winner=$(arbitrate "$N")
      fi
    fi
  fi

  if [[ "$winner" != "CLAIM $ACTOR $RUN_ID"* ]]; then
    gh issue comment "$N" --body "CLAIM-WITHDRAWN $ACTOR $RUN_ID (lost to earlier claim)" >/dev/null
    echo "lost claim race for #$N (winner: $winner)" >&2
    exit 1
  fi

  gh issue edit "$N" --add-assignee "@me" \
    --add-label "status:claimed" --add-label "claim:agent" \
    --remove-label "status:ready" >/dev/null

  # Post-edit sanity: a human may have self-assigned between pre-check and edit.
  n_after=$(gh issue view "$N" --json assignees --jq '.assignees | length')
  if [ "$n_after" != "1" ]; then
    me=$(gh api user --jq .login)
    gh issue edit "$N" --remove-assignee "$me" \
      --remove-label "status:claimed" --remove-label "claim:agent" >/dev/null
    gh issue comment "$N" --body "CLAIM-WITHDRAWN $ACTOR $RUN_ID (another assignee appeared — yielding)" >/dev/null
    echo "withdrew claim on #$N: another assignee appeared" >&2
    exit 1
  fi
}

# Earliest *live* CLAIM comment wins (lib/claim-winner.jq, unchanged).
arbitrate() {
  gh issue view "$1" --json comments \
    | jq -r -L "$LIB" -f "$LIB/claim-winner.jq"
}

# claim_human <n> <login>: v0.1.4's pre-check, then assign the human. Humans
# post no CLAIM comment (their claim is the assignee, §4.1).
claim_human() {
  local N="$1" WHO="$2" info state n_assignees is_ready n_after
  info=$(gh issue view "$N" --json state,assignees,labels)
  state=$(jq -r '.state' <<<"$info")
  n_assignees=$(jq '.assignees | length' <<<"$info")
  is_ready=$(jq '[.labels[].name] | index("status:ready") != null' <<<"$info")
  [ "$state" = "OPEN" ]    || { echo "not claimable: #$N is $state" >&2; exit 1; }
  [ "$n_assignees" = "0" ] || { echo "not claimable: #$N already has an assignee" >&2; exit 1; }
  [ "$is_ready" = "true" ] || { echo "not claimable: #$N is not status:ready" >&2; exit 1; }
  gh issue edit "$N" --add-assignee "$WHO" \
    --add-label "status:claimed" --remove-label "status:ready" >/dev/null
  n_after=$(gh issue view "$N" --json assignees --jq '.assignees | length')
  if [ "$n_after" != "1" ]; then
    gh issue edit "$N" --remove-assignee "$WHO" \
      --add-label "status:ready" --remove-label "status:claimed" >/dev/null
    echo "withdrew claim on #$N: another assignee appeared" >&2
    exit 1
  fi
}

op_claim() {
  [ $# -eq 3 ] || [ $# -eq 4 ] || usage "claim <id> <actor> <run> [agent|human]"
  need_n "$1" "claim <id> <actor> <run> [agent|human]"
  local by="${4:-agent}"
  [ -n "$2" ] || usage "claim <id> <actor> <run> [agent|human]: empty actor"
  case "$by" in
    agent) [ -n "$3" ] && [ "$3" != - ] || usage "claim <id> <actor> <run>: an agent claim needs a run"
           claim_agent "$1" "$2" "$3" ;;
    human) claim_human "$1" "$2" ;;
    *) usage "claim <id> <actor> <run> [agent|human]" ;;
  esac
}

op_release() {
  [ $# -eq 2 ] || usage "release <id> <reason>"
  need_n "$1" "release <id> <reason>"
  [ -n "$2" ] || usage "release <id> <reason>: empty reason"
  local n="$1" reason="$2" by note
  read_node "$n"
  ! jq -e '.claim == null and .status != "claimed"' "$tmp/node.json" > /dev/null || return 0
  by=$(nget '.claim.by // ""')
  jq -c '{claim_agent: false} + (if .status == "claimed" then {status: "ready"} else {} end)' \
    "$tmp/node.json" > "$tmp/lp.json"
  label_args "$(cat "$tmp/lp.json")"
  # The claimant: every assignee for an agent claim (as v0.1.4's reaper), the
  # claiming human otherwise.
  jq -r --arg by "$by" --slurpfile node "$tmp/node.json" '
    (if $by == "human" then [$node[0].claim.actor] else [(.assignees // [])[].login] end)[]
    | "--remove-assignee", .' "$tmp/issue.json" >> "$tmp/label.args"
  edit "$n" "$tmp/label.args"
  if [ "$by" = agent ] && [ "$(nget '.claim.run // ""')" != "" ]; then
    note="CLAIM-WITHDRAWN $(nget .claim.actor) $(nget .claim.run) (released: $reason)"
  else
    note="RELEASED: $reason"
  fi
  comment_file "$n" "$note"
}

op_comment() {
  [ $# -eq 2 ] || usage "comment <id> <text>|-"
  need_n "$1" "comment <id> <text>"
  local text="$2"
  [ "$text" != - ] || text=$(cat)
  [ -n "$text" ] || usage "comment <id> <text>: empty text"
  comment_file "$1" "$text"
}

op_reconcile() {
  [ $# -eq 1 ] || usage "reconcile <record-json>|-"
  local rec="$1"
  [ "$rec" != - ] || rec=$(cat)
  one_object "reconcile: record-json" "$rec"
  printf '%s' "$rec" > "$tmp/rec.json"
  jq -e '
    def str: type == "string" and length > 0;
    def fields: ["op", "id", "from", "to", "reason", "updated_at", "pr"];
    if ((keys - fields) | length) > 0 then error("record: unexpected field(s) \((keys - fields) | join(", "))")
    elif ([.op, .id, .from, .to, .reason, .updated_at] | all(str) | not) then
      error("record: op, id, from, to, reason and updated_at must be non-empty strings")
    elif (.op as $op | ["transition", "reclaim", "ping"] | index($op)) == null then
      error("record: unknown op \(.op | tojson) (transition|reclaim|ping)")
    elif .op == "ping" and .from != .to then error("record: a ping moves nothing (from must equal to)")
    elif .op == "reclaim" and .to != "ready" then error("record: a reclaim moves to ready")
    elif has("pr") and ((.pr | type) != "number" or .pr < 1 or .pr != (.pr | floor)) then error("record: pr must be a positive integer")
    elif (.id | test("^[1-9][0-9]*$") | not) then error("record: github ids are issue numbers (got \(.id | tojson))")
    else true end' "$tmp/rec.json" > /dev/null 2> "$tmp/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$tmp/err" >&2; die "reconcile: invalid record (nothing written)"; }
  local n op from to reason
  n=$(jq -r .id "$tmp/rec.json"); op=$(jq -r .op "$tmp/rec.json")
  from=$(jq -r .from "$tmp/rec.json"); to=$(jq -r .to "$tmp/rec.json")
  reason=$(jq -r .reason "$tmp/rec.json")
  read_node "$n"
  # Compare-and-set: the issue is as the plan saw it (status and updatedAt; any
  # comment, label or assignee edit since bumps updatedAt), and the record's op
  # still fits its claim.
  if ! jq -e --slurpfile r "$tmp/rec.json" '$r[0] as $r
       | .status == $r.from and .updated_at == $r.updated_at
         and (if $r.op == "reclaim" then (.claim // {}).by == "agent"
              elif $r.op == "ping" then (.claim // {}).by == "human" and .pinged_at == null
              else true end)' "$tmp/node.json" > /dev/null; then
    echo "graph-github: stale record: #$n is no longer $from at $(jq -r .updated_at "$tmp/rec.json") with the claim the plan saw (now $(nget '"\(.status) at \(.updated_at)"')); nothing written" >&2
    exit 4
  fi
  case "$op" in
    ping)
      comment_file "$n" "$reason" ;;
    reclaim)
      jq -c --arg to "$to" '{claim_agent: false, status: $to}' <<<'{}' > "$tmp/lp.json"
      label_args "$(cat "$tmp/lp.json")"
      jq -r '(.assignees // [])[] | "--remove-assignee", .login' "$tmp/issue.json" >> "$tmp/label.args"
      edit "$n" "$tmp/label.args"
      comment_file "$n" "$reason" ;;
    transition)
      case "$to" in
        done)
          local marker
          marker=$(jq -r --slurpfile node "$tmp/node.json" '
            ($node[0].kind == "task" or $node[0].kind == "promote") as $rule3
            | if $rule3 then
                ([.reason | capture("\\APR #(?<n>[1-9][0-9]*) merged into (?<b>[^\n]+)\\z")] | first // null) as $m
                | if $m == null then error("rule 3 record for #\(.id) does not name its PR (reason \(.reason | tojson))")
                  elif has("pr") and .pr != ($m.n | tonumber) then error("record pr \(.pr) disagrees with its reason \(.reason | tojson)")
                  else "AUTO-CLOSE: PR #\($m.n) merged into \($m.b). (Reconciled by graph.sh reconcile --fix.)" end
              else "AUTO-CLOSE: \(.reason). (Reconciled by graph.sh reconcile --fix.)" end' \
            "$tmp/rec.json" 2> "$tmp/err") \
            || { sed 's/^jq: error (at [^)]*): //' "$tmp/err" >&2; die "reconcile: cannot derive the AUTO-CLOSE marker (nothing written)"; }
          close_issue "$n" completed
          printf '%s' "$marker" > "$tmp/comment.md"
          gh issue comment "$n" --body-file "$tmp/comment.md" > /dev/null \
            || die "#$n was closed but its AUTO-CLOSE comment failed: post '$marker' by hand, or a reopen will be re-closed once" ;;
        cancelled)
          close_issue "$n" "not planned" ;;
        *)
          label_args "{\"status\": $(jq -cn --arg s "$to" '$s')}"
          edit "$n" "$tmp/label.args" ;;
      esac ;;
  esac
}

op="${1:-}"
[ $# -eq 0 ] || shift
case "$op" in
  list) op_list "$@" ;;
  show) op_show "$@" ;;
  create) op_create "$@" ;;
  update) op_update "$@" ;;
  link) op_link "$@" ;;
  parent) op_parent "$@" ;;
  migrate-plan) op_migrate_plan "$@" ;;
  flag) op_flag "$@" ;;
  claim) op_claim "$@" ;;
  release) op_release "$@" ;;
  comment) op_comment "$@" ;;
  reconcile) op_reconcile "$@" ;;
  *) usage "graph-github.sh list | show <id> | create <node-json> | update <id> <patch-json> | link <id> <dep-id> [via] | parent <id> <epic-id> | migrate-plan | flag <id> needs-human on|off | claim <id> <actor> <run> [agent|human] | release <id> <reason> | comment <id> <text> | reconcile <record-json> (docs/delivery_graph_spec.md §6.1)" ;;
esac
