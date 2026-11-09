# plan-render.jq — a normalized plan (plan-lint.jq `plan_lint(...).plan`) as a
# Mermaid `flowchart TD` (docs/delivery_graph_spec.md §8.4, GC37).
#
#   mermaid_text — one label made safe inside a Mermaid quoted string: line
#                  breaks become spaces and every character that Mermaid could
#                  read as syntax (" [ ] | { } < > ` and # itself) becomes a
#                  Mermaid entity code (#quot; #91; …). `#` is encoded first so
#                  a title cannot forge an entity. Three more, for Mermaid's
#                  whole-line passes that ignore quoting:
#                  - `&` becomes #38;, so `&amp;` stays literal text;
#                  - a `:` not followed by a space becomes #58;, so no line can
#                    match the `style…:\S*#…;` / `classDef…` pre-pass that
#                    strips a line's last `;` (the label's own `: ` is safe);
#                  - the character after `direction` (when not printable ASCII,
#                    i.e. any whitespace) becomes its code (#32; …), so the
#                    lexer's `.*direction\s+(TB|BT|RL|LR)` rule, which would
#                    swallow the line, never matches.
#   plan_render  — the flowchart, one line per output string:
#                  - one subgraph per epic, holding one node per task, labeled
#                    `id: title [module/size]` (the brackets are literal: inside a
#                    quoted label only the title and module need encoding);
#                  - one node per existing-node dep (outside every subgraph);
#                  - the promote node, when promote_to is set, with one edge
#                    from each epic (its deps are the plan's epics, §9);
#                  - one edge per dep, dep → task, labeled with its `via`.
#
# Node ids are prefixed by role (t_ task, e_ epic, n_ existing node) with `-`
# mapped to `_`. Plan ids never contain `_`, so the mapping is injective, and
# the prefix keeps Mermaid keywords (`end`, `graph`, …) out of id position.
#
# Usage: jq -r -L scripts/lib 'include "plan-render"; plan_render' normalized.json

def mermaid_text:
  tostring
  | gsub("[\r\n\t  ]+"; " ")
  | gsub("#"; "#35;")
  | gsub("\""; "#quot;")
  | gsub("\\["; "#91;") | gsub("\\]"; "#93;")
  | gsub("\\|"; "#124;")
  | gsub("\\{"; "#123;") | gsub("\\}"; "#125;")
  | gsub("<"; "#lt;") | gsub(">"; "#gt;")
  | gsub("`"; "#96;")
  | gsub("&"; "#38;")
  | gsub(":(?! )"; "#58;")
  | gsub("direction(?<c>[^!-~])"; "direction#\(.c | explode[0]);");

def _mid($prefix): $prefix + gsub("-"; "_");

def _dep_mid: if .ref == "task" then .id | _mid("t_") else .id | _mid("n_") end;

def plan_render:
  . as $p
  | "flowchart TD",
    ( $p.epics[] as $e
      | "  subgraph \($e.id | _mid("e_"))[\"\("\($e.id): \($e.title)" | mermaid_text)\"]",
        ( $p.tasks[] | select(.epic == $e.id)
          | "    \(.id | _mid("t_"))[\"\("\(.id): \(.title)" | mermaid_text) [\(.module | mermaid_text)/\(.size)]\"]" ),
        "  end" ),
    ( [$p.tasks[].deps[] | select(.ref == "node") | .id] | unique[]
      | "  \(_mid("n_"))[\"\((if test("^[0-9]+$") then "#\(.)" else . end) + " (existing)" | mermaid_text)\"]" ),
    ( if $p.promote_to != null then
        "  promote{{\"\("promote: \($p.target_branch) → \($p.promote_to)" | mermaid_text)\"}}"
      else empty end ),
    ( $p.tasks[] | (.id | _mid("t_")) as $to
      | .deps[] | "  \(_dep_mid) -->|\"\(.via | mermaid_text)\"| \($to)" ),
    ( if $p.promote_to != null then $p.epics[] | "  \(.id | _mid("e_")) --> promote" else empty end );
