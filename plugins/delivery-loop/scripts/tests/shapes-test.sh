#!/usr/bin/env bash
# Unit tests for lib/node.jq (validate_node) and lib/pr.jq (validate_pr): the
# normalized node and PR shapes of docs/delivery_graph_spec.md §4.1–§4.2.
#
# Every valid fixture must pass through unchanged; every malformed fixture must
# be rejected (jq exits nonzero) with an error naming the defect. Offline: the
# fixtures under fixtures/shapes/ are the only input.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lib="$here/../lib"
fx="$here/fixtures/shapes"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; shift; for l in "$@"; do echo "        $l" >&2; done; fails=1; }

# accept <module> <validator> <fixture>: the fixture is an array; every element
# must validate, and the output must equal the input (validators are identity).
accept() {
  local mod="$1" fn="$2" file="$3" got want
  if ! got=$(jq -c -L "$lib" "include \"$mod\"; map($fn)" "$fx/$file" 2>&1); then
    fail "$file accepted by $fn" "error: $got"
    return
  fi
  want=$(jq -c . "$fx/$file")
  if [ "$got" = "$want" ]; then
    pass "$file accepted by $fn"
  else
    fail "$file accepted by $fn" "output differs from input"
  fi
}

# reject <module> <validator> <fixture> <expected error substring>
reject() {
  local mod="$1" fn="$2" file="$3" expect="$4" got
  if got=$(jq -c -L "$lib" "include \"$mod\"; $fn" "$fx/$file" 2>&1); then
    fail "$file rejected by $fn" "accepted, but expected an error containing: $expect"
    return
  fi
  case "$got" in
    *"$expect"*) pass "$file rejected by $fn ($expect)" ;;
    *) fail "$file rejected by $fn" "expected error containing: $expect" "got: $got" ;;
  esac
}

# --- §4.1 node ---------------------------------------------------------------
accept node validate_node node-valid.json
reject node validate_node node-bad-missing-field.json     'missing field `target_branch`'
reject node validate_node node-bad-id.json                '`id` must match'
reject node validate_node node-bad-status.json            '`status` must be one of'
reject node validate_node node-bad-dep.json               '`deps[1]` must be an object'
reject node validate_node node-bad-claim.json             '`claim`: `by` must be "agent" or "human"'
reject node validate_node node-bad-checklist-on-task.json '`checklist` is for epic nodes only'
reject node validate_node node-bad-extra-field.json       'unexpected field `labels`'

# --- §4.2 pull request -------------------------------------------------------
accept pr validate_pr pr-valid.json
reject pr validate_pr pr-bad-number.json          '`number` must be a positive integer'
reject pr validate_pr pr-bad-state.json           '`state` must be one of'
reject pr validate_pr pr-bad-mergeable.json       '`mergeable` must be one of'
reject pr validate_pr pr-bad-patch-iteration.json '`patch_iteration` must be a non-negative integer'
reject pr validate_pr pr-bad-agent-label.json     '`agent` must equal whether `labels` contains'
reject pr validate_pr pr-bad-missing-field.json   'missing field `head_sha`'
reject pr validate_pr pr-bad-extra-field.json     'unexpected field `title`'

# A non-object is rejected outright, not crashed on.
if got=$(jq -n -L "$lib" 'include "node"; "42" | validate_node' 2>&1); then
  fail "non-object node rejected" "accepted"
else
  case "$got" in *"node must be an object"*) pass "non-object node rejected" ;;
    *) fail "non-object node rejected" "got: $got" ;; esac
fi

if [ "$fails" -ne 0 ]; then
  echo "shapes tests FAILED" >&2
  exit 1
fi
echo "shapes tests passed"
