# private-tmp.sh — run a test suite under a fresh private TMPDIR and fail if it
# leaves anything behind. Sourced by scripts/check.sh (host run, and inside the
# bash 3.2 container) and by its self-test scripts/tests/private-tmp-test.sh;
# not shipped (repo-root dogfood).
#
# Why: tests used to share the host TMPDIR, so leaked temp dirs (a dl-graph.*
# per local claim, dl-graph-local.* per graph-local-test run) piled up in /tmp
# for a whole release without the gate noticing (#70). Every script and test
# here creates scratch space with `mktemp -d "${TMPDIR:-/tmp}/…"`, so pointing
# TMPDIR at an empty dir and inspecting it afterwards catches every leak.
#
# Sourced: sets no shell options and no traps (the caller owns both). bash 3.2.

# private_tmp_leaks DIR LABEL — succeed iff DIR exists and is empty. Otherwise
# print FAIL to stderr naming LABEL and listing every leftover top-level entry.
private_tmp_leaks() {
  if [ ! -d "$1" ]; then
    echo "FAIL: $2: its private TMPDIR $1 is gone (something removed TMPDIR itself)" >&2
    return 1
  fi
  _pt_left="$(find "$1" -mindepth 1 -maxdepth 1 | sort)"
  [ -z "$_pt_left" ] && return 0
  echo "FAIL: $2 left temp files in its private TMPDIR (fix them at the source):" >&2
  printf '%s\n' "$_pt_left" | sed 's/^/    /' >&2
  return 1
}

# private_tmp_run PARENT LABEL CMD… — run CMD in a subshell with TMPDIR exported
# as a fresh empty dir under PARENT, then check it with private_tmp_leaks.
# Returns 1 if CMD fails (no leak check: the failure is already the verdict) or
# if it leaked; 0 otherwise. Removes the private dir before returning; the
# caller's EXIT trap on PARENT covers an interrupted run. CMD runs in a
# `||` context, so it must report failure by its exit status — `set -e` does
# not stop it midway.
private_tmp_run() {
  _pt_dir="$(mktemp -d "$1/dl-private-tmp.XXXXXX")" || {
    echo "FAIL: $2: could not create a private TMPDIR under $1" >&2
    return 1
  }
  _pt_label="$2"
  shift 2
  echo "    TMPDIR=$_pt_dir (private; must be empty afterwards)"
  _pt_rc=0
  (TMPDIR="$_pt_dir"; export TMPDIR; "$@") || _pt_rc=1
  if [ "$_pt_rc" -eq 0 ]; then
    private_tmp_leaks "$_pt_dir" "$_pt_label" || _pt_rc=1
  fi
  rm -rf "$_pt_dir"
  return "$_pt_rc"
}
