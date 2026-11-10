# graph.jq — shared helpers over a list of normalized nodes
# (docs/delivery_graph_spec.md §5; node shape §4.1).
#
# Used by ready.jq, reconcile, tick-plan and plan lint, so "an epic's children",
# "how many tasks this unblocks" and "the dependency cycles" are defined once.
# Pure: no I/O, no clock. Unless noted, the input is the full node array.
#
#   index_by_id     — {id: node} lookup.
#   is_open         — the input node's status is neither done nor cancelled.
#   children($epic) — the child nodes of epic id $epic: nodes whose `epic` is
#                     $epic, plus the epic's own `checklist` ids that exist.
#                     Every kind counts, `external` included (§5).
#   unblocks($id)   — how many open nodes list $id in their `deps`.
#   deps_done($idx) — every dep of the input node exists and is done (a
#                     cancelled or unknown dep never counts, GC2/GC7).
#   id_key          — sort key for one id: numeric ids by value, then slugs.
#   cycle_report    — {sccs: [{members, cycle}], total}: one representative
#                     cycle per non-trivial strongly connected component of the
#                     `deps` edges, capped at cycle_cap SCCs. O(V + E).
#   cycles          — those cycles alone, each an id path [a, b, …, a] that
#                     starts and ends at its SCC's smallest id (id_key order).
#   cycle_text($arrow) — the report as lines for a diagnostic: each cycle, plus
#                     the SCC members it misses, plus a line for any overflow.
#   iso_epoch       — seconds since the epoch for one ISO-8601 timestamp.
#
# Usage: jq -L scripts/lib 'include "graph"; cycles' nodes.json

def index_by_id: reduce .[] as $n ({}; .[$n.id] = $n);

def is_open: .status != "done" and .status != "cancelled";

def children($epic):
  ((map(select(.id == $epic)) | first // {}) | .checklist // []) as $listed
  | map(select(.epic == $epic or (.id as $id | any($listed[]; . == $id))));

def deps_done($idx): all(.deps[]; $idx[.id].status == "done");

def unblocks($id):
  map(select(is_open and any(.deps[]; .id == $id))) | length;

# id_key — sort key for one id: all-digit ids (GitHub numbers) compare as
# numbers, so "1000" follows "999"; other ids (local slugs) compare as strings
# and follow every numeric id. "Smallest id" in `cycles` means smallest id_key.
def id_key: if test("^[0-9]+$") then [0, tonumber] else [1, .] end;

# _dep_adj — {id: [dep id]}: each node's deps that name a known node, deduped
# and in id_key order. Edges to unknown ids are dropped: they cannot close a
# cycle (an unknown dep is its own diagnostic, §5).
def _dep_adj:
  index_by_id as $idx
  | reduce .[] as $n ({};
      .[$n.id] = ([$n.deps[].id | select($idx[.] != null)] | unique | sort_by(id_key)));

# _sccs($adj) — the strongly connected components of $adj ({id: [succ id]}), as
# id arrays, by Tarjan's algorithm run iteratively (an explicit frame stack, so
# depth is not bounded by jq's recursion). O(V + E).
def _sccs($adj):
  reduce ($adj | keys[]) as $root (
    {next: 0, index: {}, low: {}, on: {}, stack: [], sccs: []};
    if .index[$root] != null then .
    else
      .index[$root] = .next | .low[$root] = .next | .next += 1
      | .stack += [$root] | .on[$root] = true
      | .frames = [[$root, 0]]
      | until(.frames == [];
          .frames[-1] as [$v, $i]
          | if $i < ($adj[$v] | length) then
              $adj[$v][$i] as $w
              | .frames[-1][1] = $i + 1
              | if .index[$w] == null then
                  .index[$w] = .next | .low[$w] = .next | .next += 1
                  | .stack += [$w] | .on[$w] = true
                  | .frames += [[$w, 0]]
                elif .on[$w] then
                  .low[$v] = ([.low[$v], .index[$w]] | min)
                else . end
            else
              .frames |= .[:-1]
              | if .low[$v] == .index[$v] then
                  (.stack | rindex([$v])) as $at
                  | .stack[$at:] as $comp
                  | .sccs += [$comp]
                  | .stack |= .[:$at]
                  | reduce $comp[] as $c (.; .on[$c] = false)
                else . end
              | if .frames == [] then .
                else .frames[-1][0] as $u
                  | .low[$u] = ([.low[$u], .low[$v]] | min) end
            end)
    end)
  | .sccs;

# _scc_cycle($adj; $in) — the input id $s is the smallest member of a
# non-trivial SCC whose members are the keys of $in. A shortest cycle through
# $s inside the SCC, as [$s, …, $s]: a breadth-first walk from $s over the
# SCC's edges in $adj order, stopping at the first id with an edge back to $s.
# O(V + E) of the SCC; the queue is read by index, never sliced.
def _scc_cycle($adj; $in):
  . as $s
  | {parent: {}, seen: {($s): true}, todo: [$s], head: 0, found: null}
  | until(.found != null;
      .todo[.head] as $v
      | .head += 1
      | if any($adj[$v][]; . == $s) then .found = $v
        else reduce ($adj[$v][] | select($in[.] and true)) as $w (.;
          if .seen[$w] then . else .seen[$w] = true | .parent[$w] = $v | .todo += [$w] end)
        end)
  | .parent as $parent
  | [.found | recurse(if . == $s then empty else $parent[.] end)] | reverse + [$s];

# cycle_cap — the most cyclic SCCs cycle_report lists; the rest are counted.
def cycle_cap: 20;

# cycle_report — {sccs: [{members, cycle}], total}: one entry per non-trivial
# SCC (more than one node, or a self-loop), at most cycle_cap of them, ordered
# by their smallest id; `total` counts every such SCC. `members` is the SCC in
# id_key order; `cycle` is a shortest cycle through its smallest id (see
# _scc_cycle). Reusing the Tarjan pass keeps the cost O(V + E) on any graph:
# §5 needs every cycle reported, not every cycle enumerated (a dense SCC holds
# exponentially many).
def cycle_report:
  _dep_adj as $adj
  | [ _sccs($adj)[]
      | select(length > 1 or (.[0] as $v | any($adj[$v][]; . == $v)))
      | sort_by(id_key) ]
  | sort_by(.[0] | id_key)
  | { sccs: [ .[:cycle_cap][]
              | . as $m
              | {members: $m,
                 cycle: ($m[0] | _scc_cycle($adj; reduce $m[] as $c ({}; .[$c] = true)))} ],
      total: length };

# cycles — the cycle_report cycles alone: one id path per listed SCC.
def cycles: cycle_report | [.sccs[].cycle];

# cycle_text($arrow) — one line per listed SCC naming its cycle, joined by
# $arrow, plus the SCC's members when the cycle does not visit them all; then
# one line counting the SCCs past cycle_cap, if any. Callers prefix the lines.
def cycle_text($arrow):
  cycle_report
  | (.sccs[]
     | (.cycle | join($arrow))
       + (if (.cycle | length) - 1 < (.members | length)
          then " (SCC: \(.members | join(", ")))" else "" end)),
    (if .total > (.sccs | length)
     then "\(.total - (.sccs | length)) more cyclic SCCs not listed (cap \(cycle_cap))" else empty end);

# jq's fromdateiso8601 parses only "…:SSZ". The node and PR shapes (shape.jq
# is_iso8601) also admit fractional seconds and a ±hh:mm offset, so normalize
# both before converting. Fractions are kept, so sub-second order survives.
def iso_epoch:
  capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<frac>[.][0-9]+)?(?<off>Z|[+-][0-9]{2}:[0-9]{2})$")
  | ((.dt + "Z") | fromdateiso8601)
    + (if .frac then "0\(.frac)" | tonumber else 0 end)
    - (if .off == "Z" then 0
       else (if .off[0:1] == "-" then -1 else 1 end)
            * ((.off[1:3] | tonumber) * 3600 + (.off[4:6] | tonumber) * 60) end);
