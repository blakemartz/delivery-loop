#!/usr/bin/env bash
# graph-local.sh <primitive> [args] — the local graph backend: the work graph as
# JSON files on this machine, no issue tracker (docs/delivery_graph_spec.md §6.1,
# §6.3). Behind graph.sh.
#
# Primitives (task C1; claim/release/comment/reconcile are task C2):
#   list                          every node (open and closed), one JSON array
#                                 of §4.1 nodes.
#   show <id>                     one node, one JSON object.
#   create <node-json>            store a new node; prints its id. Without an
#                                 `id`, assigns <epic-id>-<n> (inbox-<n> for a
#                                 node with no epic), n = 1 + the highest numeric
#                                 suffix in that epic (GC66). Epic nodes need an
#                                 explicit id: it names their file.
#   update <id> <patch-json>      shallow-merge the patch into the node.
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
# Stored nodes omit `pinged_at`: it is derived on read from the newest `comment`
# event whose body starts `STALE-CLAIM-PING` (§4.1, GC44). A schema other than 1
# is refused (expected vs found); there are no implicit migrations.
#
# Concurrency (§6.3): readers take no lock; every write replaces its file
# atomically (<file>.tmp.$$ in the same directory, then mv), so a reader always
# sees a whole file (GC23). Every mutation runs inside gl_with_lock, a `mkdir`
# lock (no flock: macOS lacks it) waited on for LOCK_WAIT_SECONDS (env only,
# default 30, then exit 75), with the serialized stale-lock break of §6.3 (GC22).
# The journal has no `update` op, so update and flag journal as `transition`
# (from/to = the node's status before/after; body = the patch).
#
# Exit codes: 0 ok · 1 failed (unknown node, invalid input or node, schema
# mismatch) · 2 usage · 75 lock not acquired within LOCK_WAIT_SECONDS.
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

gl_is_id() {
  [ "${#1}" -le 40 ] && printf '%s' "$1" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'
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

gl_scratch() {
  [ -n "$GL_TMP" ] || GL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dl-graph-local.XXXXXX")"
}

gl_cleanup() {
  gl_lock_release
  [ -z "$GL_TMP" ] || rm -rf "$GL_TMP"
}

# gl_write <target>: stdin -> <target>.tmp.$$ in the same directory, then mv.
gl_write() {
  local tmp="$1.tmp.$$"
  if cat > "$tmp"; then mv -f "$tmp" "$1"; else rm -f "$tmp"; gl_die "write failed: $1"; fi
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

gl_event() { # <op> <id> <from> <to> <body>; empty -> null
  mkdir -p "$GL_STATE"
  jq -nc --arg ts "$(gl_now)" --arg actor "$GL_ACTOR" --arg run "$GL_RUN" \
    --arg op "$1" --arg id "$2" --arg from "$3" --arg to "$4" --arg body "$5" '
    def n: if . == "" then null else . end;
    {ts: $ts, actor: $actor, run: ($run | n), op: $op, id: ($id | n),
     from: ($from | n), to: ($to | n), body: ($body | n)}' >> "$GL_EVENTS"
}

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
    rm -rf "$GL_LOCK"
    gl_event lock-broken "" "$judged" "" "stale lock broken (owner: $judged)"
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
  found=$(jq -r '.schema // "none" | tostring' "$GL_STORE" 2>/dev/null) \
    || gl_die "$GL_STORE does not parse"
  [ "$found" = "$GL_SCHEMA" ] \
    || gl_die "store schema mismatch in $GL_STORE: expected $GL_SCHEMA, found $found (no implicit migrations)"
}

# Under the lock: create the store on first write.
gl_ensure_store() {
  mkdir -p "$GL_EPICS"
  if [ ! -f "$GL_STORE" ]; then
    jq -n --argjson s "$GL_SCHEMA" --arg now "$(gl_now)" '{schema: $s, created_at: $now}' | gl_write "$GL_STORE"
  fi
  gl_check_store
  [ -f "$GL_EVENTS" ] || : > "$GL_EVENTS"
}

# Every stored node (pinged_at omitted), one JSON array: per epic file (name
# order) the epic node then its nodes, then a stable sort by created_at.
GL_READ='[ inputs
  | input_filename as $f
  | if (.schema // null) != $schema
    then error("epic file schema mismatch in \($f): expected \($schema), found \(.schema // "none" | tostring) (no implicit migrations)")
    else . end
  | (.epic // empty), .nodes[] ] | sort_by(.created_at)'

gl_stored() {
  [ -f "$GL_STORE" ] || { echo '[]'; return 0; }
  gl_check_store
  local files
  shopt -s nullglob
  files=("$GL_EPICS"/*.json)
  shopt -u nullglob
  if [ "${#files[@]}" -eq 0 ]; then echo '[]'; return 0; fi
  gl_scratch
  jq -n -c --argjson schema "$GL_SCHEMA" "$GL_READ" "${files[@]}" 2> "$GL_TMP/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; gl_die "cannot read the store at $GL_STATE"; }
}

# §4.1 nodes: stored nodes + pinged_at from the journal, fields in §4.1 order,
# each through validate_node. A torn journal line is skipped, never fatal.
GL_EMIT='include "node";
  ( $ev | split("\n") | map(select(length > 0) | (fromjson? // empty))
    | reduce (.[] | select(.op == "comment" and (.id | type) == "string"
                           and ((.body // "") | type) == "string"
                           and ((.body // "") | startswith("STALE-CLAIM-PING")))) as $e
        ({}; .[$e.id] = ([.[$e.id], $e.ts] | max)) ) as $pings
  | map(. + {pinged_at: ($pings[.id] // null)}
        | . as $n | reduce node_fields[] as $k ({}; .[$k] = $n[$k])
        | validate_node)'

gl_nodes() {
  gl_scratch
  gl_stored > "$GL_TMP/stored.json"
  local ev=/dev/null
  [ ! -f "$GL_EVENTS" ] || ev="$GL_EVENTS"
  gl_jq -c --rawfile ev "$ev" "$GL_EMIT" "$GL_TMP/stored.json" 2> "$GL_TMP/err" \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; gl_die "stored nodes fail validate_node (§4.1)"; }
}

# gl_file_of <stored-node-json>: the epic file that holds it.
gl_file_of() {
  local f
  f=$(jq -r 'if .kind == "epic" then .id else (.epic // "inbox") end' <<<"$1")
  printf '%s/%s.json' "$GL_EPICS" "$f"
}

# gl_put_node <node-json>: replace the stored node with the same id in its file.
gl_put_node() {
  local file
  file=$(gl_file_of "$1")
  [ -f "$file" ] || gl_die "missing epic file $file"
  jq --argjson n "$1" --argjson schema "$GL_SCHEMA" '
    if .schema != $schema then error("schema mismatch: expected \($schema), found \(.schema)")
    elif (.epic // {}).id == $n.id then .epic = $n
    else .nodes |= map(if .id == $n.id then $n else . end) end' "$file" | gl_write "$file"
}

# gl_validate <stored-node-json>: validate_node with the derived pinged_at.
gl_validate() {
  gl_scratch
  gl_jq -e 'include "node"; . + {pinged_at: null} | validate_node | true' <<<"$1" > /dev/null 2> "$GL_TMP/err" \
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
    then error("unexpected field(s) \($bad | join(", ")): created_at/updated_at are stamped and pinged_at is derived from the journal")
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
  local node id file
  gl_ensure_store
  gl_scratch
  gl_stored > "$GL_TMP/all.json"
  node=$(jq -c --slurpfile all "$GL_TMP/all.json" --arg now "$(gl_now)" --arg base "$BASE_BRANCH" \
    "$GL_CREATE" <<<"$1" 2> "$GL_TMP/err") \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; exit 1; }
  gl_validate "$node"
  id=$(jq -r .id <<<"$node")
  file=$(gl_file_of "$node")
  if [ "$(jq -r .kind <<<"$node")" = epic ]; then
    [ ! -e "$file" ] || gl_die "epic file $file already exists"
    jq -n --argjson n "$node" --argjson s "$GL_SCHEMA" '{schema: $s, epic: $n, nodes: []}' | gl_write "$file"
  elif [ -f "$file" ]; then
    jq --argjson n "$node" '.nodes += [$n]' "$file" | gl_write "$file"
  else
    jq -n --argjson n "$node" --argjson s "$GL_SCHEMA" '{schema: $s, epic: null, nodes: [$n]}' | gl_write "$file"
  fi
  gl_event create "$id" "" "$(jq -r .status <<<"$node")" "$(jq -r .title <<<"$node")"
  printf '%s\n' "$id"
}

op_create() {
  jq -e . >/dev/null 2>&1 <<<"$1" || gl_die "create: node-json does not parse"
  gl_with_lock gl_do_create "$1"
}

gl_do_update() {
  local old new
  gl_ensure_store
  old=$(gl_get "$1")
  gl_scratch
  new=$(jq -c --argjson p "$2" --arg now "$(gl_now)" '
    def fixed: ["id", "kind", "epic", "checklist", "created_at", "updated_at", "pinged_at"];
    def allowed: ["title", "module", "size", "deps", "status", "needs_human", "claim",
                  "target_branch", "promote_to", "plan_ref", "body"];
    if ($p | type) != "object" then error("patch-json must be a JSON object")
    elif (($p | keys) - allowed | length) > 0 then
      error("cannot patch \(($p | keys) - allowed | join(", ")) (patchable: \(allowed | join(", ")); \(fixed | join(", ")) are fixed, stamped or derived)")
    else . + ($p | if has("deps") and (.deps | type) == "array"
                   then .deps |= map(if type == "string" then {id: ., via: null} else . end)
                   else . end)
         | .updated_at = $now end' <<<"$old" 2> "$GL_TMP/err") \
    || { sed 's/^jq: error (at [^)]*): //' "$GL_TMP/err" >&2; exit 1; }
  gl_validate "$new"
  gl_put_node "$new"
  gl_event transition "$1" "$(jq -r .status <<<"$old")" "$(jq -r .status <<<"$new")" "$(jq -c . <<<"$2")"
}

op_update() {
  jq -e . >/dev/null 2>&1 <<<"$2" || gl_die "update: patch-json does not parse"
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
  gl_put_node "$new"
  gl_event link "$1" "" "$2" "$3"
}

op_link() {
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
  gl_put_node "$new"
  local st
  st=$(jq -r .status <<<"$new")
  gl_event transition "$1" "$st" "$st" "needs-human $3"
}

op_flag() {
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
