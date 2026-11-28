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
# pr-diff · ci-failures · label-ensure.
#
# `label-ensure <name> <color> <description>` makes sure a repo-level label
# exists, so `pr-create --label` (which never creates one) can apply it. <color>
# is 6 hex digits, no `#`. A label the forge already offers this repo is left
# as it is (its color and description are not touched) and prints
# `{name, created: false}`; a missing one is created and prints
# `{name, created: true}`. delivery-init.sh calls it for the PR labels the loop
# relies on. <color> is checked here, once for every adapter (usage, exit 2,
# before any I/O). Under FORGE_DRY_RUN=1 every adapter still reads the labels
# but creates nothing: a missing label prints the write it would have sent (the
# curl adapters' `METHOD PATH` + JSON body, github's `gh label create …` line)
# instead of the `{name, created}` object, and exits 0.
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
  pr-comments|pr-merge|pr-set-base|pr-files|pr-diff|ci-failures|label-ensure) : ;;
  *) echo "usage: forge.sh <op> [args]; ops: whoami pr-create pr-view pr-list pr-find pr-review pr-reviews pr-comment pr-comments pr-merge pr-set-base pr-files pr-diff ci-failures label-ensure (docs/delivery_graph_spec.md §7.1)" >&2
     exit 2 ;;
esac

# need_color <color>: <color> is exactly 6 hex digits (no `#`), else usage.
need_color() {
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) : ;;
    *) echo "forge.sh: usage: label-ensure <name> <color: 6 hex digits, no #> <description>" >&2
       exit 2 ;;
  esac
}
[ "$1" != label-ensure ] || need_color "${3:-}"

adapter="$SCRIPT_DIR/backends/forge-$FORGE.sh"
[ -f "$adapter" ] || { echo "forge.sh: no adapter for FORGE=$FORGE ($adapter missing)" >&2; exit 1; }
exec bash "$adapter" "$@"
