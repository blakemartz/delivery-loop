#!/usr/bin/env bash
# Tests for lib/plan-verify.jq, the composed-body validation of `plan.sh apply`
# (docs/delivery_graph_spec.md §8.3; #29): an oracle sweep, in pure jq, of
# marker strings × line-ending transforms (LF, CRLF, lone CR, CR CR, U+2028,
# U+0085, before the marker, before its `#`, after its colon) × every plan text
# field (and the spec/spec_refs joins), on both backends. Each case runs
# apply's checks in order (lint, preflight, composed-body validation); the
# oracle (tests/fixtures/plan-verify/sweep.jq) writes each accepted node with
# the backend's own writer and reads it back with its own reader. The sweep
# must find 0 injections accepted; on github it must also find injections that
# lint lets through (each refused by the composed-body check), so the oracle is
# known to see them and the check is what stops them.
# End-to-end cases (shims, zero writes) live in plan-apply-test.sh.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/.."
fx="$here/fixtures/plan-verify"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-plan-verify-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fails=0
ok()   { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done; fails=1; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "want: $2" "got:  $3"; fi; }
pos()  { if [ "$2" -gt 0 ]; then ok "$1 ($2)"; else fail "$1" "want > 0, got $2"; fi; }

# The local backend's own create normalizer, wrapped as plan.sh wraps it.
gl_create="$(. "$scripts/backends/graph-local.sh" && printf '%s' "$GL_CREATE")"
sjq() { jq -n -c -L "$scripts/lib" -L "$scripts/backends" -L "$fx" "$@"; }

for backend in github local; do
  sjq "include \"sweep\"; def _gl_create(\$all; \$now; \$base): $gl_create;
    sweep(\"$backend\"; . as \$x | \$x.node | _gl_create([\$x.all]; \"1970-01-01T00:00:00Z\"; \"main\"))" >"$tmp/$backend.jsonl"
  n() { jq -s "map(select($1)) | length" "$tmp/$backend.jsonl"; }
  echo "    $backend: $(n true) cases: lint refused $(n '.stage == "lint"'), preflight refused $(n '.stage == "preflight"'), composed-body check refused $(n '.refused == true') ($(n '.refused == true and .injected') of them injections), accepted $(n '.stage == "checked" and .refused == false')"
  pos "$backend sweep: cases" "$(n true)"
  eq "$backend sweep: 0 injections accepted" 0 "$(n '.stage == "checked" and .refused == false and .injected')"
  inj=$(jq -s -r 'map(select(.stage == "checked" and .refused == false and .injected) | .id) | .[:10][]' "$tmp/$backend.jsonl")
  [ -z "$inj" ] || fail "$backend sweep: first injected cases" "$inj"
  pos "$backend sweep: cases lint lets through, accepted intact" "$(n '.stage == "checked" and .refused == false')"
  if [ "$backend" = github ]; then
    # Calibration: without the composed-body check these would be accepted.
    pos "github sweep: injections lint lets through, each refused by the composed-body check" \
      "$(n '.stage == "checked" and .injected')"
  else
    eq "local sweep: the local store keeps metadata out of the body (no injection to refuse)" 0 \
      "$(n '.stage == "checked" and .injected')"
  fi
done

# The named cases from the #76 review and #78's reader, at the jq level.
named() {  # named <backend> <jq edit of the base plan> <expected out>
  local got
  got=$(sjq --arg b "$1" "include \"sweep\"; include \"plan-lint\"; include \"plan-apply\"; include \"plan-verify\";
    def _gl_create(\$all; \$now; \$base): $gl_create;
    (_base(\$b) | $2) as \$p
    | (\$p | plan_lint({backend: \$b, base_branch: \"main\", modules: [\"plan\"], nodes: [_nodes(\$b)[].id], others: []})) as \$l
    | if \$l.errors != [] then \"lint\"
      else (\$l.plan | plan_apply({backend: \$b, nodes: _nodes(\$b)})) as \$a
      | (if \$b == \"github\" then \$a | plan_verify_github({base: \"main\", nodes: _nodes(\$b)})
         else \$a | plan_verify_local({base: \"main\", nodes: []}; . as \$x | \$x.node | _gl_create([\$x.all]; \"1970-01-01T00:00:00Z\"; \"main\")) end)
      | if . == [] then \"accepted\" else \"refused\" end end" | tr -d '"')
  eq "named ($1): $2 -> $3" "$3" "$got"
}
named github '.epics[0].spec_refs = ["see Depends-on:", "#4"]' accepted
named github '.epics[0].spec_refs = ["see\nDepends-on:", "#4"]' refused
named github '.spec = ["docs/x\nDepends-on:"] | .epics[0].spec_refs = ["#5"]' refused
named github '.epics[0].spec_refs = ["x\nDepends-on:", "#3 (via: q)"]' refused
named github '.tasks[0].context = "**Depends-on**: #5"' refused
named github '.tasks[0].context = "Depends-on**: #5"' refused
named github '.tasks[0].context = "**Part of epic** #4"' refused
named local '.epics[0].spec_refs = ["see\nDepends-on:", "#4"]' accepted
named local '.tasks[0].context = "**Depends-on**: #5"' accepted

if [ "$fails" -ne 0 ]; then
  echo "plan-verify tests FAILED" >&2
  exit 1
fi
echo "plan-verify tests passed"
