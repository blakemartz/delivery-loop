#!/usr/bin/env bash
# gh-shim.sh — one offline `gh` for a board that spans both seams (GC26 parity,
# tests/parity-test.sh). It adds no behaviour: issue reads (and `--version`) go
# to the graph-github shim, everything else (pr, api, run) to the forge-github
# shim, each with its own fixture directory, so both merged shims and their
# fixtures are reused as they are.
#   SHIM_GRAPH_FX  dir holding $SHIM_BOARD (default: fixtures/graph-github)
#   SHIM_FORGE_FX  dir holding prs.json + lists.json (default: this dir)
#   SHIM_STATE     the shared call log ($SHIM_STATE/log) and shim state
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  issue|--version)
    SHIM_FX="${SHIM_GRAPH_FX:-$here/../graph-github}" exec bash "$here/../graph-github/gh-shim.sh" "$@" ;;
  *)
    SHIM_FX="${SHIM_FORGE_FX:-$here}" exec bash "$here/../forge-github/gh-shim.sh" "$@" ;;
esac
