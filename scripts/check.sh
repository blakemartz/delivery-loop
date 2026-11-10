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
# passes (each run under a fresh private TMPDIR it must leave empty), the
# manifests validate and agree on the version, and no consumer-specific
# string has leaked into the shipped plugin. Requires the `claude` CLI on PATH.
set -euo pipefail
invoked_from="$PWD"   # a relative DL_BASH32 is resolved against this, not the toplevel
cd "$(git rev-parse --show-toplevel)"
. scripts/lib/bash32.sh
. scripts/lib/private-tmp.sh

# Every test run below gets its own fresh private TMPDIR under gate_tmp and must
# leave it empty (scripts/lib/private-tmp.sh): a leaked temp file is a gate
# failure, listed by path (#70). The trap removes everything on any exit.
gate_tmp="$(mktemp -d "${TMPDIR:-/tmp}/dl-gate.XXXXXX")"
trap 'rm -rf "$gate_tmp"' EXIT

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

# Explicit status, not set -e: private_tmp_run calls this in a `||` context,
# where set -e is suspended.
run_tests() {
  for t in plugins/delivery-loop/scripts/tests/*-test.sh; do
    [ -e "$t" ] || continue
    echo "--> $t"
    bash "$t" || { echo "FAIL: $t" >&2; return 1; }
  done
}

echo '==> unit tests (every plugins/delivery-loop/scripts/tests/*-test.sh; private TMPDIR, no leaks)'
private_tmp_run "$gate_tmp" "unit tests" run_tests || exit 1

# The same suite under a real bash 3.2 (the macOS default the engine targets),
# so 3.2-only regressions can't hide behind the host's bash 5. Optional, never
# silent: it runs in the first environment available, else prints a SKIPPED
# notice and the gate continues.
#   DL_BASH32=/path/to/bash-3.2  run with that binary first on PATH (so the
#                                tests' own `bash …` calls are 3.2 too), using
#                                the host's jq and git. A bare name resolves via
#                                PATH, a relative path from the invoking cwd; it
#                                is linked by absolute path and re-verified as
#                                3.2 THROUGH the shim, else the gate FAILS
#                                (scripts/lib/bash32.sh; self-tested below).
#   DL_BASH32=off                skip explicitly.
#   unset                        use the local docker image DL_BASH32_IMAGE
#                                (default bash:3.2; never pulled). The repo is
#                                mounted read-only; git and a jq < 1.8 (1.8.2
#                                breaks, see #62) are apk-installed in the
#                                container unless the image already has them
#                                (any 1.6, 1.7 or 1.8.0/1.8.1 is kept) —
#                                stock bash:3.2 has neither, so this needs
#                                network on every run. A prebuilt local image
#                                with git + jq<1.8 (DL_BASH32_IMAGE=…) avoids
#                                that. No network / no image -> SKIPPED.
#                                The container makes its own private TMPDIR
#                                under its /tmp (not a host mount: files the
#                                container's root leaves there would be
#                                root-owned on the host) and runs the same
#                                leak check there; a leak fails the gate.
#                                The jq 1.6 stage below shares this container
#                                runner (container_suite).
echo '==> gate self-tests (scripts/tests/{bash32-shim,private-tmp}-test.sh; private TMPDIR, no leaks)'
private_tmp_run "$gate_tmp" "bash32-shim-test" bash scripts/tests/bash32-shim-test.sh || exit 1
private_tmp_run "$gate_tmp" "private-tmp-test" bash scripts/tests/private-tmp-test.sh || exit 1

# container_suite IMAGE LABEL PROVISION — run every unit test inside the local
# docker image IMAGE (never pulled): the repo and git's common dir (worktrees
# point there) mounted read-only, git safe.directory opened, one private TMPDIR
# under the container's /tmp with the same leak check. PROVISION is shell run
# first in the container; it exits 77 if the container can't be provisioned
# (an environment problem: the caller SKIPs) or 78 if the image is unfit (the
# caller FAILs). Returns the container's exit status.
container_suite() {
  _cs_top="$(pwd -P)"
  _cs_common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  _cs_inner="$3"'
    git config --global safe.directory "*"
    echo "    bash $BASH_VERSION in container, $(jq --version), $(git --version)"
    . scripts/lib/private-tmp.sh
    run() {
      for t in plugins/delivery-loop/scripts/tests/*-test.sh; do
        echo "--> $t"; bash "$t" || { echo "FAIL: $t" >&2; return 1; }
      done
    }
    gate_tmp="$(mktemp -d /tmp/dl-gate.XXXXXX)" || exit 1
    trap '"'"'rm -rf "$gate_tmp"'"'"' EXIT
    private_tmp_run "$gate_tmp" "'"$2"'" run || exit 1'
  _cs_rc=0
  docker run --rm --pull=never -v "$_cs_top:$_cs_top:ro" -v "$_cs_common:$_cs_common:ro" \
    -w "$_cs_top" "$1" bash -c "$_cs_inner" || _cs_rc=$?
  return "$_cs_rc"
}

echo '==> unit tests under bash 3.2 (optional; DL_BASH32 or docker image)'
bash32_skip() { echo "!!! SKIPPED bash 3.2 test run: $1" >&2; }
if [ "${DL_BASH32:-}" = off ]; then
  bash32_skip "DL_BASH32=off"
elif [ -n "${DL_BASH32:-}" ]; then
  shim="$gate_tmp/shim"; mkdir "$shim"   # outside the private TMPDIR, so not a "leak"
  v="$(bash32_shim "$DL_BASH32" "$invoked_from" "$shim")" || exit 1
  echo "    bash $v via DL_BASH32 ($(readlink "$shim/bash")), $(jq --version)"
  (PATH="$shim:$PATH"; export PATH; private_tmp_run "$gate_tmp" "unit tests under bash 3.2" run_tests) || exit 1
elif command -v docker >/dev/null 2>&1 \
     && docker image inspect "${DL_BASH32_IMAGE:-bash:3.2}" >/dev/null 2>&1; then
  rc=0
  container_suite "${DL_BASH32_IMAGE:-bash:3.2}" "unit tests under bash 3.2" '
    command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null 2>&1 || exit 77
    case "$(jq --version 2>/dev/null)" in jq-1.[67]*|jq-1.8.[01]) ;; *)
      apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/v3.21/main "jq<1.8" \
        >/dev/null 2>&1 || exit 77 ;;
    esac' || rc=$?
  case "$rc" in
    0) ;;
    77) bash32_skip "could not install git/jq in ${DL_BASH32_IMAGE:-bash:3.2} (no network?)" ;;
    *) echo "FAIL: unit tests under bash 3.2 (above)" >&2; exit 1 ;;
  esac
else
  bash32_skip "set DL_BASH32 to a bash 3.2 binary, or provide docker image ${DL_BASH32_IMAGE:-bash:3.2}"
fi

# The same suite under jq 1.6, the oldest jq the engine supports (lib/config.sh
# dl_jq_check), so 1.6-only breakage (keyword object shorthands such as
# {module}, contains on "\u0000", stderr's encoding; #79) can't hide behind the
# host's newer jq. Optional, never silent:
#   DL_JQ16=off   skip explicitly.
#   otherwise     use the local docker image DL_JQ16_IMAGE (default
#                 dl-bash32:jq16; never pulled, nothing installed in it): it
#                 must already carry bash, git and jq 1.6 (Alpine's 1.6 build
#                 reports "jq-master-…", so the apk package is checked too),
#                 else the gate FAILS. No docker / no image -> SKIPPED.
echo '==> unit tests under jq 1.6 (optional; docker image)'
jq16_skip() { echo "!!! SKIPPED jq 1.6 test run: $1" >&2; }
jq16_image="${DL_JQ16_IMAGE:-dl-bash32:jq16}"
if [ "${DL_JQ16:-}" = off ]; then
  jq16_skip "DL_JQ16=off"
elif command -v docker >/dev/null 2>&1 && docker image inspect "$jq16_image" >/dev/null 2>&1; then
  rc=0
  container_suite "$jq16_image" "unit tests under jq 1.6" '
    command -v git >/dev/null 2>&1 || { echo "FAIL: no git in the image" >&2; exit 78; }
    case "$(jq --version 2>/dev/null)" in
      jq-1.6*) ;;
      *) apk list --installed 2>/dev/null | grep -q "^jq-1\.6-" \
           || { echo "FAIL: the image'"'"'s jq is not 1.6: $(jq --version 2>&1)" >&2; exit 78; } ;;
    esac' || rc=$?
  case "$rc" in
    0) ;;
    *) echo "FAIL: unit tests under jq 1.6 in $jq16_image (above)" >&2; exit 1 ;;
  esac
else
  jq16_skip "provide docker image $jq16_image (bash + git + jq 1.6; DL_JQ16_IMAGE overrides)"
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
