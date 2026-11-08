#!/usr/bin/env bash
# check.sh — THE verification gate for this repo.
#
# The single definition of "is this repo correct": the delivery loop runs this
# identically for implementers, reviewers, and patchers (it is GATE_CMD in
# .claude/delivery.conf). Change what "correct" means HERE, nowhere else.
#
# This repo dogfoods the delivery-loop plugin it ships, so the gate encodes the
# package's own invariants: every script parses, the shipped engine stays
# bash-3.2 clean, every unit test under plugins/delivery-loop/scripts/tests/
# passes, the manifests validate and agree on the version, and no consumer-specific
# string has leaked into the shipped plugin. Requires the `claude` CLI on PATH.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo '==> bash -n: every script parses'
for f in $(find plugins scripts -name '*.sh'); do bash -n "$f"; done

echo '==> bash 3.2 lint: no bash-4+ constructs in plugins/delivery-loop/scripts/'
# The shipped engine targets bash 3.2 (macOS default). Fail on any bash-4+
# construct: declare -A, mapfile, readarray, ${x,,}, ${x^^}, &>>, |&, coproc.
# Comment-only lines are ignored so prose may name a construct.
bash4_re='declare -A|(^|[^A-Za-z0-9_])(mapfile|readarray|coproc)([^A-Za-z0-9_]|$)|[$][{][A-Za-z_][A-Za-z0-9_]*(,,|\^\^)|&>>|[|]&'
if grep -rnE "$bash4_re" plugins/delivery-loop/scripts/ | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' >&2; then
  echo "FAIL: bash-4+ construct in the shipped engine (above); target bash 3.2" >&2
  exit 1
fi

echo '==> unit tests (every plugins/delivery-loop/scripts/tests/*-test.sh)'
for t in plugins/delivery-loop/scripts/tests/*-test.sh; do
  [ -e "$t" ] || continue
  echo "--> $t"
  bash "$t"
done

echo '==> plugin manifest validates'
claude plugin validate ./plugins/delivery-loop

echo '==> manifest versions agree (plugin.json == marketplace.json)'
plugin_v="$(jq -r .version plugins/delivery-loop/.claude-plugin/plugin.json)"
market_v="$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)"
if [ "$plugin_v" != "$market_v" ]; then
  echo "FAIL: plugin.json ($plugin_v) != marketplace.json ($market_v)" >&2
  exit 1
fi

echo '==> no consumer-specific strings in plugins/'
if grep -rin lineage plugins/ >&2; then
  echo "FAIL: consumer-specific string leaked into the shipped plugin (above)" >&2
  exit 1
fi

echo "==> gate passed"
