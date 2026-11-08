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
#   unblocks($id)   — how many open nodes list $id in their `deps`.
#   cycles          — every simple cycle over the `deps` edges, each an id path
#                     [a, b, …, a] that starts and ends at its smallest id.
#   iso_epoch       — seconds since the epoch for one ISO-8601 timestamp.
#
# Usage: jq -L scripts/lib 'include "graph"; cycles' nodes.json

def index_by_id: reduce .[] as $n ({}; .[$n.id] = $n);

def is_open: .status != "done" and .status != "cancelled";

def children($epic):
  ((map(select(.id == $epic)) | first // {}) | .checklist // []) as $listed
  | map(select(.epic == $epic or (.id as $id | any($listed[]; . == $id))));

def unblocks($id):
  map(select(is_open and any(.deps[]; .id == $id))) | length;

# Each simple cycle is enumerated exactly once, rooted at its smallest id: the
# walk from root $s only visits ids greater than $s and never revisits one on
# the current path. Edges to unknown ids are ignored (they cannot close a cycle).
# Worst case is exponential in the number of cycles, which a real backlog
# (and plan lint's job of keeping it acyclic) keeps at or near zero.
def cycles:
  index_by_id as $idx
  | [ ($idx | keys[]) as $s
      | def _walk($path):
          ($idx[$path[-1]].deps | map(.id) | unique[]) as $w
          | if $w == $s then $path + [$s]
            elif $w > $s and $idx[$w] != null and (any($path[]; . == $w) | not)
            then _walk($path + [$w])
            else empty end;
        _walk([$s]) ];

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
