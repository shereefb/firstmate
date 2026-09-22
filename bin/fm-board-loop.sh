#!/usr/bin/env bash
# fm-board-loop.sh - one board-level detect -> investigate -> recover -> verify
# pass over the Operating Studio Linear board and the workers bound to it.
#
# Usage:
#   fm-board-loop.sh [scan] [--cards <file>] [--remote-inventory <file>]
#   fm-board-loop.sh inventory
#   fm-board-loop.sh recover [--cards <file>] [--remote-inventory <file>]
#   fm-board-loop.sh pause [--reason <text>]
#   fm-board-loop.sh resume --card <Linear-id-or-identifier>
#
# The command is the single owner of the board-loop classification and of the
# durable deployment ledger it reads and writes:
#   * `scan` (the default) is read-only apart from that ledger. It joins
#     canonical worker identity to canonical Linear card identity and emits one
#     stable machine-readable JSON object on stdout.
#   * `inventory` prints this home's compact worker inventory for a parent to
#     merge; it never enumerates a sibling home's panes.
#   * `recover` performs only bounded, untrusted-safe recovery: it steers an
#     owning worker through bin/fm-send.sh's durable inbox, or reports that the
#     cause must be escalated. It never issues a lifecycle action
#     (interrupt/exit/relaunch), never merges, and never mutates Linear. It
#     fails CLOSED by default. `resume --card` grants recovery to one card, and
#     `pause` revokes every grant. A live endpoint or status-log history is
#     never evidence that recovery is safe.
#     `scan` stays read-only and may run under the stop posture.
#
# Identity is authoritative and never inferred: a lane joins a card only by the
# immutable Linear issue id recorded as `linear_card_id=` in task metadata, and
# a PR is authoritative only through the task's recorded `pr=` URL and
# `pr_head=` sha. A title search is a fallback discovery hint at most; it is
# never performed here and never overrides a canonical binding.
#
# A lane is productive capacity only when its agent is live and working, its
# disposition is not terminal/done/parked/paused/blocked, its validation is not
# blocked or failed, and its card is still active. A pane, a stale status-log
# event, or a historical activity record is never productive coverage.
#
# Throughput health is the count of cards newly verified Ready to Deploy in the
# rolling prior hour, kept in a durable ledger beside the state directory. Zero
# landings while eligible work is active is an actionable end-to-end flow fault,
# not a healthy cycle.
#
# Linear, the forge, Herdr, and the crew-state reader are optional at the
# command boundary: an unavailable input is reported as explicit
# `unavailable`/`unknown` evidence, never guessed into a healthy verdict.
#
# Environment overrides (all optional):
#   FM_BOARD_LOOP_NOW                 fixed epoch for deterministic tests
#   FM_BOARD_LOOP_CREW_STATE_CMD      crew-state reader ("" disables the read)
#   FM_BOARD_LOOP_VALIDATION_TIMEOUT  per-lane crew-state probe bound, default 10s
#   FM_BOARD_LOOP_HERDR_CLI           herdr client `<cli> <session> agent get <pane>`
#   FM_BOARD_LOOP_ENDPOINT_STATUS_CMD `<cmd> <session:pane>` -> alive/dead/missing/...
#   FM_BOARD_LOOP_PR_PROBE_CMD        optional `<probe> <url>` override for the forge read
#   FM_BOARD_LOOP_SEND_CMD            bounded recovery steer command
#   FM_BOARD_LOOP_STALL_SECS          stall window for an unmoved disposition, default 1800
#   FM_BOARD_LOOP_PAUSE               set to 1 to force recovery closed
#   FM_BOARD_LOOP_REMOTE_INVENTORY    path to a remote inventory fixture
#   FM_LINEAR_CONFIG_FILE             narrow Linear env file (default .env.linear.local)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

MODE=scan
CARDS_FILE=
REMOTE_FILE=
PAUSE_REASON=
RESUME_CARD=
LINEAR_CONFIG_FILE=${FM_LINEAR_CONFIG_FILE:-$FM_HOME/.env.linear.local}
HISTORY="$STATE/.board-loop-deploy-history"
STALL_LEDGER="$STATE/.board-loop-stall.tsv"
RECOVERY_LEDGER="$STATE/.board-loop-recovery.jsonl"
PAUSE_MARKER="$STATE/.board-loop-pause"
RESUME_DIR="$STATE/.board-loop-resume"
INVENTORY_SCHEMA='fm-board-inventory.v1'
REPORT_SCHEMA='fm-board-loop.v1'
DEPLOY_WINDOW_SECS=3600
REMOTE_MAX_AGE_SECS=${FM_BOARD_LOOP_REMOTE_MAX_AGE_SECS:-1800}
case "$REMOTE_MAX_AGE_SECS" in
  ''|*[!0-9]*|0) REMOTE_MAX_AGE_SECS=1800 ;;
esac
STALL_SECS_DEFAULT=1800
RECOVERY_RETRY_SECS=900
RECOVERY_MAX_ATTEMPTS=3
case "${FM_BOARD_LOOP_STALL_SECS:-}" in
  ''|*[!0-9]*) STALL_SECS=$STALL_SECS_DEFAULT ;;
  *) STALL_SECS=$FM_BOARD_LOOP_STALL_SECS ;;
esac

usage() {
  cat <<'EOF'
usage: fm-board-loop.sh [scan] [--cards <file>] [--remote-inventory <file>]
       fm-board-loop.sh inventory
       fm-board-loop.sh recover [--cards <file>] [--remote-inventory <file>]
       fm-board-loop.sh pause [--reason <text>]
       fm-board-loop.sh resume --card <Linear-id-or-identifier>
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    scan) MODE=scan ;;
    inventory) MODE=inventory ;;
    recover) MODE=recover ;;
    pause) MODE=pause ;;
    resume) MODE=resume ;;
    --card)
      shift
      [ "$#" -gt 0 ] || { usage >&2; exit 2; }
      RESUME_CARD=$1
      ;;
    --card=*) RESUME_CARD=${1#--card=} ;;
    --reason)
      shift
      [ "$#" -gt 0 ] || { usage >&2; exit 2; }
      PAUSE_REASON=$1
      ;;
    --reason=*) PAUSE_REASON=${1#--reason=} ;;
    --cards)
      shift
      [ "$#" -gt 0 ] || { usage >&2; exit 2; }
      CARDS_FILE=$1
      ;;
    --cards=*) CARDS_FILE=${1#--cards=} ;;
    --remote-inventory)
      shift
      [ "$#" -gt 0 ] || { usage >&2; exit 2; }
      REMOTE_FILE=$1
      ;;
    --remote-inventory=*) REMOTE_FILE=${1#--remote-inventory=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

if ! command -v jq >/dev/null 2>&1; then
  echo 'fm-board-loop: jq is required' >&2
  exit 1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-board-loop.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
VALIDATION_MAP=
VALIDATION_TIMEOUT=${FM_BOARD_LOOP_VALIDATION_TIMEOUT:-10}
case "$VALIDATION_TIMEOUT" in ''|*[!0-9]*|0) VALIDATION_TIMEOUT=10 ;; esac

board_now() {
  case "${FM_BOARD_LOOP_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_BOARD_LOOP_NOW" ;;
  esac
}

NOW=$(board_now)

task_id_valid() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# --- pause guard -------------------------------------------------------------

board_loop_pause_reason() {
  [ -f "$PAUSE_MARKER" ] && [ ! -L "$PAUSE_MARKER" ] || { printf ''; return 0; }
  sed -n 's/^reason=//p' "$PAUSE_MARKER" 2>/dev/null | sed -n '/./{p;q;}'
}

board_loop_paused() {
  if [ -f "$PAUSE_MARKER" ] && [ ! -L "$PAUSE_MARKER" ]; then return 0; fi
  if [ "${FM_BOARD_LOOP_PAUSE:-}" = 1 ]; then return 0; fi
  [ -d "$RESUME_DIR" ] && [ ! -L "$RESUME_DIR" ] || return 0
  return 1
}

board_loop_card_resumed() { # <card-id> <identifier>
  local card=$1 identifier=$2 grant
  board_loop_paused && return 1
  for grant in "$card" "$identifier"; do
    case "$grant" in ''|.*|*/*|*[!A-Za-z0-9._-]*) continue ;; esac
    [ -f "$RESUME_DIR/$grant" ] && [ ! -L "$RESUME_DIR/$grant" ] && return 0
  done
  return 1
}

action_pause() {
  local tmp
  mkdir -p "$STATE" 2>/dev/null || true
  if [ -e "$RESUME_DIR" ] && { [ ! -d "$RESUME_DIR" ] || [ -L "$RESUME_DIR" ]; }; then
    printf 'fm-board-loop: unsafe resume ledger\n' >&2
    return 1
  fi
  tmp=$(umask 077; mktemp "$STATE/.board-loop-pause.XXXXXX") || return 1
  if printf 'since=%s\nreason=%s\n' "$NOW" "${PAUSE_REASON:-manual pause}" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f "$tmp" "$PAUSE_MARKER" \
    && { [ ! -d "$RESUME_DIR" ] || rm -f "$RESUME_DIR"/*; }; then
    printf 'paused: board recovery suspended (%s)\n' "${PAUSE_REASON:-manual pause}"
    return 0
  fi
  rm -f "$tmp"
  printf 'fm-board-loop: could not write the pause marker\n' >&2
  return 1
}

action_resume() {
  local tmp
  case "$RESUME_CARD" in ''|.*|*/*|*[!A-Za-z0-9._-]*)
    printf 'fm-board-loop: resume requires a safe --card value\n' >&2
    return 1
    ;;
  esac
  mkdir -p "$RESUME_DIR" || return 1
  [ ! -L "$RESUME_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$RESUME_DIR/.resume.XXXXXX") || return 1
  if printf 'since=%s\ncard=%s\n' "$NOW" "$RESUME_CARD" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f "$tmp" "$RESUME_DIR/$RESUME_CARD" \
    && rm -f "$PAUSE_MARKER"; then
    printf 'resumed: board recovery enabled for %s\n' "$RESUME_CARD"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# --- external input boundaries ------------------------------------------------

# crew_state_line is the authoritative task/run disposition, and an optional
# boundary: an unavailable reader yields an explicit unknown, never a guess.
crew_state_line() { # <task-id>
  local id=$1 cmd=${FM_BOARD_LOOP_CREW_STATE_CMD-$SCRIPT_DIR/fm-crew-state.sh}
  [ -n "$cmd" ] && [ -x "$cmd" ] || return 1
  fm_run_timed "$VALIDATION_TIMEOUT" "$cmd" "$id" 2>/dev/null
}

# pr_probe returns one compact JSON object for a canonical PR URL:
#   {"state":"OPEN|MERGED|CLOSED","isDraft":bool,"headRefOid":"<sha>",
#    "checks":"green|red|pending|unknown","mergedAt":<epoch-or-null>}
# An unavailable probe yields nothing, which the caller records as unknown.
pr_probe() { # <pr-url>
  local url=$1 cmd=${FM_BOARD_LOOP_PR_PROBE_CMD:-}
  [ -n "$url" ] || return 1
  if [ -n "$cmd" ]; then
    # shellcheck disable=SC2086
    $cmd "$url" 2>/dev/null
    return
  fi
  command -v gh >/dev/null 2>&1 || return 1
  gh pr view "$url" --json state,isDraft,headRefOid,mergeStateStatus,statusCheckRollup,mergedAt 2>/dev/null \
    | jq -c '
      . as $pr
      | {state,isDraft,headRefOid,
         checks:(if (($pr.statusCheckRollup // []) | length) == 0 then "unknown"
                 elif any($pr.statusCheckRollup[]; (.conclusion // .state // "")
                   | IN("FAILURE","ERROR","CANCELLED","TIMED_OUT","ACTION_REQUIRED")) then "red"
                 elif all($pr.statusCheckRollup[]; (.conclusion // .state // "")
                   | IN("SUCCESS","NEUTRAL","SKIPPED")) then "green"
                 else "pending" end),
         mergedAt:(if ($pr.mergedAt // "") == "" then null else ($pr.mergedAt | fromdateiso8601) end)}'
}

# linear_cards returns a JSON array of the five active board columns, read from
# --cards when given, else from the narrow project-local Linear credential.
linear_cards() {
  if [ -n "$CARDS_FILE" ]; then
    [ -f "$CARDS_FILE" ] && [ ! -L "$CARDS_FILE" ] || return 1
    jq -e 'type == "array"' "$CARDS_FILE" >/dev/null 2>&1 || return 1
    jq -c '[.[] | {
      id:(.id // ""), identifier:(.identifier // ""),
      state:(if (.state | type) == "object" then (.state.name // "") else (.state // "") end),
      title:(.title // ""), url:(.url // "")
    } | select((.id | length) > 0)]' "$CARDS_FILE"
    return 0
  fi
  local key team project cursor payload
  key=$(fmx_env_get FM_LINEAR_READONLY_API_KEY "$LINEAR_CONFIG_FILE")
  [ -n "$key" ] || key=$(fmx_env_get LINEAR_API_KEY "$LINEAR_CONFIG_FILE")
  [ -n "$key" ] || key=${LINEAR_API_KEY:-}
  team=$(fmx_env_get FM_LINEAR_OPERATING_STUDIO_TEAM_ID "$LINEAR_CONFIG_FILE")
  [ -n "$team" ] || team=${FM_LINEAR_OPERATING_STUDIO_TEAM_ID:-}
  project=$(fmx_env_get FM_LINEAR_OPERATING_STUDIO_PROJECT_ID "$LINEAR_CONFIG_FILE")
  [ -n "$project" ] || project=${FM_LINEAR_OPERATING_STUDIO_PROJECT_ID:-}
  [ -n "$key" ] && [ -n "$team" ] && [ -n "$project" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  cursor=
  local cards='[]' page
  page=$(mktemp "${TMPDIR:-/tmp}/fm-board-loop.XXXXXX") || return 1
  while :; do
    payload=$(jq -cn --arg team "$team" --arg project "$project" --arg after "$cursor" '
      {query:"query Board($team: ID!, $project: ID!, $after: String) { issues(first: 250, after: $after, filter: { team: { id: { eq: $team } }, project: { id: { eq: $project } }, state: { name: { in: [\"Ready to Build\", \"In Progress\", \"In Review\", \"Ready to Merge\", \"Ready to Deploy\"] } } }) { nodes { id identifier title url state { name } } pageInfo { hasNextPage endCursor } } }",
       variables:{team:$team,project:$project,after:(if $after == "" then null else $after end)}}')
    if ! curl --fail --silent --show-error --max-time 15 \
      -H 'Content-Type: application/json' -H "Authorization: $key" \
      --data "$payload" https://api.linear.app/graphql > "$page" 2>/dev/null; then
      rm -f "$page"
      return 1
    fi
    if ! jq -e '(.errors // [] | length) == 0 and (.data.issues.nodes | type) == "array"' "$page" >/dev/null 2>&1; then
      rm -f "$page"
      return 1
    fi
    cards=$(jq -cn --argjson a "$cards" --slurpfile p "$page" '
      $a + ($p[0].data.issues.nodes | map({
        id:(.id // ""), identifier:(.identifier // ""),
        state:(.state.name // ""), title:(.title // ""), url:(.url // "")
      }))')
    [ "$(jq -r '.data.issues.pageInfo.hasNextPage' "$page")" = true ] || break
    cursor=$(jq -r '.data.issues.pageInfo.endCursor' "$page")
    [ -n "$cursor" ] || break
  done
  rm -f "$page"
  printf '%s\n' "$cards"
}

# --- herdr activity -----------------------------------------------------------

# agent_status_of returns the raw Herdr agent status for a recorded endpoint as
# one of working/idle/done/blocked, or unavailable/unknown. Liveness and the
# raw status are separate facts: an idle or done registration is not work.
agent_status_of() { # <session> <pane>
  local session=$1 pane=$2 cli=${FM_BOARD_LOOP_HERDR_CLI:-} out status
  [ -n "$session" ] && [ -n "$pane" ] || { printf 'unavailable\n'; return 0; }
  if [ -n "$cli" ]; then
    # shellcheck disable=SC2086
    out=$($cli "$session" agent get "$pane" 2>/dev/null) || out=
  else
    command -v herdr >/dev/null 2>&1 || { printf 'unavailable\n'; return 0; }
    out=$(fm_backend_herdr_cli "$session" agent get "$pane" 2>/dev/null) || out=
  fi
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null) || status=
  case "$status" in
    working|idle|done|blocked) printf '%s\n' "$status" ;;
    *) printf 'unknown\n' ;;
  esac
}

endpoint_status_of() { # <backend> <endpoint>
  local backend=$1 endpoint=$2 status cmd=${FM_BOARD_LOOP_ENDPOINT_STATUS_CMD:-}
  [ -n "$backend" ] && [ -n "$endpoint" ] || { printf 'unavailable\n'; return 0; }
  if [ -n "$cmd" ]; then
    status=$("$cmd" "$endpoint" 2>/dev/null) || status=unreadable
  else
    status=$(fm_backend_agent_state "$backend" "$endpoint" 2>/dev/null) || status=unreadable
  fi
  case "$status" in
    alive|dead|missing|ambiguous|unreadable|unverified) printf '%s\n' "$status" ;;
    *) printf 'unreadable\n' ;;
  esac
}

# disposition_of folds the status log's current declaration with live agent
# status. A terminal declaration always wins; otherwise a live working agent is
# working, and an idle/done agent with no terminal declaration is idle/done.
disposition_of() { # <status-verb> <agent-status>
  local verb=$1 agent=$2
  case "$verb" in
    done|failed|cancelled) printf 'terminal\n'; return 0 ;;
    needs-decision) printf 'parked\n'; return 0 ;;
    blocked) printf 'blocked\n'; return 0 ;;
    paused) printf 'paused\n'; return 0 ;;
  esac
  case "$agent" in
    working) printf 'working\n' ;;
    idle) printf 'idle\n' ;;
    done) printf 'done\n' ;;
    blocked) printf 'blocked\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

validation_of() { # <task-id>
  local id=$1 line state
  line=$(crew_state_line "$id") || { printf 'unknown\n'; return 0; }
  state=${line#state: }   # "state: working · source: run-step · detail"
  state=${state%% *}
  case "$state" in
    working) printf 'running\n' ;;
    parked) printf 'gate-waiting\n' ;;
    blocked) printf 'blocked\n' ;;
    done) printf 'green\n' ;;
    failed) printf 'failed\n' ;;
    paused) printf 'waiting\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

agent_status_from_validation() { # <validation>
  case "$1" in
    running) printf 'working\n' ;;
    green) printf 'done\n' ;;
    blocked) printf 'blocked\n' ;;
    gate-waiting|waiting) printf 'idle\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# prepare_validations probes every recorded non-secondmate task's live
# validation/run disposition in parallel, bounded by VALIDATION_TIMEOUT each, so
# a wall of lanes can never serialize a slow crew-state read into the scan.
# The result is one sorted id<TAB>validation map file; a failed probe is unknown.
prepare_validations() {
  local ids="$TMP/validation-ids" pids='' count=0 pid id out="$TMP/validations.tsv" meta
  : > "$ids"
  : > "$out"
  if [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      id=${meta##*/}; id=${id%.meta}
      task_id_valid "$id" || continue
      [ "$(fm_meta_get "$meta" kind)" = secondmate ] && continue
      printf '%s\n' "$id" >> "$ids"
    done
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    (
      v=$(validation_of "$id") || v=unknown
      if [ "$v" = unknown ]; then source=unavailable; else source=available; fi
      printf '%s\t%s\t%s\n' "$id" "$v" "$source" >> "$out"
    ) &
    pids="$pids $!"
  done < "$ids"
  for pid in $pids; do
    wait "$pid" 2>/dev/null || true
  done
  if [ "$count" -gt 0 ] && [ -s "$out" ]; then
    LC_ALL=C sort -o "$out" "$out" 2>/dev/null || true
  fi
  VALIDATION_MAP=$out
}

validation_lookup() { # <task-id>
  local id=$1
  [ -n "$VALIDATION_MAP" ] && [ -f "$VALIDATION_MAP" ] || { printf 'unknown\n'; return 0; }
  awk -F'\t' -v id="$id" '$1 == id { print $2; found=1; exit } END { if (!found) print "unknown" }' \
    "$VALIDATION_MAP" 2>/dev/null || printf 'unknown\n'
}

validation_source_lookup() { # <task-id>
  local id=$1
  [ -n "$VALIDATION_MAP" ] && [ -f "$VALIDATION_MAP" ] || { printf 'unavailable\n'; return 0; }
  awk -F'\t' -v id="$id" '$1 == id { print $3; found=1; exit } END { if (!found) print "unavailable" }' \
    "$VALIDATION_MAP" 2>/dev/null || printf 'unavailable\n'
}

# --- decision ledger ----------------------------------------------------------

# decision_state_of prints one TSV row per open or durably answered decision:
#   <key>\t<verb>\t<delivered>\t<acknowledged>\t<ring-attempts>\t<progressed>\t<phase>
# Answer records bind the exact key to the exact inbox record and status offset.
# Delivery is never completion: a decision is consumed only once the worker
# also reaches a productive or terminal disposition.
decision_state_of() { # <task-id>
  local id=$1
  local status="$STATE/$id.status" inbox="$STATE/$id.inbox" records="$STATE/$id.decision-deliveries"
  local key verb note delivered handed attempts f line msg count record basename baseline size progressed phase open_set
  open_set=$(status_open_decisions "$status" 2>/dev/null || true)
  while IFS=$'\t' read -r key verb note || [ -n "${key:-}" ]; do
    [ -n "$key" ] || continue
    delivered=0
    handed=0
    attempts=0
    if [ -f "$inbox/.ring-state" ] && [ ! -L "$inbox/.ring-state" ]; then
      line=$(sed -n '/./{p;q;}' "$inbox/.ring-state" 2>/dev/null) || line=
      msg=${line%%$'\t'*}
      line=${line#*$'\t'}
      count=${line%%$'\t'*}
      case "$count" in ''|*[!0-9]*) count=0 ;; esac
      attempts=$count
      [ -n "$msg" ] || attempts=$count
    fi
    printf '%s\t%s\t%s\t%s\t%s\t0\topen\n' "$key" "$verb" "$delivered" "$handed" "$attempts"
  done < <(printf '%s\n' "$open_set")
  if [ -d "$records" ] && [ ! -L "$records" ]; then
    for record in "$records"/*.record; do
      [ -f "$record" ] && [ ! -L "$record" ] || continue
      key=$(sed -n 's/^key=//p' "$record" | sed -n '/./{p;q;}')
      basename=$(sed -n 's/^inbox_record=//p' "$record" | sed -n '/./{p;q;}')
      baseline=$(sed -n 's/^status_size=//p' "$record" | sed -n '/./{p;q;}')
      phase=$(sed -n 's/^phase=//p' "$record" | sed -n '/./{p;q;}')
      case "$key" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
      case "$basename" in ''|*/*|.*|*[!A-Za-z0-9._-]*) continue ;; esac
      case "$baseline" in ''|*[!0-9]*) baseline=0 ;; esac
      case "$phase" in ''|committed) phase=committed ;; prepared)
        case "$open_set" in
          "$key"$'\t'* | *$'\n'"$key"$'\t'*) continue ;;
        esac
        ;; *) continue ;;
      esac
      delivered=0
      handed=0
      if [ -f "$inbox/$basename" ] && [ ! -L "$inbox/$basename" ]; then delivered=1; fi
      if [ -f "$inbox/handled/$basename" ] && [ ! -L "$inbox/handled/$basename" ]; then
        delivered=1
        handed=1
      fi
      if [ -f "$status" ] && [ ! -L "$status" ]; then
        size=$(wc -c < "$status" 2>/dev/null | tr -d '[:space:]')
      else
        size=0
      fi
      case "$size" in ''|*[!0-9]*) size=0 ;; esac
      progressed=0
      [ "$size" -le "$baseline" ] || progressed=1
      attempts=0
      if [ "$delivered" -eq 1 ] && [ "$handed" -eq 0 ] && [ -f "$inbox/.ring-state" ]; then
        line=$(sed -n '/./{p;q;}' "$inbox/.ring-state" 2>/dev/null) || line=
        msg=${line%%$'\t'*}
        count=${line#*$'\t'}; count=${count%%$'\t'*}
        [ "$msg" = "$basename" ] || count=0
        case "$count" in ''|*[!0-9]*) count=0 ;; esac
        attempts=$count
      fi
      printf '%s\tanswered\t%s\t%s\t%s\t%s\t%s\n' "$key" "$delivered" "$handed" "$attempts" "$progressed" "$phase"
    done
  fi
}

# --- lane and decision collection ---------------------------------------------

lane_json() { # lane fields followed by PR and source-health evidence
  jq -cn \
    --arg task_id "$1" --arg kind "$2" --arg backend "$3" --arg endpoint "$4" \
    --arg linear_card_id "$5" --arg agent_status "$6" --arg endpoint_status "$7" \
    --arg disposition "$8" --arg validation "$9" --argjson terminal "${10}" \
    --arg pr "${11}" --arg pr_head "${12}" --arg pr_state "${13}" \
    --argjson pr_draft "${14}" --arg pr_head_live "${15}" \
    --arg pr_checks "${16}" --argjson pr_merged_at "${17}" --arg status_verb "${18}" \
    --argjson status_size "${19}" --arg agent_source "${20}" \
    --arg validation_source "${21}" --arg forge_source "${22}" \
    '{task_id:$task_id, kind:$kind, backend:$backend, endpoint:$endpoint,
      linear_card_id:$linear_card_id, agent_status:$agent_status,
      endpoint_status:$endpoint_status, disposition:$disposition,
      validation:$validation, terminal:$terminal, pr:$pr, pr_head:$pr_head,
      pr_state:$pr_state, pr_draft:$pr_draft, pr_head_live:$pr_head_live,
      pr_checks:$pr_checks, pr_merged_at:$pr_merged_at,
      status_verb:$status_verb, status_size:$status_size,
      agent_source:$agent_source, validation_source:$validation_source,
      forge_source:$forge_source}'
}

collect_lanes() { # -> JSON array
  local meta id kind backend endpoint card session pane agent endstat
  local status verb disposition validation terminal pr pr_head
  local pr_state pr_draft pr_head_live pr_checks pr_merged_at out lines=() status_size validation_source
  local agent_source forge_source
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf '[]\n'; return 0; }
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    task_id_valid "$id" || continue
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" = secondmate ] && continue
    backend=$(fm_backend_of_meta "$meta")
    endpoint=$(fm_backend_target_of_meta "$meta")
    card=$(fm_meta_get "$meta" linear_card_id)
    pr=$(fm_meta_get "$meta" pr)
    pr_head=$(fm_meta_get "$meta" pr_head)
    terminal=$(fm_meta_get "$meta" terminal)
    session=$(fm_meta_get "$meta" herdr_session)
    pane=$(fm_meta_get "$meta" herdr_pane_id)
    validation=$(validation_lookup "$id")
    validation_source=$(validation_source_lookup "$id")
    if [ "$backend" = herdr ] && [ -n "$session" ] && [ -n "$pane" ] && [ "$endpoint" = "$session:$pane" ]; then
      agent=$(agent_status_of "$session" "$pane")
      endstat=$(endpoint_status_of "$backend" "$endpoint")
      case "$agent" in unavailable|unknown) agent_source=unavailable ;; *) agent_source=available ;; esac
    else
      agent=$(agent_status_from_validation "$validation")
      endstat=$(endpoint_status_of "$backend" "$endpoint")
      agent_source=$validation_source
    fi
    verb=$(status_current_line "$STATE/$id.status" "$kind" 2>/dev/null) || verb=
    verb=${verb%% *}
    [ -n "$verb" ] || verb=unknown
    if [ "$terminal" = 1 ]; then
      disposition=terminal
    else
      disposition=$(disposition_of "$verb" "$agent")
    fi
    pr_state=unknown
    pr_draft=false
    pr_head_live=
    pr_checks=unknown
    pr_merged_at=0
    forge_source=not-required
    if [ -n "$pr" ]; then
      out=$(pr_probe "$pr") || out=
      if [ -n "$out" ]; then
        pr_state=$(printf '%s' "$out" | jq -r '.state // "unknown"' 2>/dev/null) || pr_state=unknown
        pr_draft=$(printf '%s' "$out" | jq -r '.isDraft // false' 2>/dev/null) || pr_draft=false
        pr_head_live=$(printf '%s' "$out" | jq -r '.headRefOid // ""' 2>/dev/null) || pr_head_live=
        pr_checks=$(printf '%s' "$out" | jq -r '.checks // "unknown"' 2>/dev/null) || pr_checks=unknown
        pr_merged_at=$(printf '%s' "$out" | jq -r '
          if (.mergedAt | type) == "number" then .mergedAt
          elif (.mergedAt | type) == "string" then (.mergedAt | fromdateiso8601)
          else 0 end' 2>/dev/null) || pr_merged_at=0
        if [ "$pr_state" = unknown ]; then forge_source=unavailable; else forge_source=available; fi
      else
        forge_source=unavailable
      fi
    fi
    case "$pr_draft" in true|false) ;; *) pr_draft=false ;; esac
    case "$pr_checks" in green|red|pending|unknown) ;; *) pr_checks=unknown ;; esac
    case "$pr_merged_at" in ''|*[!0-9]*) pr_merged_at=0 ;; esac
    if [ -f "$STATE/$id.status" ]; then
      status_size=$(wc -c < "$STATE/$id.status" 2>/dev/null | tr -d '[:space:]')
    else
      status_size=0
    fi
    case "$status_size" in ''|*[!0-9]*) status_size=0 ;; esac
    if [ "$terminal" = 1 ]; then
      lines+=("$(lane_json "$id" "$kind" "$backend" "$endpoint" "$card" "$agent" "$endstat" \
        "$disposition" "$validation" true "$pr" "$pr_head" "$pr_state" "$pr_draft" "$pr_head_live" "$pr_checks" "$pr_merged_at" "$verb" "$status_size" \
        "$agent_source" "$validation_source" "$forge_source")")
    else
      lines+=("$(lane_json "$id" "$kind" "$backend" "$endpoint" "$card" "$agent" "$endstat" \
        "$disposition" "$validation" false "$pr" "$pr_head" "$pr_state" "$pr_draft" "$pr_head_live" "$pr_checks" "$pr_merged_at" "$verb" "$status_size" \
        "$agent_source" "$validation_source" "$forge_source")")
    fi
  done
  [ "${#lines[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  printf '%s\n' "${lines[@]}" | jq -cs '.'
}

collect_decisions() { # -> JSON array
  local meta id lines=()
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf '[]\n'; return 0; }
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    task_id_valid "$id" || continue
    while IFS=$'\t' read -r key verb delivered handed attempts progressed phase; do
      [ -n "$key" ] || continue
      lines+=("$(jq -cn --arg task_id "$id" --arg key "$key" --arg verb "$verb" \
        --argjson delivered "$delivered" --argjson acknowledged "$handed" \
        --argjson ring_attempts "$attempts" --argjson progressed "$progressed" \
        --arg phase "$phase" \
        '{task_id:$task_id, key:$key, verb:$verb, delivered:$delivered,
          acknowledged:$acknowledged, ring_attempts:$ring_attempts,
          progressed:$progressed, phase:$phase}')")
    done < <(decision_state_of "$id")
  done
  [ "${#lines[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  printf '%s\n' "${lines[@]}" | jq -cs '.'
}

collect_remote() { # -> health envelope with inventories and merged lanes
  local file=${REMOTE_FILE:-${FM_BOARD_LOOP_REMOTE_INVENTORY:-}}
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || {
      printf '{"status":"unavailable","inventories":[],"lanes":[]}\n'; return 0;
    }
    jq -ce --argjson now "$NOW" --argjson max_age "$REMOTE_MAX_AGE_SECS" '
      (if type == "array" then . else [.] end) as $inventories
      | if ($inventories | length) > 0
          and all($inventories[]; .schema == "fm-board-inventory.v1"
            and (.home | type) == "string" and (.home | length) > 0
            and (.owner_task | type) == "string" and (.owner_task | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
            and (.observed_at | type) == "number" and .observed_at <= $now
            and ($now - .observed_at) <= $max_age
            and (.lanes | type) == "array")
          and all($inventories[].lanes[];
            (.task_id | type) == "string" and (.linear_card_id | type) == "string"
            and (.backend | type) == "string" and (.endpoint | type) == "string"
            and (.agent_status | type) == "string" and (.endpoint_status | type) == "string"
            and (.disposition | type) == "string" and (.validation | type) == "string"
            and (.agent_source | type) == "string" and (.validation_source | type) == "string"
            and (.forge_source | type) == "string")
        then {status:"available", inventories:$inventories,
              lanes:[$inventories[] as $inv | $inv.lanes[]
                | . + {owner_home:$inv.home, owner_task:$inv.owner_task,
                       observed_at:$inv.observed_at}]}
        else error("invalid remote inventory") end' "$file" 2>/dev/null \
      || printf '{"status":"unavailable","inventories":[],"lanes":[]}\n'
    return 0
  fi
  printf '{"status":"not-configured","inventories":[],"lanes":[]}\n'
}

# --- deployment ledger --------------------------------------------------------

history_prepare() {
  [ ! -L "$HISTORY" ] || return 0
  if [ ! -f "$HISTORY" ]; then
    : > "$HISTORY" 2>/dev/null || true
  fi
}

# history_record appends one exact-head deployment without duplicating its
# permanent card/head identity. Idempotent across reruns.
history_record() { # <card-id> <pr-url> <head> <merged-at>
  local card=$1 pr=$2 head=$3 merged_at=$4
  [ -n "$card" ] && [ -n "$head" ] || return 0
  case "$merged_at" in ''|*[!0-9]*|0) return 0 ;; esac
  [ "$merged_at" -le "$NOW" ] || return 0
  [ -f "$HISTORY" ] && [ ! -L "$HISTORY" ] || : > "$HISTORY" 2>/dev/null || true
  if awk -F'\t' -v c="$card" -v h="$head" 'NF >= 4 && $2 == c && $4 == h { found=1 } END { exit found ? 0 : 1 }' "$HISTORY" 2>/dev/null; then
    return 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$merged_at" "$card" "$pr" "$head" >> "$HISTORY" 2>/dev/null || true
}

history_json() {
  if [ ! -f "$HISTORY" ] || [ -L "$HISTORY" ]; then
    printf '[]\n'
    return 0
  fi
  jq -Rn '[inputs | split("\t") | select(length >= 3) | select(.[0] | test("^[0-9]+$"))
    | {ts:(.[0] | tonumber), card_id:.[1], pr:.[2], head:(.[3] // "")}]' < "$HISTORY" 2>/dev/null \
    || printf '[]\n'
}

# lane_history_json reads the durable per-lane disposition ledger so a lane that
# has held the same disposition with no new status bytes or PR head across
# passes is surfaced as stalled rather than counted as active indefinitely.
lane_history_json() {
  if [ ! -f "$STALL_LEDGER" ] || [ -L "$STALL_LEDGER" ]; then
    printf '[]\n'
    return 0
  fi
  jq -Rn '[inputs | split("\t") | select(length >= 5)
    | {task_id:.[0], disposition:.[1],
       status_size:((.[2] // "0") | tonumber? // 0),
       pr_head:(.[3] // ""), since:((.[4] // "0") | tonumber? // 0)}]' \
    < "$STALL_LEDGER" 2>/dev/null || printf '[]\n'
}

# lane_history_write persists the current pass's disposition, evidence size, PR
# head, and stall anchor. It is the one writer of the ledger.
lane_history_write() { # reads the report JSON on stdin
  local tmp
  tmp=$(mktemp "$STATE/.board-loop-stall.XXXXXX" 2>/dev/null) || return 0
  if jq -r '.lanes[] | [.task_id, .disposition, (.status_size // 0),
      (.pr_head // ""), (.stall_since // 0)] | @tsv' > "$tmp" 2>/dev/null \
    && mv -f "$tmp" "$STALL_LEDGER" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
}

# --- inventory mode -----------------------------------------------------------

emit_inventory() {
  local lanes owner_task=
  prepare_validations
  lanes=$(collect_lanes)
  if [ -f "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ]; then
    owner_task=$(sed -n '/./{p;q;}' "$FM_HOME/.fm-secondmate-home" 2>/dev/null)
  fi
  jq -cn --arg home "$FM_HOME" --arg owner_task "$owner_task" --argjson observed_at "$NOW" \
    --argjson lanes "$lanes" \
    '{schema:"'"$INVENTORY_SCHEMA"'", home:$home, owner_task:$owner_task,
      observed_at:$observed_at, lanes:$lanes}'
}

# --- classification -----------------------------------------------------------

classify() { # cards, lanes, decisions, remote envelope, history, previous lanes, paused, reason, sources
  jq -n \
    --argjson now "$NOW" \
    --argjson window "$DEPLOY_WINDOW_SECS" \
    --argjson stall_secs "$STALL_SECS" \
    --argjson cards "$1" \
    --argjson lanes "$2" \
    --argjson decisions "$3" \
    --argjson remote "$4" \
    --argjson history "$5" \
    --argjson prev "$6" \
    --argjson paused "$7" \
    --arg pause_reason "$8" \
    --argjson sources "$9" \
    --arg schema "$REPORT_SCHEMA" '
    def active: . == "Ready to Build" or . == "In Progress" or . == "In Review" or . == "Ready to Merge";
    def productive:
      .agent_status == "working" and .endpoint_status == "alive"
      and .agent_source == "available" and .validation_source == "available"
      and (.disposition != "terminal" and .disposition != "done"
           and .disposition != "parked" and .disposition != "paused"
           and .disposition != "blocked")
      and (.validation != "blocked" and .validation != "failed")
      and ((.card_state == null) or (.card_state | active));
    [ $lanes[] as $l
      | ($cards | map(select(.id == $l.linear_card_id)) | .[0]) as $c
      | ($prev | map(select(.task_id == $l.task_id)) | .[0]) as $p
      | ($l.pr_head // "") as $ph
      | (if $p != null and $p.disposition == $l.disposition
            and ($p.status_size // 0) == ($l.status_size // 0)
            and ($p.pr_head // "") == $ph
          then ($p.since // $now) else $now end) as $since
      | $l + {card_state:($c.state // null), card_identifier:($c.identifier // null),
              stall_since:$since, stalled_secs:($now - $since)} ] as $joined
    | [ $cards[] as $c
        | ([ $joined[] | select(.linear_card_id == $c.id) ]) as $owners
        | if ($owners | length) == 0 then
            {kind:"orphan-card", task_id:null, card_id:$c.id, identifier:$c.identifier,
             card_state:$c.state, detail:"Linear card has no recorded worker binding",
             recovery:{kind:"escalate", target:null, reason:"assign a worker to the card"}}
          elif ($owners | length) > 1 then
            {kind:"duplicate-ownership", task_id:$owners[0].task_id, card_id:$c.id,
             identifier:$c.identifier, card_state:$c.state,
             detail:("multiple workers claim this card: " + ($owners | map(.task_id) | join(","))),
             recovery:{kind:"escalate", target:null, reason:"resolve the duplicate card ownership"}}
          else $owners[0] as $l
            | if ($l.pr_head != "" and $l.pr_head_live != "" and $l.pr_head != $l.pr_head_live) then
                {kind:"head-drift", task_id:$l.task_id, card_id:$c.id, identifier:$c.identifier,
                 card_state:$c.state,
                 detail:("recorded PR head " + $l.pr_head + " differs from the live head " + $l.pr_head_live),
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"re-verify the exact PR head before any landing decision"}}
              elif $l.pr != "" and ($l.pr_head == "" or $l.pr_head_live == "") then
                {kind:"pr-head-unverified", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"the canonical PR does not have matching recorded and live head evidence",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"record and verify the exact PR head before changing the card state"}}
              elif $c.state == "In Review" and $l.pr == "" then
                {kind:"in-review-without-pr", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"card is In Review but the worker records no PR",
                 recovery:{kind:"steer", target:$l.task_id,
                   reason:"attach the canonical PR URL or move the card back to In Progress"}}
              elif $c.state == "Ready to Merge" and ($l.pr_state != "MERGED"
                   or $l.pr_head_live != $l.pr_head) then
                {kind:"ready-to-merge-unlanded", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"reviewed candidate is Ready to Merge but not landed",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"land the reviewed candidate serially and verify the readback"}}
              elif $c.state == "Ready to Merge" and $l.pr_state == "MERGED"
                   and $l.pr_head_live == $l.pr_head then
                {kind:"merged-pr-awaiting-linear-readback", task_id:$l.task_id,
                 card_id:$c.id, identifier:$c.identifier, card_state:$c.state,
                 detail:"the exact reviewed head is merged but Linear still says Ready to Merge",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"have the serial merge owner complete and verify the Linear transition"}}
              elif $c.state == "Ready to Deploy" and ($l.pr_state != "MERGED"
                   or $l.pr_head_live != $l.pr_head) then
                {kind:"ready-to-deploy-unverified", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"card is Ready to Deploy without a merged canonical PR",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"verify the landing before counting this card as deployed"}}
              elif $c.state == "Ready to Deploy" and $l.pr_merged_at <= 0 then
                {kind:"merge-time-unverified", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"the exact merged head has no authoritative merge time",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"restore merge-time evidence before counting throughput"}}
              elif $l.pr != "" and $c.state == "In Progress" and $l.pr_state == "OPEN"
                   and $l.pr_draft == false
                   and ($l.disposition == "done" or $l.disposition == "terminal"
                        or $l.agent_status == "idle" or $l.agent_status == "done")
                   and ($l.pr_checks != "green" or $l.validation != "green") then
                {kind:"pr-not-green", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"the open PR lacks green forge checks and green lane validation",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"finish validation before requesting independent review"}}
              elif $l.pr != "" and $c.state == "In Progress" and $l.pr_state == "OPEN"
                   and $l.pr_draft == false
                   and $l.pr_checks == "green" and $l.validation == "green"
                   and ($l.disposition == "done" or $l.disposition == "terminal"
                        or $l.agent_status == "idle" or $l.agent_status == "done") then
                {kind:"green-pr-not-in-review", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"a non-draft PR is open while the card is still In Progress",
                 recovery:{kind:"steer", target:$l.task_id,
                   reason:"move the card to In Review for independent review and verify the readback"}}
              elif $l.pr != "" and $c.state == "In Progress" and $l.pr_draft == true then
                {kind:"draft-held", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"the PR is still a draft; a draft cannot be reviewed or merged",
                 recovery:{kind:"steer", target:$l.task_id,
                   reason:"mark the PR ready or declare the draft wait"}}
              elif $l.disposition == "terminal" and ($c.state | active) then
                {kind:"terminal-lane-active-card", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:("worker is terminal but the card is still " + $c.state),
                 recovery:{kind:"steer", target:$l.task_id,
                   reason:"move the card to its next state and verify the readback"}}
              elif $l.disposition == "done" and ($c.state | active) then
                {kind:"terminal-lane-active-card", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"worker reports done but the card is still active",
                 recovery:{kind:"steer", target:$l.task_id,
                   reason:"reconcile your finished work with the card state"}}
              elif ($l.stalled_secs >= $stall_secs) and ($c.state | active) then
                {kind:"stalled-disposition", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:("lane has held disposition " + $l.disposition + " for "
                   + ($l.stalled_secs | tostring) + "s with no new status or PR head evidence"),
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"unstall the lane or reassign it; the disposition has not moved"}}
              elif ($l.agent_status == "idle" or $l.agent_status == "done")
                   and $c.state == "In Progress" and $l.validation != "green" then
                {kind:"idle-lane-unresolved", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"worker is idle/done with unresolved In Progress work",
                 recovery:{kind:"steer", target:$l.task_id,
                   reason:"resume or hand off the card; your agent is idle"}}
              elif (($l.agent_status == "unavailable" or $l.agent_status == "unknown"
                    or $l.endpoint_status == "missing" or $l.endpoint_status == "dead"
                    or $l.endpoint_status == "unreadable" or $l.endpoint_status == "unverified"
                    or $l.endpoint_status == "unavailable")
                    and ($c.state | active)) then
                {kind:"endpoint-unavailable", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"worker endpoint is unavailable while the card is active",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"recover the worker before the card can progress"}}
              else empty end
          end
      ] as $card_causes
    | [ $decisions[] as $d
        | ($joined | map(select(.task_id == $d.task_id)) | .[0]) as $l
        | if $d.phase == "prepared" then
            {kind:"decision-tracking-incomplete", task_id:$d.task_id,
             card_id:($l.linear_card_id // null), identifier:($l.card_identifier // null),
             detail:"decision closed with a durable prepared binding that was not committed",
             recovery:{kind:"escalate", target:$d.task_id,
               reason:("repair acknowledgement tracking for decision key " + $d.key)}}
          elif $d.verb == "blocked" then
            if $d.delivered != 1 then
              {kind:"blocked-undelivered", task_id:$d.task_id,
               card_id:($l.linear_card_id // null), identifier:($l.card_identifier // null),
               detail:"blocker recorded but the clearing instruction never reached the worker inbox",
               recovery:{kind:"steer", target:$d.task_id,
                 reason:("clear blocker key " + $d.key + " and verify acknowledgement")}}
            else
              {kind:"blocked-lane", task_id:$d.task_id,
               card_id:($l.linear_card_id // null), identifier:($l.card_identifier // null),
               detail:("lane reports a blocker: " + ($d.key // "default")),
               recovery:{kind:"escalate", target:$d.task_id,
                 reason:("clear or reassign the blocker for key " + $d.key)}}
            end
          elif $d.delivered != 1 then
            {kind:"decision-recorded-undelivered", task_id:$d.task_id,
             card_id:($l.linear_card_id // null), identifier:($l.card_identifier // null),
             detail:"decision recorded but not delivered to the worker inbox",
             recovery:{kind:"steer", target:$d.task_id,
               reason:("answer decision key " + $d.key + " and verify acknowledgement")}}
          elif $d.acknowledged != 1 and $d.ring_attempts >= 3 then
            {kind:"decision-delivered-unacknowledged", task_id:$d.task_id,
             card_id:($l.linear_card_id // null), identifier:($l.card_identifier // null),
             detail:"decision delivered but unacknowledged after the bounded ring ladder",
             recovery:{kind:"escalate", target:$d.task_id,
               reason:"deliver the decision through a reachable channel and verify acknowledgement"}}
          elif $d.acknowledged != 1 then
            {kind:"decision-delivered-unacknowledged", task_id:$d.task_id,
             card_id:($l.linear_card_id // null), identifier:($l.card_identifier // null),
             detail:"decision delivered but the worker has not acknowledged it",
             recovery:{kind:"steer", target:$d.task_id,
               reason:("acknowledge and consume decision key " + $d.key)}}
          elif $d.acknowledged == 1 and $l != null
               and $l.disposition != "terminal"
               and (($d.progressed == 1 and $l.disposition == "working") | not)
               and ($l.card_state != null) and ($l.card_state | active) then
            {kind:"decision-unconsumed", task_id:$d.task_id, card_id:$l.linear_card_id,
             identifier:$l.card_identifier, detail:"decision acknowledged but the lane never reached a productive disposition",
             recovery:{kind:"steer", target:$d.task_id,
               reason:("act on decision key " + $d.key + " and report a productive or terminal disposition")}}
          else empty end
      ] as $decision_causes
    | [ $joined[] as $l
        | select(($l.linear_card_id // "") == "")
        | {kind:"worker-without-card", task_id:$l.task_id, card_id:null, identifier:null,
           detail:"worker has no canonical Linear card binding",
           recovery:{kind:"escalate", target:$l.task_id,
             reason:"record the immutable Linear card id for this worker"}}
      ] as $unbound_causes
    | [ $remote.inventories[] as $inv
        | {kind:"remote-inventory", home:($inv.home // ""),
           lanes:(($inv.lanes // []) | length), detail:"remote inventory included"} ] as $remote_rows
    | ([ $history[] | select((.ts | type) == "number" and ($now - .ts) <= $window) ] | length) as $landed
    | ([ $joined[] | select(productive) ] | length) as $productive
    | ([ $joined[] | select(.card_state != null and (.card_state | active)
          and .disposition != "terminal") ] | length) as $eligible_active
    | ([ $cards[] | select(.state == "Ready to Deploy") ] | length) as $rtd
    | ([
        if $sources.linear == "unavailable" then
          {kind:"source-unavailable", task_id:null, card_id:null, identifier:null,
           detail:"Linear board input is unavailable",
           recovery:{kind:"escalate",target:null,reason:"restore Linear board access"}}
        else empty end,
        if $sources.remote == "unavailable" then
          {kind:"source-unavailable", task_id:null, card_id:null, identifier:null,
           detail:"remote lane inventory is unavailable or invalid",
           recovery:{kind:"escalate",target:null,reason:"restore the remote inventory feed"}}
        else empty end,
        if any($joined[]; .validation_source == "unavailable") then
          {kind:"source-unavailable", task_id:null, card_id:null, identifier:null,
           detail:"crew-state validation is unavailable for one or more lanes",
           recovery:{kind:"escalate",target:null,reason:"restore crew-state validation"}}
        else empty end,
        if any($joined[]; .agent_source == "unavailable") then
          {kind:"source-unavailable", task_id:null, card_id:null, identifier:null,
           detail:"agent-state evidence is unavailable for one or more lanes",
           recovery:{kind:"escalate",target:null,reason:"restore the backend agent-state reader"}}
        else empty end,
        if any($joined[]; .forge_source == "unavailable") then
          {kind:"source-unavailable", task_id:null, card_id:null, identifier:null,
           detail:"forge evidence is unavailable for one or more recorded PRs",
           recovery:{kind:"escalate",target:null,reason:"restore the canonical PR probe"}}
        else empty end
      ]) as $source_causes
    | (($card_causes + $decision_causes + $unbound_causes + $source_causes)) as $causes
    | {
        schema:$schema,
        generated_at:$now,
        cards:($cards | map({id, identifier, state, title, url})),
        lanes:$joined,
        causes:$causes,
        capacity:{productive:$productive, lanes:($joined | length),
          eligible_active:$eligible_active},
        throughput:{window_seconds:$window, ready_to_deploy:$rtd,
          verified_ready_to_deploy:$landed,
          fault:($landed == 0 and $eligible_active > 0)},
        paused:$paused,
        pause_reason:$pause_reason,
        sources:$sources,
        decisions:($decisions),
        remote:($remote_rows),
        summary:{cards:($cards | length), causes:($causes | length),
          end_to_end_fault:(($landed == 0 and $eligible_active > 0)
            or any($causes[]; .kind == "endpoint-unavailable" or .kind == "source-unavailable"))}
      }'
}

# --- recover ------------------------------------------------------------------

# Recovery retries one still-present cause at most three times, no faster than
# the board cadence. The ledger drops a signature as soon as its cause clears,
# so a later recurrence gets a fresh bounded retry ladder.
recovery_signature() {
  local sig
  sig=$(printf '%s' "$1" | shasum 2>/dev/null | cut -d' ' -f1)
  [ -n "$sig" ] || sig=$(printf '%s' "$1" | cksum 2>/dev/null | awk '{print $1}')
  printf '%s' "$sig"
}

recovery_ledger_sync() { # <active task/reason TSV on stdin>
  local active="$TMP/recovery-active.tsv" tmp id reason sig
  : > "$active"
  while IFS=$'\t' read -r id reason; do
    [ -n "$id" ] || continue
    sig=$(recovery_signature "$reason")
    [ -n "$sig" ] || continue
    printf '%s\t%s\n' "$id" "$sig" >> "$active"
  done
  [ -f "$RECOVERY_LEDGER" ] && [ ! -L "$RECOVERY_LEDGER" ] || { : > "$RECOVERY_LEDGER"; return 0; }
  tmp=$(mktemp "$STATE/.board-loop-recovery.XXXXXX") || return 1
  awk -F'\t' 'NR==FNR { active[$1 FS $2]=1; next }
    active[$1 FS $2] { print }' "$active" "$RECOVERY_LEDGER" > "$tmp" \
    && mv -f "$tmp" "$RECOVERY_LEDGER" || { rm -f "$tmp"; return 1; }
}

recover_target() { # <task-id> <reason> <card-id> <identifier>
  local id=$1 reason=$2 card=$3 identifier=$4 sig send_cmd=${FM_BOARD_LOOP_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}
  local row attempts last tmp
  board_loop_card_resumed "$card" "$identifier" || return 1
  task_id_valid "$id" || return 1
  sig=$(recovery_signature "$reason")
  [ -n "$sig" ] || return 1
  row=$(awk -F'\t' -v id="$id" -v sig="$sig" '$1 == id && $2 == sig { print; exit }' \
    "$RECOVERY_LEDGER" 2>/dev/null) || row=
  attempts=$(printf '%s' "$row" | awk -F'\t' '{print $3}')
  last=$(printf '%s' "$row" | awk -F'\t' '{print $4}')
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ "$attempts" -lt "$RECOVERY_MAX_ATTEMPTS" ] || return 0
  [ $((NOW - last)) -ge "$RECOVERY_RETRY_SECS" ] || return 0
  if FM_HOME="$FM_HOME" $send_cmd "$id" "$reason" >/dev/null 2>&1; then
    tmp=$(mktemp "$STATE/.board-loop-recovery.XXXXXX") || return 1
    awk -F'\t' -v id="$id" -v sig="$sig" '!($1 == id && $2 == sig)' \
      "$RECOVERY_LEDGER" > "$tmp" 2>/dev/null || true
    printf '%s\t%s\t%s\t%s\n' "$id" "$sig" "$((attempts + 1))" "$NOW" >> "$tmp" \
      && mv -f "$tmp" "$RECOVERY_LEDGER" || { rm -f "$tmp"; return 1; }
    return 0
  fi
  return 1
}

# --- main ---------------------------------------------------------------------

case "$MODE" in
  inventory)
    emit_inventory
    ;;
  scan|recover)
    history_prepare
    if CARDS=$(linear_cards); then LINEAR_HEALTH=available; else CARDS='[]'; LINEAR_HEALTH=unavailable; fi
    prepare_validations
    LOCAL_LANES=$(collect_lanes)
    DECISIONS=$(collect_decisions)
    REMOTE=$(collect_remote)
    LANES=$(jq -cn --arg home "$FM_HOME" --argjson local "$LOCAL_LANES" --argjson remote "$REMOTE" \
      '($local | map(. + {owner_home:$home, owner_task:"", observed_at:null})) + $remote.lanes')
    SOURCES=$(jq -cn --arg linear "$LINEAR_HEALTH" \
      --arg remote "$(printf '%s' "$REMOTE" | jq -r '.status')" \
      '{linear:$linear,remote:$remote}')

    # Record newly verified Ready to Deploy cards before the throughput read so
    # this pass's own verified landings count inside the rolling hour.
    while IFS=$'\t' read -r card pr head merged_at; do
      [ -n "$card" ] || continue
      history_record "$card" "$pr" "$head" "$merged_at"
    done < <(jq -r --argjson lanes "$LANES" '
      .[] as $c
      | select($c.state == "Ready to Deploy")
      | ($lanes | map(select(.linear_card_id == $c.id))) as $owners
      | select(($owners | length) == 1)
      | $owners[0] as $l
      | select($l.pr != ""
          and $l.pr_state == "MERGED" and $l.pr_head != ""
          and $l.pr_head_live == $l.pr_head and $l.pr_merged_at > 0)
      | [$c.id, $l.pr, $l.pr_head_live, $l.pr_merged_at] | @tsv
    ' < <(printf '%s' "$CARDS") 2>/dev/null || true)

    PREV_LANES=$(lane_history_json)
    if board_loop_paused; then PAUSED=true; else PAUSED=false; fi
    PAUSE_REASON=$(board_loop_pause_reason)
    REPORT=$(classify "$CARDS" "$LANES" "$DECISIONS" "$REMOTE" "$(history_json)" "$PREV_LANES" "$PAUSED" "$PAUSE_REASON" "$SOURCES")
    printf '%s' "$REPORT" | lane_history_write

    if [ "$MODE" = recover ]; then
      if board_loop_paused; then
        printf 'fm-board-loop: recovery is paused; no recovery steer was sent\n' >&2
      else
        printf '%s' "$REPORT" | jq -r '
          .causes[] as $cause | select($cause.recovery.kind == "steer")
          | ([.lanes[] | select(.task_id == $cause.task_id)][0]) as $lane
          | [(if (($lane.owner_task // "") != "") then $lane.owner_task else $cause.recovery.target end),
             ($cause.recovery.reason // $cause.detail)] | @tsv' \
          | recovery_ledger_sync
        while IFS=$'\t' read -r target reason card identifier; do
          [ -n "$target" ] || continue
          recover_target "$target" "$reason" "$card" "$identifier" || true
        done < <(printf '%s' "$REPORT" | jq -r '
          .causes[] as $cause | select($cause.recovery.kind == "steer")
          | ([.lanes[] | select(.task_id == $cause.task_id)][0]) as $lane
          | [(if (($lane.owner_task // "") != "") then $lane.owner_task else $cause.recovery.target end),
             ($cause.recovery.reason // $cause.detail), ($cause.card_id // ""),
             ($cause.identifier // "")] | @tsv')
      fi
    fi
    printf '%s\n' "$REPORT"
    ;;
  pause)
    action_pause
    ;;
  resume)
    action_resume
    ;;
esac
