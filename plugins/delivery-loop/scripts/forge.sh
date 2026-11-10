#!/usr/bin/env bash
# forge.sh <op> [args] — the forge seam (docs/delivery_graph_spec.md §7).
#
# Skills and engine scripts call this, never `gh pr`/`glab`/`tea`/`curl`
# directly (§3 rule 3). It resolves the config, validates the combination once
# (`delivery-config.sh --check` semantics, §11) before any I/O, and dispatches
# to backends/forge-$FORGE.sh, which maps the forge onto the §4.2 PR shape.
#
# Ops (§7.1): whoami · pr-create · pr-view · pr-list · pr-find · pr-review ·
# pr-reviews · pr-comment · pr-comments · pr-merge · pr-set-base · pr-files ·
# pr-diff · ci-failures.
#
# Exit codes: 0 ok · 1 failed / refused / invalid config · 2 usage ·
# 3 list reached LIST_LIMIT · 4 unsupported by this forge.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/config.sh
. "$SCRIPT_DIR/lib/config.sh"

dl_config_check || exit 1

case "${1:-}" in
  whoami|pr-create|pr-view|pr-list|pr-find|pr-review|pr-reviews|pr-comment|\
  pr-comments|pr-merge|pr-set-base|pr-files|pr-diff|ci-failures) : ;;
  *) echo "usage: forge.sh <op> [args]; ops: whoami pr-create pr-view pr-list pr-find pr-review pr-reviews pr-comment pr-comments pr-merge pr-set-base pr-files pr-diff ci-failures (docs/delivery_graph_spec.md §7.1)" >&2
     exit 2 ;;
esac

adapter="$SCRIPT_DIR/backends/forge-$FORGE.sh"
[ -f "$adapter" ] || { echo "forge.sh: no adapter for FORGE=$FORGE ($adapter missing)" >&2; exit 1; }
exec bash "$adapter" "$@"
