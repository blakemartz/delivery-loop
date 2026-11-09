# graph-github.jq — normalize `gh issue list|view --json …` objects onto the §4.1
# node shape (docs/delivery_graph_spec.md §4.1, §6.2).
#
# Pure: no I/O, no clock. Used by backends/graph-github.sh with `-L lib -L backends`.
# It translates storage; it does not decide (§3 rule 1): readiness, ordering and
# legality stay in lib/*.jq, applied by graph.sh.
#
#   gh_kind          — "task" | "epic" | "promote" from the type labels, or null
#                      for an issue that is not a delivery node (no type label).
#   gh_node($base)   — one issue → one §4.1 node; $base is BASE_BRANCH, the
#                      target when the body has no `Delivery-Target:` line.
#   gh_nodes($base)  — an issue array → the node array, non-delivery issues
#                      dropped, input order kept.
#   gh_short_blocked — the input issue's `blockedBy` returned fewer `nodes` than
#                      its `totalCount` (it needs a `gh issue view` re-read, GC64).
#   gh_short_comments — the input issue's `comments` may be truncated: `gh issue
#                      list` returns at most the first 100 per issue and exposes no
#                      total, so exactly 100 (or more) needs a re-read (GC74).
#   gh_reread_fields — the comma-joined `gh issue view --json` fields the input
#                      issue must re-read ("" when it is complete).
#
# Field derivation (github column of §4.1):
#   kind        `task` label, else `epic`, else `promote` (v0.1.4 listed every
#               `task`-labeled issue as a task, so `task` wins a double label).
#   epic        native `parent.number`, else the first `[Ee]pic #E` body match
#               (v0.1.4 parity: its task epic came from the body only).
#   checklist   epics only: the `- [ ] #N` / `- [x] #N` ids of the epic's own body,
#               first occurrence order, deduplicated.
#   deps        native `blockedBy.nodes[].number` ∪ legacy `Depends-on:` lines,
#               deduplicated, in numeric order (GC11). `via` comes from a
#               `Depends-on: #N (via: …)` line; null otherwise.
#   status      CLOSED: stateReason NOT_PLANNED/DUPLICATE → cancelled, else done
#               (v0.1.4 counted any CLOSED issue as done, GC9). OPEN: the most
#               advanced `status:*` label; none → ready (the label is a cache,
#               reconcile repairs it; ready.jq never reads it).
#   claim       `claim:agent`: the winning live `CLAIM <actor> <run> <ts>` comment
#               (lib/claim-ledger.jq), else the first assignee with run/at null,
#               else null — an actorless agent claim is drift for reconcile, not
#               a node validate_node must reject. No `claim:agent` but an
#               assignee: a human claim {actor: login, run: null, at: null}.
#   pinged_at   the newest `STALE-CLAIM-PING` comment's createdAt, else null.
#   applied_prs the PR numbers of every `AUTO-CLOSE: PR #<n>` comment, ascending,
#               deduplicated (reconcile rule 3 skips them, so a human reopen
#               sticks). v0.1.4's epic `AUTO-CLOSE: epic …` comment names no PR.
#               A PR that closed the issue by GitHub closing keyword (no comment)
#               is not derived yet: that is task B2's (spec §4.1, GC75).
#   (comments)  pinged_at, applied_prs and claim need every comment; graph-github.sh
#               re-reads an issue whose list read may be truncated (GC74).
#   target_branch / plan_ref / promote_to
#               the `Delivery-Target:` / `Delivery-Plan:` / `Delivery-Promote-To:`
#               body lines (promote_to on promote nodes only).
#
# Line-oriented matches split the body on "\n" first: jq's Oniguruma `^`/`$` do
# not reliably anchor at line boundaries.
include "claim-ledger";

def _labels: [(.labels // [])[] | .name];

def _has_label($l): any(_labels[]; . == $l);

def _lines: (.body // "") | split("\n") | map(rtrimstr("\r"));

# Ordered dedupe: first occurrence wins.
def _uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

# The value of the first `<key>: <value>` body line (one token), or null.
def _trailer($key):
  [ _lines[] | capture("^" + $key + ":[ \t]*(?<v>[^ \t]+)") | .v ] | first // null;

def gh_kind:
  if _has_label("task") then "task"
  elif _has_label("epic") then "epic"
  elif _has_label("promote") then "promote"
  else null end;

def gh_epic:
  if (.parent | type) == "object" and .parent.number != null then .parent.number | tostring
  else [ (.body // "") | scan("[Ee]pic #([0-9]+)") | .[0] ] | first // null end;

def gh_checklist:
  [ _lines[] | capture("^[ \t]*[-*] \\[[ xX]\\][ \t]*#(?<n>[0-9]+)") | .n ] | _uniq;

# Legacy text edges: every `#N` on a `Depends-on:` line (v0.1.4 scanned the rest
# of each line), minus a trailing `(via: …)` annotation, which names the edge.
def _text_edges:
  [ _lines[]
    | capture("Depends-on:(?<rest>.*)").rest
    | ([ capture("[(]via:[ \t]*(?<v>.*[^ \t])[ \t]*[)][ \t]*$") | .v ] | first // null) as $via
    | sub("[(]via:.*$"; "")
    | scan("#([0-9]+)") | {id: .[0], via: $via} ];

def gh_native_deps:
  if (.blockedBy | type) == "object"
  then [ (.blockedBy.nodes // [])[] | .number | tostring ]
  else [] end;

def gh_deps:
  _text_edges as $text
  | [ gh_native_deps[], $text[].id ] | unique | sort_by(tonumber)
  | map(. as $id
        | {id: $id,
           via: ([ $text[] | select(.id == $id) | .via | select(. != null) ] | first // null)});

def gh_short_blocked:
  (.blockedBy | type) == "object"
  and (.blockedBy.totalCount // 0) > ((.blockedBy.nodes // []) | length);

# `gh issue list --json comments` returns an issue's first 100 comments only (no
# totalCount; gh 2.96.0). `gh issue view --json comments` pages them all.
def _gh_list_comment_cap: 100;

def gh_short_comments:
  ((.comments // []) | length) >= _gh_list_comment_cap;

def gh_reread_fields:
  [ (if gh_short_blocked then "blockedBy" else empty end),
    (if gh_short_comments then "comments" else empty end) ] | join(",");

# Most advanced first, so a label edit caught half-way still reads forward.
def _status_labels:
  ["approved", "changes-requested", "in-review", "claimed", "ready", "blocked"];

def gh_status:
  if .state == "CLOSED" then
    if .stateReason == "NOT_PLANNED" or .stateReason == "DUPLICATE" then "cancelled"
    else "done" end
  else
    _labels as $l
    | [ _status_labels[] | select(. as $s | any($l[]; . == "status:" + $s)) ] | first // "ready"
  end;

def gh_claim:
  [ (.assignees // [])[] | .login | select(type == "string" and length > 0) ] as $who
  | if _has_label("claim:agent") then
      ( {comments: (.comments // [])} | live_claims | sort_by(.createdAt)
        | map((.body | split(" ")) as $f
              | select(($f[1] // "") != "")
              | {actor: $f[1],
                 run: (if ($f[2] // "") == "" then null else $f[2] end),
                 at: .createdAt, by: "agent"})
        | first ) as $won
      | if $won != null then $won
        elif $who != [] then {actor: $who[0], run: null, at: null, by: "agent"}
        else null end
    elif $who != [] then {actor: $who[0], run: null, at: null, by: "human"}
    else null end;

def gh_pinged_at:
  [ (.comments // [])[] | select((.body // "") | startswith("STALE-CLAIM-PING")) | .createdAt ]
  | max // null;

# The number must follow the prefix directly (offset 0), so a body like
# "AUTO-CLOSE: PR #x\n5" names no PR; #0 is not a PR number.
def gh_applied_prs:
  [ (.comments // [])[] | (.body // "")
    | select(startswith("AUTO-CLOSE: PR #")) | ltrimstr("AUTO-CLOSE: PR #")
    | first(match("[0-9]+")) | select(.offset == 0) | .string | tonumber
    | select(. > 0) ]
  | unique;

# Several size:* labels: L wins (v0.1.4 excluded any size:L issue — L means
# "split me", never claimable), then S, then M (v0.1.4 ranked S only on size:S).
def gh_size:
  _labels as $l | [ ("L", "S", "M") | select(. as $s | any($l[]; . == "size:" + $s)) ] | first // null;

def gh_module:
  [ _labels[] | select(startswith("module:")) | ltrimstr("module:") ] | first // null
  | if . == "" then null else . end;

def gh_node($base):
  gh_kind as $kind
  | { id: (.number | tostring),
      kind: $kind,
      title: (.title // ""),
      epic: gh_epic,
      checklist: (if $kind == "epic" then gh_checklist else [] end),
      pinged_at: gh_pinged_at,
      applied_prs: gh_applied_prs,
      module: gh_module,
      size: gh_size,
      deps: gh_deps,
      status: gh_status,
      needs_human: _has_label("needs-human"),
      claim: gh_claim,
      target_branch: (_trailer("Delivery-Target") // $base),
      promote_to: (if $kind == "promote" then _trailer("Delivery-Promote-To") else null end),
      plan_ref: _trailer("Delivery-Plan"),
      body: (.body // ""),
      created_at: .createdAt,
      updated_at: .updatedAt };

def gh_nodes($base): map(select(gh_kind != null) | gh_node($base));
