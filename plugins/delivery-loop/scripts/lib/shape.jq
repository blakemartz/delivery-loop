# shape.jq — shared field predicates for the normalized-shape validators.
#
# Included (jq module) by node.jq (validate_node) and pr.jq (validate_pr) so the
# meaning of "an ISO-8601 timestamp", "a node id" and the exact-key check live in
# exactly one place. Pure: no I/O, no clock. See docs/delivery_graph_spec.md §4.

# ISO-8601 timestamp, RFC 3339 profile: extended-format date, `T`, time, optional
# fraction, then `Z` or a `±hh:mm` offset (github "…Z"; gitlab "….123Z"; gitea
# "…+01:00"). Deliberately strict:
#   - the basic-format offset `+0100` (what `date +%z` prints) is rejected:
#     ISO 8601 forbids mixing it with an extended-format date/time, and no forge
#     emits it;
#   - lowercase `t`/`z` are rejected: ISO 8601 designators are uppercase.
# Writers that mint timestamps themselves (the local store, claim `at`) emit UTC
# `date -u +%Y-%m-%dT%H:%M:%SZ`, which is also the only form jq's
# `fromdateiso8601` parses without normalization.
def is_iso8601:
  type == "string"
  and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");

def is_iso8601_or_null: . == null or is_iso8601;

def is_nonempty_string: type == "string" and length > 0;

def is_string_or_null: . == null or type == "string";

def is_bool: type == "boolean";

def is_int: type == "number" and . == floor;

def is_string_array: type == "array" and all(.[]; type == "string");

# Membership in a fixed set of JSON values.
def is_enum($vals): . as $v | any($vals[]; . == $v);

# A node id (§4.1): a github issue number as a string ("42") or a local slug.
# Both match the slug rule: ^[a-z0-9]+(-[a-z0-9]+)*$, at most 40 characters,
# which also excludes `--` (the worktree name separator). The rule is
# backend-agnostic, so it is a superset of each backend's ids (it admits "042",
# or a slug on github); it rejects "#42", so writers that accept the `#N` form
# (plan deps, §8.1) normalize to "42" before emitting a node or PR.
def is_node_id:
  type == "string" and length <= 40 and test("^[a-z0-9]+(-[a-z0-9]+)*$");

# Error strings for an object whose key set must equal $fields exactly. (The
# parameter is not named $keys: jq would bind `keys` to it, shadowing the builtin.)
def key_errors($fields):
  (($fields - keys)[] | "missing field `\(.)`"),
  ((keys - $fields)[] | "unexpected field `\(.)`");

# Error string when present field $name fails `cond` (absent fields are reported
# by key_errors, so they are skipped here).
def check($name; cond; $msg):
  if has($name) and (.[$name] | cond | not)
  then "`\($name)` \($msg) (got \(.[$name] | tojson))"
  else empty end;

# Fail fast: pass the input through unchanged, or raise one error naming every
# violation. $what is the shape's name plus an identifying key.
def raise_if_errors($what; $errors):
  if ($errors | length) == 0 then .
  else error("invalid \($what): \($errors | join("; "))") end;
