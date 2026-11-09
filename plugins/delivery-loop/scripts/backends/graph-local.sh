#!/usr/bin/env bash
# graph-local.sh <primitive> [args] — the local graph backend: the work graph as
# JSON files on this machine, no issue tracker (docs/delivery_graph_spec.md §6.1,
# §6.3). Behind graph.sh.
#
# Primitives (task C1; claim/release/comment/reconcile are task C2):
#   list                          every node (open and closed), one JSON array
#                                 of §4.1 nodes.
#   show <id>                     one node, one JSON object.
#   create <node-json>|-          store a new node (`-`: JSON on stdin, for
#                                 nodes past the argv limit); prints its id. Without an
#                                 `id`, assigns <epic-id>-<n> (inbox-<n> for a
#                                 node with no epic), n = 1 + the highest numeric
#                                 suffix in that epic (GC66). Epic nodes need an
#                                 explicit id: it names their file.
#   update <id> <patch-json>|-    shallow-merge the patch into the node.
#   link <id> <dep-id> [via]      add the blocking edge {id: dep-id, via}.
#   flag <id> needs-human on|off  set or clear needs_human.
#   unlock --force                operator cleanup: remove lock, lock.break and
#                                 lock.break.reap whatever their owners.
# Mutating primitives accept trailing `--actor <name>` / `--run <run>`, recorded
# in the lock owner line and the journal (actor defaults to the OS user).
#
# It stores; it does not decide (§3 rule 1): readiness, ordering, staleness and
# legality live in lib/*.jq, applied by graph.sh. Every node it writes or emits
# passes validate_node (lib/node.jq). It never stores an `external` node (§4.1).
#
# Store (§6.3), under STATE_DIR (empty -> <git-common-dir>/delivery, so every
# worktree of a clone shares it, GC27; `--path-format` needs git >= 2.31):
#   store.json            {"schema":1,"created_at":…}
#   epics/<epic-id>.json  {"schema":1,"epic":<node>,"nodes":[<task|promote nodes>]}
#   epics/inbox.json      {"schema":1,"epic":null,"nodes":[…]}: nodes with no epic
#   events.jsonl          append-only journal {ts,actor,run,op,id,from,to,body}
#   lock/owner            present only while held: "host pid run epoch"
# Stored nodes omit `pinged_at` and `applied_prs`, derived on read from journal
# `comment` events: the newest whose body starts `STALE-CLAIM-PING` (§4.1,
# GC44), and the PR numbers of those starting `AUTO-CLOSE: PR #<n>` (GC72). A schema other than 1
# is refused (expected vs found); there are no implicit migrations.
#
# Concurrency (§6.3): readers take no lock; every write replaces its file
# atomically (<file>.tmp.$$ in the same directory, mv'd only if its producer
# exited 0 with one JSON object), so a reader always sees a whole file (GC23);
# an empty or unparsable epic file is a loud read error, never "no nodes". A
# successful stale-lock break sweeps a dead writer's leftover *.tmp.* files.
# The journal reader skips (with a warning) any line that does not parse, and
# an append first repairs a torn tail with a newline. Every mutation runs inside gl_with_lock, a `mkdir`
# lock (no flock: macOS lacks it) waited on for LOCK_WAIT_SECONDS (env only,
# default 30, then exit 75), with the serialized stale-lock break of §6.3 (GC22).
# The journal has no `update` op, so update and flag journal as `transition`
# (from/to = the node's status before/after; body = the patch).
#
# Input: every node-json and patch-json must be exactly one JSON object
# (`{…}{…}` or `[…]` is refused before the lock, nothing written). Every id
# that names a file or is stored is a §4.1 slug (^[a-z0-9]+(-[a-z0-9]+)*$, at
# most 40 chars). update/link/flag fail unless they replace exactly one stored
# node. Each mutation builds and checks its journal line before it commits
# the epic file, so a failure leaves store and journal unchanged.
#
# Requires jq >= 1.6 (`--rawfile`; `--slurpfile` is 1.5): checked at startup.
#
# Exit codes: 0 ok · 1 failed (unknown node, invalid input or node, schema
# mismatch, jq too old) · 2 usage · 75 lock not acquired within LOCK_WAIT_SECONDS.
#
# Sourcing this file (tests) defines the gl_* functions without running a primitive.
set -euo pipefail

GL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GL_LIB="$GL_DIR/../lib"
# shellcheck source=../lib/config.sh
. "$GL_LIB/config.sh"

GL_SCHEMA=1
GL_ACTOR=""
GL_RUN=""
GL_TMP=""          # scratch dir (outside STATE_DIR), made on demand
GL_HELD=""         # owner line of the lock we hold
GL_HELD_BREAK=""   # owner line of the lock.break we hold
GL_HELD_REAP=""    # owner line of the lock.break.reap we hold
GL_BROKE=0         # set by gl_break_lock: 1 iff it removed the lock

gl_die()   { echo "graph-local: $*" >&2; exit 1; }
gl_usage() { echo "graph-local: usage: $*" >&2; exit 2; }
gl_now()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
gl_host()  { uname -n; }
gl_jq()    { jq -L "$GL_LIB" "$@"; }

# gl_is_id <s>: a §4.1 slug, ^[a-z0-9]+(-[a-z0-9]+)*$, at most 40 chars. Pure
# glob (no grep: grep matches per line, so "e<newline>e" would pass); the
# letters are spelled out so no locale's collation can widen a range.
gl_is_id() {
  [ -n "$1" ] && [ "${#1}" -le 40 ] || return 1
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789-]*|-*|*-|*--*) return 1 ;;
  esac
}

# gl_one_object <what> <json>: refuse anything but exactly one JSON object
# (`jq -e .` alone accepts `{…}{…}`, which would commit two nodes).
gl_one_object() {
  printf '%s' "$2" | jq -e -s 'length == 1 and (.[0] | type) == "object"' > /dev/null 2>&1 \
    || gl_die "$1 must be exactly one JSON object (got invalid JSON, several values, or a non-object): nothing written"
}

# gl_check_jq: jq >= 1.6 (`--rawfile`). Probed by feature, reported by version.
gl_check_jq() {
  command -v jq > /dev/null 2>&1 || gl_die "jq not found on PATH (the local backend needs jq >= 1.6)"
  jq -n --rawfile x /dev/null 'true' > /dev/null 2>&1 \
    || gl_die "jq >= 1.6 required (for --rawfile/--slurpfile); found $(jq --version 2>&1 || echo unknown)"
}

gl_resolve_state() {
  local common
  if [ -n "${STATE_DIR:-}" ]; then
    GL_STATE="$STATE_DIR"
  else
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
      || gl_die "STATE_DIR is empty and the current directory is not in a git repository"
    case "$common" in
      /*) : ;;
      *) gl_die "STATE_DIR is empty and \`git rev-parse --path-format=absolute\` failed: the local backend needs git >= 2.31" ;;
    esac
    GL_STATE="$common/delivery"
  fi
  GL_STORE="$GL_STATE/store.json"
  GL_EPICS="$GL_STATE/epics"
  GL_EVENTS="$GL_STATE/events.jsonl"
  GL_LOCK="$GL_STATE/lock"
  GL_BREAK="$GL_STATE/lock.break"
  GL_REAP="$GL_STATE/lock.break.reap"
  case "$LOCK_STALE_SECONDS" in ''|*[!0-9]*) gl_die "LOCK_STALE_SECONDS must be a non-negative integer (got '$LOCK_STALE_SECONDS')" ;; esac
  case "${LOCK_WAIT_SECONDS:-30}" in ''|*[!0-9]*) gl_die "LOCK_WAIT_SECONDS must be a non-negative integer (got '${LOCK_WAIT_SECONDS:-}')" ;; esac
}

# gl_scratch: the per-process scratch dir. gl_main calls it once, in the main
# shell, before dispatch, so the EXIT trap's gl_cleanup sees GL_TMP; a first
# call inside a $(…) or pipeline subshell would set GL_TMP only there and leak
# the dir. The lazy fallback is for callers that source this file (tests).
gl_scratch() {
  [ -n "$GL_TMP" ] || GL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-local.XXXXXX")"
}

gl_cleanup() {
  gl_lock_release
  [ -z "$GL_TMP" ] || rm -rf "$GL_TMP"
}

# gl_write_cmd <target> <cmd…>: run cmd with stdout -> <target>.tmp.$$ in the
# same directory; mv it over <target> only if cmd exited 0 and its output is
# exactly one JSON object. Otherwise the tmp is removed and <target> is left
# byte-identical (never pipe a producer into the committing write: a failed
# producer would commit an empty file).
gl_write_cmd() {
  local target="$1" tmp="$1.tmp.$$" rc=0
  shift
  "$@" > "$tmp" || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"; gl_die "write of $target aborted: its producer exited $rc ($target unchanged)"
  fi
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object"' "$tmp" > /dev/null 2>&1; then
    rm -f "$tmp"; gl_die "write of $target aborted: its producer did not emit exactly one JSON object ($target unchanged)"
  fi
  mv -f "$tmp" "$target"
}

# gl_json_file <name> <json>: write json to $GL_TMP/<name>.json and print the
# path, so jq reads it with --slurpfile instead of --argjson (no argv ceiling).
gl_json_file() {
  gl_scratch
  printf '%s\n' "$2" > "$GL_TMP/$1.json"
  printf '%s' "$GL_TMP/$1.json"
}

# gl_sweep_tmp: remove *.tmp.<pid> files a dead writer left between its tmp
# write and mv (GC23). Only call while no live process can be writing: under a
# held lock.break, before removing the dead holder's lock. Lock dirs' own
# owner.tmp files are not touched.
gl_sweep_tmp() {
  local f
  for f in "$GL_STATE"/*.tmp.* "$GL_EPICS"/*.tmp.*; do
    [ ! -f "$f" ] || rm -f "$f"
  done
}

# --- lock (§6.3) -------------------------------------------------------------

gl_owner_line() { printf '%s %s %s %s' "$(gl_host)" "$$" "${GL_RUN:--}" "$(date +%s)"; }

gl_read_owner() { cat "$1/owner" 2>/dev/null || true; }

# gl_put_owner <dir> <line>: the owner file appears whole (tmp + mv).
gl_put_owner() { printf '%s\n' "$2" > "$1/owner.tmp.$$" && mv -f "$1/owner.tmp.$$" "$1/owner"; }

# gl_release_dir <dir> <line>: remove a lock dir we hold. An owner-less dir is
# ours too (we died between mkdir and the owner write); nobody else's.
gl_release_dir() {
  local cur
  cur=$(gl_read_owner "$1")
  if [ "$cur" = "$2" ] || [ -z "$cur" ]; then rm -rf "$1"; fi
}

# gl_pid_dead <pid>: kill -0 fails with ESRCH. EPERM (another user's live
# process) or anything else means alive.
gl_pid_dead() {
  local msg
  if msg=$(LC_ALL=C; export LC_ALL; kill -0 "$1" 2>&1); then return 1; fi
  case "$msg" in *"No such process"*) return 0 ;; *) return 1 ;; esac
}

# gl_line_stale <owner-line>: this host, a dead pid, and an owner epoch older
# than LOCK_STALE_SECONDS. A malformed or empty line is live.
gl_line_stale() {
  local host pid run epoch extra
  read -r host pid run epoch extra <<EOF
$1
EOF
  [ -n "$epoch" ] && [ -z "$extra" ] || return 1
  case "$pid$epoch" in *[!0-9]*) return 1 ;; esac
  [ "$host" = "$(gl_host)" ] || return 1
  gl_pid_dead "$pid" || return 1
  [ $(( $(date +%s) - epoch )) -gt "$LOCK_STALE_SECONDS" ]
}

# gl_event_build <op> <id> <from> <to> <body>: build one journal line (empty
# -> null) into $GL_TMP/ev-line and check it is exactly one JSON object on one
# line. Mutations call it BEFORE committing their epic file, so a failed build
# leaves everything unchanged (a retried id-less create cannot duplicate).
# The body goes through a file: no argv ceiling.
gl_event_build() {
  gl_scratch
  printf '%s' "$5" > "$GL_TMP/ev-body"
  jq -nc --arg ts "$(gl_now)" --arg actor "$GL_ACTOR" --arg run "$GL_RUN" \
    --arg op "$1" --arg id "$2" --arg from "$3" --arg to "$4" --rawfile body "$GL_TMP/ev-body" '
    def n: if . == "" then null else . end;
    {ts: $ts, actor: $actor, run: ($run | n), op: $op, id: ($id | n),
     from: ($from | n), to: ($to | n), body: ($body | n)}' > "$GL_TMP/ev-line" \
    || gl_die "cannot build the $1 journal event for '${2:-}' (nothing written)"
  if [ "$(wc -l < "$GL_TMP/ev-line")" -ne 1 ] \
     || ! jq -e -s 'length == 1 and (.[0] | type) == "object"' "$GL_TMP/ev-line" > /dev/null 2>&1; then
    gl_die "the $1 journal event for '${2:-}' is not one JSON object on one line (nothing written)"
  fi
}

# gl_event_append: append the line gl_event_build made. Called with the lock
# held (or, for lock-broken, with lock.break held while the dead holder's lock
# still exists), so no other appender runs concurrently. If the journal's last
# byte is not a newline (a torn tail: a crash mid-append, or NUL padding after
# a power loss), a newline is written first so the tail cannot swallow this
# event. `wc -l` counts only \n bytes; $(tail -c 1) would drop a NUL.
gl_event_append() {
  mkdir -p "$GL_STATE"
  if [ -s "$GL_EVENTS" ] && [ "$(tail -c 1 "$GL_EVENTS" | wc -l)" -eq 0 ]; then
    printf '\n' >> "$GL_EVENTS"
  fi
  cat "$GL_TMP/ev-line" >> "$GL_EVENTS"
}

# gl_event <op> <id> <from> <to> <body>: build and append (no commit between).
gl_event() { gl_event_build "$@"; gl_event_append; }

# gl_reap_break <judged-line>: remove a stale lock.break, itself serialized by
# lock.break.reap and re-checked against the same owner line.
gl_reap_break() {
  mkdir "$GL_REAP" 2>/dev/null || return 0
  GL_HELD_REAP=$(gl_owner_line)
  gl_put_owner "$GL_REAP" "$GL_HELD_REAP"
  local cur
  cur=$(gl_read_owner "$GL_BREAK")
  if [ "$cur" = "$1" ] && gl_line_stale "$cur"; then rm -rf "$GL_BREAK"; fi
  gl_release_dir "$GL_REAP" "$GL_HELD_REAP"
  GL_HELD_REAP=""
}

# gl_break_lock <judged-line>: break the lock judged stale under that owner
# line, serialized by lock.break, so two concurrent breakers can never delete a
# lock a third process acquired in between (GC22). Sets GL_BROKE.
gl_break_lock() {
  local judged="$1" cur
  GL_BROKE=0
  if ! mkdir "$GL_BREAK" 2>/dev/null; then
    cur=$(gl_read_owner "$GL_BREAK")
    if [ -n "$cur" ] && gl_line_stale "$cur"; then gl_reap_break "$cur"; fi
    return 0
  fi
  GL_HELD_BREAK=$(gl_owner_line)
  gl_put_owner "$GL_BREAK" "$GL_HELD_BREAK"
  cur=$(gl_read_owner "$GL_LOCK")
  if [ "$cur" = "$judged" ] && gl_line_stale "$cur"; then
    # While the dead holder's lock still exists nobody else can write: journal
    # the break and sweep its stray tmp files first, then remove the lock.
    gl_event lock-broken "" "$judged" "" "stale lock broken (owner: $judged)"
    gl_sweep_tmp
    rm -rf "$GL_LOCK"
    GL_BROKE=1
  fi
  gl_release_dir "$GL_BREAK" "$GL_HELD_BREAK"
  GL_HELD_BREAK=""
}

gl_lock_acquire() {
  local wait="${LOCK_WAIT_SECONDS:-30}" start line i=0 delay
  start=$(date +%s)
  mkdir -p "$GL_STATE"
  while :; do
    if mkdir "$GL_LOCK" 2>/dev/null; then
      GL_HELD=$(gl_owner_line)
      gl_put_owner "$GL_LOCK" "$GL_HELD"
      return 0
    fi
    line=$(gl_read_owner "$GL_LOCK")
    if [ -n "$line" ] && gl_line_stale "$line"; then
      gl_break_lock "$line"
      [ "$GL_BROKE" = 0 ] || continue
    fi
    if [ $(( $(date +%s) - start )) -ge "$wait" ]; then
      echo "graph-local: lock not acquired within ${wait}s (LOCK_WAIT_SECONDS): $GL_LOCK held by '${line:-<no owner file; treated as live>}'" >&2
      echo "graph-local: if no process holds it (e.g. a dead holder whose pid was reused, or an owner-less lock), run: graph-local.sh unlock --force" >&2
      if [ -d "$GL_REAP" ]; then
        echo "graph-local: $GL_REAP exists (a crashed reap); after checking no process holds it, run: graph-local.sh unlock --force" >&2
      fi
      exit 75
    fi
    # backoff: 50ms doubling to a 500ms cap
    case "$i" in 0) delay=0.05 ;; 1) delay=0.1 ;; 2) delay=0.2 ;; 3) delay=0.4 ;; *) delay=0.5 ;; esac
    i=$((i + 1))
    sleep "$delay"
  done
}

gl_lock_release() {
  if [ -n "$GL_HELD_REAP" ]; then gl_release_dir "$GL_REAP" "$GL_HELD_REAP"; GL_HELD_REAP=""; fi
  if [ -n "$GL_HELD_BREAK" ]; then gl_release_dir "$GL_BREAK" "$GL_HELD_BREAK"; GL_HELD_BREAK=""; fi
  if [ -n "$GL_HELD" ]; then gl_release_dir "$GL_LOCK" "$GL_HELD"; GL_HELD=""; fi
}

# gl_with_lock <cmd…>: run cmd holding the lock; the EXIT trap releases it on
# every path (set -e failure, gl_die, signal).
gl_with_lock() {
  trap gl_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  gl_lock_acquire
  "$@"
  gl_lock_release
}

# --- store -------------------------------------------------------------------

gl_check_store() {
  local found
  [ -s "$GL_STORE" ] || gl_die "$GL_STORE is empty (expected one JSON object): refusing to use the store"
  found=$(jq -r '.schema // "none" | tostring' "$GL_STORE" 2>/dev/null) \
    || gl_die "$GL_STORE does not parse"
  [ -n "$found" ] || gl_die "$GL_STORE holds no JSON value: refusing to use the store"
  [ "$found" = "$GL_SCHEMA" ] \
    || gl_die "store schema mismatch in $GL_STORE: expected $GL_SCHEMA, found $found (no implicit migrations)"
}

# gl_orphan_epics: die if store.json is missing while epic files exist (a lost
# or deleted store.json must not read as an empty graph, nor be recreated).
gl_orphan_epics() {
  local files
  shopt -s nullglob
  files=("$GL_EPICS"/*.json)
  shopt -u nullglob
  [ "${#files[@]}" -eq 0 ] \
    || gl_die "$GL_STORE is missing but ${#files[@]} epic file(s) exist under $GL_EPICS: refusing to treat the store as empty (restore store.json)"
}

# Under the lock: create the store on first write.
gl_ensure_store() {
  mkdir -p "$GL_EPICS"
  if [ ! -f "$GL_STORE" ]; then
    gl_orphan_epics
    gl_write_cmd "$GL_STORE" jq -n --argjson s "$GL_SCHEMA" --arg now "$(gl_now)" '{schema: $s, created_at: $now}'
  fi
  gl_check_store
  [ -f "$GL_EVENTS" ] || : > "$GL_EVENTS"
}

# Every stored node (pinged_at/applied_prs omitted), one JSON array: per epic file (name
# order) the epic node then its nodes, then a stable sort by created_at. Each
# epic file must hold exactly one JSON object: an empty or multi-value file is
# an error, never "no nodes" (gl_stored rejects empty files by name first).
GL_READ='reduce inputs as $d ({}; .[input_filename] += [$d])
  | if length != $nfiles
    then error("\($nfiles - length) epic file(s) hold no JSON value (expected one object each)")
    else . end
  | [ to_entries[] | .key as $f | .value
      | if length != 1 or (.[0] | type) != "object"
        then error("epic file \($f): expected exactly one JSON object, found \(length) value(s)")
        else .[0] end
      | if (.schema // null) != $schema
        then error("epic file schema mismatch in \($f): expected \($schema), found \(.schema // "none" | tostring) (no implicit migrations)")
        elif (.nodes | type) != "array"
        then error("epic file \($f): `nodes` is not an array")
        else . end
      | (.epic // empty), .nodes[] ] | sort_by(.created_at)'

gl_stored() {
  [ -f "$GL_STORE" ] || { gl_orphan_epics; echo '[]'; return 0; }
  gl_check_store
  local files f
  shopt -s nullglob
  files=("$GL_EPICS"/*.json)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then echo '[]'; return 0; fi
  for f in "${files[@]}"; do
    [ -s "$f" ] || gl_die "epic file $f is empty (expected one JSON object; a failed write?): refusing to read the store at $GL_STATE"
  done
  gl_scratch
  jq -n -c --argjson schema "$GL_SCHEMA" --argjson nfiles "${#files[@]}" "$GL_READ" "${files[@]}" 2> "$GL_TMP/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; gl_die "cannot read the store at $GL_STATE"; }
}

# §4.1 nodes: stored nodes + pinged_at and applied_prs from the journal, fields
# in §4.1 order, each through validate_node, given $ev = the parsed journal
# events. applied_prs: per id, the ascending unique PR numbers > 0 that directly
# follow `AUTO-CLOSE: PR #` in a `comment` body (the gh_applied_prs parse).
GL_EMIT='include "node";
  def applied_prs:
    reduce (.[] | select(.op == "comment" and (.id | type) == "string"
                         and (.body | type) == "string"
                         and (.body | startswith("AUTO-CLOSE: PR #")))
              | .id as $id | .body | ltrimstr("AUTO-CLOSE: PR #")
              | first(match("[0-9]+")) | select(.offset == 0)
              | .string | tonumber | select(. > 0) | [$id, .]) as $p
      ({}; .[$p[0]] = (.[$p[0]] + [$p[1]] | unique));
  ($ev[0] | applied_prs) as $applied
  | ( $ev[0]
    | reduce (.[] | select(.op == "comment" and (.id | type) == "string"
                           and (.body | type) == "string"
                           and (.body | startswith("STALE-CLAIM-PING")))) as $e
        ({}; .[$e.id] = ([.[$e.id], $e.ts] | max)) ) as $pings
  | map(. + {pinged_at: ($pings[.id] // null), applied_prs: ($applied[.id] // [])}
        | . as $n | reduce node_fields[] as $k ({}; .[$k] = $n[$k])
        | validate_node)'

# The journal, one line per event: {bad: [line numbers], ev: [events]}. A line
# that is not one JSON object, or holds a NUL byte (a torn tail, a crash
# mid-append, NUL padding), is skipped on its own, so it can never hide the
# events after it.
GL_JOURNAL='[inputs] | to_entries | map(select(.value | test("\\S")))
  | map(.n = .key + 1
        | .e = (if .value | contains("\u0000") then null
                else .value | try fromjson catch null end))
  | {bad: map(select((.e | type) != "object") | .n),
     ev:  map(select((.e | type) == "object") | .e)}'

# gl_journal <out-file>: the parsed events array; warns on skipped lines.
gl_journal() {
  if [ ! -s "$GL_EVENTS" ]; then echo '[]' > "$1"; return 0; fi
  jq -n -R -c "$GL_JOURNAL" "$GL_EVENTS" > "$GL_TMP/journal.json" 2> "$GL_TMP/err" \
    || { cat "$GL_TMP/err" >&2; gl_die "cannot read the journal $GL_EVENTS"; }
  local bad
  bad=$(jq -r '.bad | if length == 0 then "" else "\(length) line(s): \(.[:10] | map(tostring) | join(", "))\(if length > 10 then ", …" else "" end)" end' "$GL_TMP/journal.json")
  [ -z "$bad" ] || echo "graph-local: warning: skipping unparsable journal $bad in $GL_EVENTS" >&2
  jq -c .ev "$GL_TMP/journal.json" > "$1"
}

gl_nodes() {
  gl_scratch
  gl_stored > "$GL_TMP/stored.json"
  gl_journal "$GL_TMP/events.json"
  gl_jq -c --slurpfile ev "$GL_TMP/events.json" "$GL_EMIT" "$GL_TMP/stored.json" 2> "$GL_TMP/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; gl_die "stored nodes fail validate_node (§4.1)"; }
}

# gl_file_of <stored-node-json>: the epic file that holds it. The name must be
# a slug, so no input can make an unsafe or multi-line filename.
gl_file_of() {
  local f
  f=$(jq -r 'if .kind == "epic" then .id else (.epic // "inbox") end' <<<"$1")
  gl_is_id "$f" || gl_die "refusing epic file name '$f': not a §4.1 slug"
  printf '%s/%s.json' "$GL_EPICS" "$f"
}

# gl_put_node <node-json>: replace the stored node with the same id in its
# file. Fails (file unchanged) unless exactly one node, or the epic header,
# carries that id: a no-op replace never returns 0.
gl_put_node() {
  local file
  file=$(gl_file_of "$1")
  [ -f "$file" ] || gl_die "missing epic file $file"
  gl_write_cmd "$file" jq --slurpfile n "$(gl_json_file node "$1")" --argjson schema "$GL_SCHEMA" '
    $n[0] as $n
    | ([.nodes[] | select(.id == $n.id)] | length) as $hits
    | if .schema != $schema then error("schema mismatch: expected \($schema), found \(.schema)")
      elif (.epic // {}).id == $n.id and $hits == 0 then .epic = $n
      elif $hits == 1 and (.epic // {}).id != $n.id then .nodes |= map(if .id == $n.id then $n else . end)
      else error("node \($n.id | tojson) is stored \($hits + (if (.epic // {}).id == $n.id then 1 else 0 end)) time(s) in this file (expected exactly 1): nothing replaced") end' "$file"
}

# gl_validate <stored-node-json>: validate_node with the derived fields stubbed.
gl_validate() {
  gl_scratch
  gl_jq -e 'include "node"; . + {pinged_at: null, applied_prs: []} | validate_node | true' <<<"$1" > /dev/null 2> "$GL_TMP/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; gl_die "refusing to store an invalid node"; }
}

# gl_get <id>: the stored node, or exit 1.
gl_get() {
  gl_is_id "$1" || gl_die "not a node id: '$1'"
  local n
  n=$(gl_stored | jq -c --arg id "$1" 'map(select(.id == $id)) | first // empty')
  [ -n "$n" ] || gl_die "no node '$1' in $GL_STATE"
  printf '%s\n' "$n"
}

# --- primitives ----------------------------------------------------------------

op_list() { gl_nodes; }

op_show() {
  gl_is_id "$1" || gl_usage "show <id> (a slug: ^[a-z0-9]+(-[a-z0-9]+)*\$, at most 40 chars)"
  local n
  n=$(gl_nodes | jq -c --arg id "$1" 'map(select(.id == $id)) | first // empty')
  [ -n "$n" ] || gl_die "no node '$1' in $GL_STATE"
  printf '%s\n' "$n"
}

GL_CREATE='
  def allowed: ["id", "kind", "title", "epic", "checklist", "module", "size", "deps",
                "status", "needs_human", "claim", "target_branch", "promote_to",
                "plan_ref", "body"];
  def deps_norm: map(if type == "string" then {id: ., via: null} else . end);
  def home: if .kind == "epic" then .id else (.epic // "inbox") end;
  ($all[0]) as $all
  | if type != "object" then error("node-json must be a JSON object") else . end
  | (keys - allowed) as $bad
  | if ($bad | length) > 0
    then error("unexpected field(s) \($bad | join(", ")): created_at/updated_at are stamped and pinged_at/applied_prs are derived from the journal")
    else . end
  | if (.kind | type) != "string" then error("`kind` is required (task|epic|promote)")
    elif .kind == "external" then error("the local backend never stores external nodes (§4.1)")
    elif (.title | type) != "string" or .title == "" then error("`title` is required")
    elif ((.checklist // []) | length) > 0 then error("`checklist` is github-only; local children come from `epic`")
    elif .kind == "epic" and .epic != null then error("an epic node has no parent epic (`epic` must be null)")
    elif .kind == "epic" and .id == null then error("an epic node needs an explicit `id` (it names epics/<id>.json)")
    else . end
  | . as $in
  | ($in.epic // null) as $epic
  | if $epic != null and ([$all[] | select(.id == $epic and .kind == "epic")] | length) == 0
    then error("unknown epic \($epic | tojson): create the epic node first") else . end
  | (if $in.id != null then $in.id
     else (if $epic == null then "inbox" else $epic end) as $p
       | ([$all[] | select(home == $p and .kind != "epic") | .id
           | capture("^" + $p + "-(?<n>[0-9]+)$") | .n | tonumber] | max // 0) as $hi
       | [$all[].id] as $ids
       | ($hi + 1) | until(("\($p)-\(.)") as $c | ($ids | index($c)) == null; . + 1)
       | "\($p)-\(.)" end) as $id
  | if ($id | type) != "string" then error("`id` must be a string")
    elif $id == "inbox" then error("id \"inbox\" is reserved (epics/inbox.json)")
    elif any($all[]; .id == $id) then error("id \($id | tojson) already exists")
    else . end
  | {id: $id, kind: $in.kind, title: $in.title, epic: $epic, checklist: [],
     module: ($in.module // null), size: ($in.size // null),
     deps: (($in.deps // []) | if type == "array" then deps_norm else . end),
     status: ($in.status // "ready"), needs_human: ($in.needs_human // false),
     claim: ($in.claim // null), target_branch: ($in.target_branch // $base),
     promote_to: ($in.promote_to // null), plan_ref: ($in.plan_ref // null),
     body: ($in.body // ""), created_at: $now, updated_at: $now}'

gl_do_create() {
  local node id file nf
  gl_ensure_store
  gl_scratch
  gl_stored > "$GL_TMP/all.json"
  node=$(jq -c --slurpfile all "$GL_TMP/all.json" --arg now "$(gl_now)" --arg base "$BASE_BRANCH" \
    "$GL_CREATE" <<<"$1" 2> "$GL_TMP/err") \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; exit 1; }
  gl_one_object "create: the built node" "$node"
  gl_validate "$node"
  id=$(jq -r .id <<<"$node")
  gl_is_id "$id" || gl_die "create: id '$id' is not a §4.1 slug"
  file=$(gl_file_of "$node")
  nf=$(gl_json_file node "$node")
  gl_event_build create "$id" "" "$(jq -r .status <<<"$node")" "$(jq -r .title <<<"$node")"
  if [ "$(jq -r .kind <<<"$node")" = epic ]; then
    [ ! -e "$file" ] || gl_die "epic file $file already exists"
    gl_write_cmd "$file" jq -n --slurpfile n "$nf" --argjson s "$GL_SCHEMA" '{schema: $s, epic: $n[0], nodes: []}'
  elif [ -f "$file" ]; then
    gl_write_cmd "$file" jq --slurpfile n "$nf" '.nodes += $n' "$file"
  else
    gl_write_cmd "$file" jq -n --slurpfile n "$nf" --argjson s "$GL_SCHEMA" '{schema: $s, epic: null, nodes: $n}'
  fi
  gl_event_append
  printf '%s\n' "$id"
}

op_create() {
  [ "$1" != - ] || set -- "$(cat)"
  gl_one_object "create: node-json" "$1"
  gl_with_lock gl_do_create "$1"
}

gl_do_update() {
  local old new
  gl_ensure_store
  old=$(gl_get "$1")
  gl_scratch
  new=$(jq -c --slurpfile p "$(gl_json_file patch "$2")" --arg now "$(gl_now)" '
    def fixed: ["id", "kind", "epic", "checklist", "created_at", "updated_at", "pinged_at", "applied_prs"];
    def allowed: ["title", "module", "size", "deps", "status", "needs_human", "claim",
                  "target_branch", "promote_to", "plan_ref", "body"];
    $p[0] as $p
    | if ($p | type) != "object" then error("patch-json must be a JSON object")
    elif (($p | keys) - allowed | length) > 0 then
      error("cannot patch \(($p | keys) - allowed | join(", ")) (patchable: \(allowed | join(", ")); \(fixed | join(", ")) are fixed, stamped or derived)")
    else . + ($p | if has("deps") and (.deps | type) == "array"
                   then .deps |= map(if type == "string" then {id: ., via: null} else . end)
                   else . end)
         | .updated_at = $now end' <<<"$old" 2> "$GL_TMP/err") \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; exit 1; }
  gl_validate "$new"
  gl_event_build transition "$1" "$(jq -r .status <<<"$old")" "$(jq -r .status <<<"$new")" "$(jq -c . <<<"$2")"
  gl_put_node "$new"
  gl_event_append
}

op_update() {
  [ "$2" != - ] || set -- "$1" "$(cat)"
  gl_is_id "$1" || gl_die "update: not a node id: '$1'"
  gl_one_object "update: patch-json" "$2"
  gl_with_lock gl_do_update "$1" "$2"
}

gl_do_link() {
  local old new
  gl_ensure_store
  old=$(gl_get "$1")
  new=$(jq -c --arg d "$2" --arg via "$3" --argjson hasvia "$4" --arg now "$(gl_now)" '
    (if $hasvia then $via else null end) as $v
    | if any(.deps[]; .id == $d)
      then if $hasvia then .deps |= map(if .id == $d then .via = $v else . end) else . end
      else .deps += [{id: $d, via: $v}] end' <<<"$old")
  [ "$(jq -c 'del(.updated_at)' <<<"$new")" != "$(jq -c 'del(.updated_at)' <<<"$old")" ] || return 0
  new=$(jq -c --arg now "$(gl_now)" '.updated_at = $now' <<<"$new")
  gl_validate "$new"
  gl_event_build link "$1" "" "$2" "$3"
  gl_put_node "$new"
  gl_event_append
}

op_link() {
  gl_is_id "$1" || gl_die "link: not a node id: '$1'"
  gl_is_id "$2" || gl_die "link: not a node id: '$2'"
  [ "$1" != "$2" ] || gl_die "link: a node cannot block itself ('$1')"
  local hasvia=false
  [ $# -lt 3 ] || hasvia=true
  gl_with_lock gl_do_link "$1" "$2" "${3:-}" "$hasvia"
}

gl_do_flag() {
  local old new
  gl_ensure_store
  old=$(gl_get "$1")
  [ "$(jq -r .needs_human <<<"$old")" != "$2" ] || return 0
  new=$(jq -c --argjson on "$2" --arg now "$(gl_now)" '.needs_human = $on | .updated_at = $now' <<<"$old")
  gl_validate "$new"
  local st
  st=$(jq -r .status <<<"$new")
  gl_event_build transition "$1" "$st" "$st" "needs-human $3"
  gl_put_node "$new"
  gl_event_append
}

op_flag() {
  gl_is_id "$1" || gl_die "flag: not a node id: '$1'"
  [ "$2" = needs-human ] || gl_usage "flag <id> needs-human on|off"
  case "$3" in
    on) gl_with_lock gl_do_flag "$1" true on ;;
    off) gl_with_lock gl_do_flag "$1" false off ;;
    *) gl_usage "flag <id> needs-human on|off" ;;
  esac
}

op_unlock() {
  [ "${1:-}" = --force ] || gl_usage "unlock --force"
  local d had=""
  for d in "$GL_REAP" "$GL_BREAK" "$GL_LOCK"; do
    if [ -e "$d" ]; then had="$had $(basename "$d")=[$(gl_read_owner "$d")]"; rm -rf "$d"; fi
  done
  if [ -n "$had" ]; then
    gl_sweep_tmp
    gl_event lock-broken "" "" "" "unlock --force:$had"
    echo "graph-local: removed$had" >&2
  fi
}

gl_main() {
  local op="${1:-}"
  [ $# -eq 0 ] || shift
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --actor) [ $# -ge 2 ] || gl_usage "--actor <name>"; GL_ACTOR="$2"; shift 2 ;;
      --run)   [ $# -ge 2 ] || gl_usage "--run <run>"; GL_RUN="$2"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  [ -n "$GL_ACTOR" ] || GL_ACTOR="$(id -un 2>/dev/null || echo unknown)"
  # The owner line is space-separated: no whitespace inside its run field.
  GL_RUN=$(printf '%s' "$GL_RUN" | tr -s ' \t\n' '___')
  set -- ${args[@]+"${args[@]}"}
  trap gl_cleanup EXIT
  gl_scratch   # once, here in the main shell, so the EXIT trap removes it
  gl_check_jq
  gl_resolve_state
  case "$op" in
    list)   [ $# -eq 0 ] || gl_usage "list"; op_list ;;
    show)   [ $# -eq 1 ] || gl_usage "show <id>"; op_show "$1" ;;
    create) [ $# -eq 1 ] || gl_usage "create <node-json>"; op_create "$1" ;;
    update) [ $# -eq 2 ] || gl_usage "update <id> <patch-json>"; op_update "$1" "$2" ;;
    link)   { [ $# -eq 2 ] || [ $# -eq 3 ]; } || gl_usage "link <id> <dep-id> [via]"; op_link "$@" ;;
    flag)   [ $# -eq 3 ] || gl_usage "flag <id> needs-human on|off"; op_flag "$@" ;;
    unlock) op_unlock "$@" ;;
    *) gl_usage "graph-local.sh list | show <id> | create <node-json> | update <id> <patch-json> | link <id> <dep-id> [via] | flag <id> needs-human on|off | unlock --force (docs/delivery_graph_spec.md §6.1, §6.3)" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then gl_main "$@"; fi
