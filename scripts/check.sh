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

run_tests() {
  for t in plugins/delivery-loop/scripts/tests/*-test.sh; do
    [ -e "$t" ] || continue
    echo "--> $t"
    bash "$t"
  done
}

echo '==> unit tests (every plugins/delivery-loop/scripts/tests/*-test.sh)'
run_tests

# The same suite under a real bash 3.2 (the macOS default the engine targets),
# so 3.2-only regressions can't hide behind the host's bash 5. Optional, never
# silent: it runs in the first environment available, else prints a SKIPPED
# notice and the gate continues.
#   DL_BASH32=/path/to/bash-3.2  run with that binary first on PATH (so the
#                                tests' own `bash …` calls are 3.2 too), using
#                                the host's jq and git.
#   DL_BASH32=off                skip explicitly.
#   unset                        use the local docker image DL_BASH32_IMAGE
#                                (default bash:3.2; never pulled). The repo is
#                                mounted read-only; git and jq < 1.8 (1.8.2
#                                breaks, see #62) are apk-installed in the
#                                container unless the image already has them.
#                                No network / no image -> SKIPPED.
echo '==> unit tests under bash 3.2 (optional; DL_BASH32 or docker image)'
bash32_skip() { echo "!!! SKIPPED bash 3.2 test run: $1" >&2; }
if [ "${DL_BASH32:-}" = off ]; then
  bash32_skip "DL_BASH32=off"
elif [ -n "${DL_BASH32:-}" ]; then
  v="$("$DL_BASH32" -c 'echo "$BASH_VERSION"' 2>/dev/null)" || v=""
  case "$v" in
    3.2*) ;;
    *) echo "FAIL: DL_BASH32=$DL_BASH32 is not a bash 3.2 binary (version: '${v:-none}')" >&2; exit 1 ;;
  esac
  shim="$(mktemp -d)"
  trap 'rm -rf "$shim"' EXIT
  ln -s "$DL_BASH32" "$shim/bash"
  echo "    bash $v via DL_BASH32, $(jq --version)"
  (PATH="$shim:$PATH"; export PATH; run_tests)
elif command -v docker >/dev/null 2>&1 \
     && docker image inspect "${DL_BASH32_IMAGE:-bash:3.2}" >/dev/null 2>&1; then
  top="$(pwd -P)"
  common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"   # worktrees point here
  # Exit 77 = the container couldn't be provisioned (environment, not a failure).
  inner='
    command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null 2>&1 || exit 77
    case "$(jq --version 2>/dev/null)" in jq-1.[67]*|jq-1.8.[01]) ;; *)
      apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/v3.21/main "jq<1.8" \
        >/dev/null 2>&1 || exit 77 ;;
    esac
    git config --global safe.directory "*"
    echo "    bash $BASH_VERSION in container, $(jq --version), $(git --version)"
    for t in plugins/delivery-loop/scripts/tests/*-test.sh; do
      echo "--> $t"; bash "$t" || exit 1
    done'
  rc=0
  docker run --rm -v "$top:$top:ro" -v "$common:$common:ro" -w "$top" \
    "${DL_BASH32_IMAGE:-bash:3.2}" bash -c "$inner" || rc=$?
  case "$rc" in
    0) ;;
    77) bash32_skip "could not install git/jq in ${DL_BASH32_IMAGE:-bash:3.2} (no network?)" ;;
    *) echo "FAIL: unit tests under bash 3.2 (above)" >&2; exit 1 ;;
  esac
else
  bash32_skip "set DL_BASH32 to a bash 3.2 binary, or provide docker image ${DL_BASH32_IMAGE:-bash:3.2}"
fi

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
