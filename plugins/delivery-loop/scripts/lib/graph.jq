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
#   cycles          — every simple cycle over the `deps` edges, each an id path
#                     [a, b, …, a] that starts and ends at its smallest id
#                     (id_key order). Near-linear on acyclic graphs.
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

# _reaching($s; $radj; $ok) — the ids in object $ok that reach $s through ids
# in $ok, $s included: a breadth-first walk of the reversed edges $radj.
def _reaching($s; $radj; $ok):
  {seen: {($s): true}, todo: [$s]}
  | until(.todo == [];
      .todo[0] as $v
      | .todo |= .[1:]
      | reduce ($radj[$v] // [] | .[] | select($ok[.] and true)) as $u (.;
          if .seen[$u] then . else .seen[$u] = true | .todo += [$u] end))
  | .seen;

# Every simple cycle, each exactly once as an id path [a, b, …, a] rooted at its
# smallest id (id_key order). Johnson-style restriction:
#   1. Tarjan SCCs: a cycle lies inside one SCC, so only non-trivial SCCs (more
#      than one node, or a self-loop) are searched. An acyclic graph stops here,
#      in O(V + E).
#   2. Within an SCC, the walk from root $s visits only ids ranked above $s
#      that can still reach $s through such ids (reverse reachability), so
#      every branch the walk takes can close a cycle back to $s.
# Unlike Johnson's blocked sets, a branch can still dead-end when its only way
# back runs through the current path, so a dense SCC can cost more than the
# cycles it holds; a backlog's SCCs are what lint reports, and stay tiny.
def cycles:
  _dep_adj as $adj
  | (reduce ($adj | to_entries[]) as $e ({}; reduce $e.value[] as $w (.; .[$w] += [$e.key])))
    as $radj
  | [ _sccs($adj)[]
      | select(length > 1 or (.[0] as $v | any($adj[$v][]; . == $v)))
      | sort_by(id_key) ] as $comps
  | [ $comps[]
      | . as $comp
      | range(0; length) as $r
      | $comp[$r] as $s
      | (reduce $comp[$r:][] as $c ({}; .[$c] = true)) as $above
      | _reaching($s; $radj; $above) as $live
      | def _walk($path; $on):
          $adj[$path[-1]][] as $w
          | if $w == $s then $path + [$s]
            elif $live[$w] and ($on[$w] | not) then _walk($path + [$w]; $on + {($w): true})
            else empty end;
        _walk([$s]; {($s): true}) ]
  | sort_by(map(id_key));

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
