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
#   gh_external($base) — one unlabelled issue → its §4.1 `external` node.
#   gh_nodes($base)  — an issue array → the node array, input order kept: every
#                      delivery issue, plus every unlabelled issue the graph
#                      references (§6.2) as an `external` node; any other
#                      unlabelled issue is dropped.
#   gh_short_blocked — the input issue's `blockedBy` returned fewer `nodes` than
#                      its `totalCount` (it needs a `gh issue view` re-read, GC64).
#   gh_short_comments — the input issue's `comments` may be truncated: `gh issue
#                      list` returns at most the first 100 per issue and exposes no
#                      total, so exactly 100 (or more) needs a re-read (GC74).
#   gh_reread_fields — the comma-joined `gh issue view --json` fields the input
#                      issue must re-read ("" when it is complete). Only
#                      delivery issues are re-read: an external's deps and
#                      comment-derived fields are fixed (§4.1).
#   gh_needs_closers — the input issue is an open delivery issue that some PR
#                      has a closing reference to: graph-github.sh reads its
#                      timeline's ClosedEvent closers (GC75) into `_closed_by_prs`.
#   gh_timeline_closers($repo) — a `gh api graphql` timeline response → the
#                      numbers of the PRs of repo $repo that closed the issue.
#   gh_migrate_plan  — a raw issue array → the native edges `graph.sh migrate`
#                      adds to each open task: its legacy `Depends-on:` refs and
#                      `Part of epic #E` parent (task B3, §6.2, GC48).
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
#   applied_prs the PR numbers of every `AUTO-CLOSE: PR #<n>` comment, plus every
#               PR that closed the issue through a GitHub closing keyword
#               (`_closed_by_prs`, which graph-github.sh patches in from the
#               timeline), ascending, deduplicated (reconcile rule 3 skips them,
#               so a human reopen sticks, GC72/GC75). v0.1.4's epic `AUTO-CLOSE:
#               epic …` comment names no PR. Evidence (verified 2026-11-09
#               against live issues reopened after a keyword close, gh 2.96.0):
#               `closedByPullRequestsReferences` survives the reopen but also
#               lists still-open linked PRs, and never a PR into a non-default
#               branch; the timeline's `ClosedEvent.closer` names exactly the PR
#               that closed it (null for a `gh issue close`). So the reference
#               list selects which open issues to look up, and the closer is
#               the evidence.
#   (comments)  pinged_at, applied_prs and claim need every comment; graph-github.sh
#               re-reads an issue whose list read may be truncated (GC74).
#   external    an issue with no task/epic/promote label that a delivery node
#               references: a dep target (native blockedBy or `Depends-on:`), an
#               entry of an epic's checklist, or an issue whose epic derivation
#               names an epic node (§6.2). Its fixed fields are forced (§4.1:
#               claim/pinged_at/module/size/plan_ref/promote_to null, deps and
#               checklist [], needs_human false, applied_prs []): its labels,
#               assignees, comments and edges are never read. status: open ->
#               blocked; closed -> done | cancelled; epic as for any node;
#               target_branch is BASE_BRANCH.
#   target_branch / plan_ref / promote_to
#               the `Delivery-Target:` / `Delivery-Plan:` / `Delivery-Promote-To:`
#               lines of the body's trailer block (promote_to on promote nodes
#               only); a key line anywhere else in the body is prose (#77).
#
# The trailer block (§6.2) is the body's LAST paragraph that is a trailer
# paragraph: paragraphs are split on blank lines (empty, or only spaces, tabs
# and NBSPs; trailing whitespace on a line is ignored), and a trailer paragraph
# is one whose every line is a trailer line — a machine key line
# (`Delivery-Target:` / `Delivery-Plan:` / `Delivery-Promote-To:` /
# `Delivery-Task:` followed by a value), a `Depends-on:` line, or a `Part of
# epic #E` line, each at column 0 — and at least one of them a machine key line.
# Paragraphs below it (prose a human appended: "Update: …", a `Depends-on:`
# line of its own) are skipped, so appending never loses the block (#77
# review A); key lines in any paragraph above it, or in a paragraph that mixes
# them with prose, are prose. `create` always writes the block last (a
# Delivery-Target line at least, after a blank line) and `link` appends
# `Depends-on:` lines to the last paragraph, so bodies written by v0.1.4 and B2
# (key lines last) read as before. Within the block the first line of a key
# wins. A body with no trailer paragraph has no machine keys.
# Machine keys are read from the block only. `Depends-on:` and `Part of epic`
# stay human-authored body conventions read on any line, but only at line start
# (after optional indentation, one `-`/`*`/`+` list bullet and a `**` bold
# opener; `Depends-on` may also close the bold before or after its colon), so
# prose that mentions them mid-line, a checklist item, a quote (`> …`) or code
# span adds no edge and no migrate parent (§2 exception 7). (The `epic` field's
# `[Ee]pic #E` body fallback keeps v0.1.4's match anywhere, §4.1: it orders, it
# adds no edge.)
#
# Line-oriented matches split the body on "\n" first: jq's Oniguruma `^`/`$` do
# not reliably anchor at line boundaries.
include "claim-ledger";

def _labels: [(.labels // [])[] | .name];

def _has_label($l): any(_labels[]; . == $l);

def _lines: (.body // "") | split("\n") | map(rtrimstr("\r"));

# Ordered dedupe: first occurrence wins.
def _uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

def _is_blank: test("^[ \t\u00a0]*$");

def _rtrim_ws: sub("[ \t\u00a0]+$"; "");

def _is_key_line:
  test("^(Delivery-Target|Delivery-Plan|Delivery-Promote-To|Delivery-Task):[ \t]*[^ \t]");

def _is_trailer_line:
  _is_key_line
  or startswith("Depends-on:")
  or test("^Part of [Ee]pic #[0-9]+([^0-9]|$)");

# The body's trailer block (see the header), as lines (trailing whitespace
# trimmed); [] when it has none.
def _trailer_block:
  reduce (_lines[] | _rtrim_ws) as $l ({cur: [], out: []};
    if $l == "" then (if .cur == [] then . else {cur: [], out: (.out + [.cur])} end)
    else .cur += [$l] end)
  | (.out + (if .cur == [] then [] else [.cur] end))
  | [ .[] | select(all(.[]; _is_trailer_line) and any(.[]; _is_key_line)) ]
  | last // [];

# The value of the trailer block's first `<key>: <value>` line (one token), or null.
def _trailer($key):
  [ _trailer_block[] | capture("^" + $key + ":[ \t]*(?<v>[^ \t]+)") | .v ] | first // null;

# Line start for the human-authored conventions (see the header): indentation,
# an optional list bullet, an optional bold opener.
def _line_lead: "^[ \t]*(?:[-*+][ \t]+)?(?:[*][*])?";

# The rest of a `Depends-on:` line (bold closed before or after the colon).
def _dep_rest: capture(_line_lead + "Depends-on(?:[*][*])?:(?:[*][*])?(?<rest>.*)").rest;

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

# Legacy text edges: every `#N` on a line that starts `Depends-on:` (see
# _line_lead; v0.1.4 scanned the rest of each line), minus a trailing
# `(via: …)` annotation, which names the edge. Unlike v0.1.4, a mid-line
# `Depends-on:` is prose, not an edge (§2 exception 7).
def _text_edges:
  [ _lines[]
    | _dep_rest
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
  if gh_kind == null then ""
  else
    [ (if gh_short_blocked then "blockedBy" else empty end),
      (if gh_short_comments then "comments" else empty end) ] | join(",")
  end;

def gh_needs_closers:
  gh_kind != null and .state == "OPEN"
  and ((.closedByPullRequestsReferences // []) | length) > 0;

def gh_timeline_closers($repo):
  [ (.data.repository.issue.timelineItems.nodes // [])[]
    | .closer | select(type == "object" and .__typename == "PullRequest")
    | select((.repository.nameWithOwner // "") | ascii_downcase == ($repo | ascii_downcase))
    | .number | select(type == "number" and . > 0) ] | unique;

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
  [ ( (.comments // [])[] | (.body // "")
      | select(startswith("AUTO-CLOSE: PR #")) | ltrimstr("AUTO-CLOSE: PR #")
      | first(match("[0-9]+")) | select(.offset == 0) | .string | tonumber ),
    ( (._closed_by_prs // [])[] | select(type == "number") )
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

def _gh_closed_status:
  if .stateReason == "NOT_PLANNED" or .stateReason == "DUPLICATE" then "cancelled" else "done" end;

def gh_external($base):
  { id: (.number | tostring),
    kind: "external",
    title: (.title // ""),
    epic: gh_epic,
    checklist: [],
    pinged_at: null,
    applied_prs: [],
    module: null,
    size: null,
    deps: [],
    status: (if .state == "CLOSED" then _gh_closed_status else "blocked" end),
    needs_human: false,
    claim: null,
    target_branch: $base,
    promote_to: null,
    plan_ref: null,
    body: (.body // ""),
    created_at: .createdAt,
    updated_at: .updatedAt };

# The ids a delivery node references (§6.2): dep targets and epic checklist
# entries, as a set; plus the epic node ids, which an issue's epic derivation
# may name.
def _gh_refs:
  map(select(gh_kind != null)) as $del
  | { ids: (reduce ( ($del[] | gh_deps[].id),
                     ($del[] | select(gh_kind == "epic") | gh_checklist[]) ) as $i
              ({}; .[$i] = true)),
      epics: (reduce ($del[] | select(gh_kind == "epic") | .number | tostring) as $e
              ({}; .[$e] = true)) };

def gh_nodes($base):
  _gh_refs as $r
  | map( if gh_kind != null then gh_node($base)
         elif $r.ids[.number | tostring]
              or (gh_epic as $e | $e != null and $r.epics[$e]) then gh_external($base)
         else empty end );

# --- write helpers (task B2) ------------------------------------------------------

# The status labels graph-github writes (§6.2: open statuses are labels).
def gh_status_label_names: _status_labels | map("status:" + .);

# gh_label_plan($p) — input: a raw issue. The label edit that applies patch $p
# (any of status / module / size / needs_human / claim_agent; an absent key
# changes nothing) as {add: [name], remove: [name]}: only labels the issue lacks
# are added and only labels it carries are removed, so gh never resolves an
# absent label. A new module or size replaces every other `module:*` / `size:*`
# label, so the read's precedence (first module; size L > S > M) can never mask
# the write; null removes them all.
def _gh_add_if_absent($have; $l): if any($have[]; . == $l) then [] else [$l] end;

def _gh_family($have; $prefix; $want):
  { add: (if $want == null then [] else _gh_add_if_absent($have; $want) end),
    remove: [ $have[] | select(startswith($prefix) and . != $want) ] };

def gh_label_plan($p):
  _labels as $have
  | [ (if $p | has("status") then
         ("status:" + $p.status) as $w
         | { add: _gh_add_if_absent($have; $w),
             remove: [ $have[] | select(. as $l | any(gh_status_label_names[]; . == $l) and . != $w) ] }
       else empty end),
      (if $p | has("module") then
         _gh_family($have; "module:"; (if $p.module == null then null else "module:" + $p.module end))
       else empty end),
      (if $p | has("size") then
         _gh_family($have; "size:"; (if $p.size == null then null else "size:" + $p.size end))
       else empty end),
      (if $p | has("needs_human") then
         if $p.needs_human then {add: _gh_add_if_absent($have; "needs-human"), remove: []}
         else {add: [], remove: [ $have[] | select(. == "needs-human") ]} end
       else empty end),
      (if ($p | has("claim_agent")) and ($p.claim_agent | not) then
         {add: [], remove: [ $have[] | select(. == "claim:agent") ]}
       else empty end) ]
  | {add: (map(.add[]) | _uniq), remove: (map(.remove[]) | _uniq)};

# gh_link_body($dep; $via) — input: a raw issue. Its body with the text edge
# `Depends-on: #<dep> (via: <via>)` recorded: a single-dep `Depends-on: #<dep>`
# line is rewritten in place (its via replaced), else the line is appended
# directly below the last non-blank line, so it joins the trailer block (§6.2)
# rather than starting a paragraph of its own. Line endings are normalized to
# "\n".
def gh_link_body($dep; $via):
  ("Depends-on: #" + $dep + (if $via == null then "" else " (via: " + $via + ")" end)) as $line
  | _lines as $ls
  | ([ $ls | to_entries[]
       | select(.value | test("^Depends-on:[ \t]*#" + $dep + "[ \t]*([(]via:.*[)])?[ \t]*$"))
       | .key ] | first // null) as $at
  | if $at != null then $ls | .[$at] = $line | join("\n")
    else ($ls | until(length == 0 or (.[-1] | _is_blank | not); .[:-1]) | join("\n")) as $b
         | (if $b == "" then $line else $b + "\n" + $line end) end;

# gh_has_text_edge($dep; $via) — the body already records the edge to $dep
# (with exactly $via, when $via is a string).
def gh_has_text_edge($dep; $via):
  any(_text_edges[]; .id == $dep and ($via == null or .via == $via));

# --- migrate (task B3) ------------------------------------------------------------

# The epic of a line that starts `Part of epic #E` (see _line_lead; §6.2: the
# legacy parent), or null. Mid-line prose ("not Part of epic #3") names no parent.
def _gh_part_of_epic:
  [ _lines[] | capture(_line_lead + "Part of [Ee]pic(?:[*][*])? #(?<e>[0-9]+)") | .e ] | first // null;

# The `Depends-on:` refs as migrate reads them: like _text_edges (line start
# only, via dropped), but a ref with an `owner/repo` prefix is kept apart as
# cross-repo, {repo, id}, so migrate never turns `other/repo#5` into a local
# native edge. (_text_edges itself keeps v0.1.4's `#N` scan, so `list` reads
# `other/repo#5` as #5.)
def _gh_dep_refs:
  [ _lines[]
    | _dep_rest
    | sub("[(]via:.*$"; "")
    | scan("([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#([0-9]+)") | {repo: .[0], id: .[1]} ];

# gh_migrate_plan — input: a raw issue array: every issue of the repo
# (`--state all`, complete blockedBy). For every open task, the native edits that
# carry its legacy text edges over (§6.2, GC48):
#   {id, links: [dep ids with a `Depends-on:` line but no native blocked-by, in
#    numeric order], parent: the `Part of epic #E` epic when there is no native
#    parent (else null), blockers: the native blocked-by count once the links
#    are added, blocking: {dep: the number of issues that dep blocks once every
#    planned link is added} for each of its links, warnings: [text]}.
# In ascending issue order (gh lists newest first). A task with nothing to add
# and nothing to warn about is left out, so a migrated board plans []. Text
# lines are never removed. The parent is set only when it is the epic the node
# already reads (gh_epic's body fallback), so migrating never changes a node's
# epic. Never planned (each warned about instead, so --apply cannot wedge on an
# edit GitHub rejects): a self edge; a dep or epic that is not an issue in the
# read (a dangling ref, GC7; a PR number; a deleted or transferred issue); a
# cross-repo `owner/repo#N` dep.
# `blocking` is a lower bound: it counts the native blocked-by edges of issues
# in this read only (not other repos' issues blocked by the dep, nor nodes
# beyond a short blockedBy of an unlabelled issue, which is not re-read).
def gh_migrate_plan:
  . as $all
  | ([ $all[] | .number | tostring ]) as $known
  | ([ $all[] | gh_native_deps[] ]) as $native_blocking
  | [ $all[] | select(gh_kind == "task" and .state == "OPEN")
      | (.number | tostring) as $id
      | gh_native_deps as $native
      | _gh_dep_refs as $refs
      | ([ $refs[] | select(.repo == null) | .id ] | unique | sort_by(tonumber)) as $text
      | ([ $refs[] | select(.repo != null) | "\(.repo)#\(.id)" ] | unique) as $cross
      | ([ $text[] | select(. as $d | $d != $id and ($native | index($d)) == null) ]) as $cand
      | ([ $cand[] | select(. as $d | ($known | index($d)) != null) ]) as $links
      | ([ $cand[] | select(. as $d | ($known | index($d)) == null) ]) as $unknown
      | ((.parent | type) == "object" and .parent.number != null) as $has_parent
      | _gh_part_of_epic as $text_part
      | (if $has_parent then null else $text_part end) as $part
      | gh_epic as $epic
      | (if $part != null and $part == $epic and $part != $id then $part else null end) as $want_parent
      | { id: $id,
          links: $links,
          parent: (if $want_parent != null and ($known | index($want_parent)) != null then $want_parent else null end),
          blockers: (([ (.blockedBy.totalCount // 0), ($native | length) ] | max) + ($links | length)),
          warnings: [ (if ($text | index($id)) != null then "#\($id) Depends-on: itself; not linked" else empty end),
                      ($unknown[] | "#\($id) Depends-on: #\(.), which is not an issue in this repo; not linked"),
                      ($cross[] | "#\($id) Depends-on: \(.) is in another repo; not linked (migrate links this repo's issues only)"),
                      (if $has_parent and $text_part != null and $text_part != (.parent.number | tostring)
                       then "#\($id) has native parent #\(.parent.number) but `Part of epic #\($text_part)`; parent left as is (fix the body)"
                       elif $part != null and $part == $id then "#\($id) is Part of epic of itself; parent not set"
                       elif $part != null and $part != $epic
                       then "#\($id) reads epic #\($epic) but has `Part of epic #\($part)`; parent not set (fix the body)"
                       elif $want_parent != null and ($known | index($want_parent)) == null
                       then "#\($id) Part of epic #\($want_parent), which is not an issue in this repo; parent not set"
                       else empty end) ] } ]
  | (reduce ($native_blocking[], .[].links[]) as $d ({}; .[$d] += 1)) as $blocks
  | map(.blocking = (.links | map({key: ., value: $blocks[.]}) | from_entries)
        | select(.links != [] or .parent != null or .warnings != []))
  | sort_by(.id | tonumber);
