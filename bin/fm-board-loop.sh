#!/usr/bin/env bash
# fm-board-loop.sh - one board-level detect -> investigate -> recover -> verify
# pass over the Operating Studio Linear board and the workers bound to it.
#
# Usage:
#   fm-board-loop.sh [scan] [--cards <file>] [--remote-inventory <file>]
#   fm-board-loop.sh inventory
#   fm-board-loop.sh recover [--cards <file>] [--remote-inventory <file>]
#   fm-board-loop.sh pause [--reason <text>]
#   fm-board-loop.sh resume
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
#     fails CLOSED while a durable stop posture is active: the
#     `state/.board-loop-pause` marker written by `pause` and removed by
#     `resume`, the FM_BOARD_LOOP_PAUSE=1 process override, or a configured
#     stop-status file (FM_BOARD_LOOP_STOP_STATUS) whose newest stop-key line is
#     paused/blocked. A live endpoint is never evidence that recovery is safe.
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
#   FM_BOARD_LOOP_PR_PROBE_CMD        `<probe> <url>` -> {"state","isDraft","headRefOid"}
#   FM_BOARD_LOOP_SEND_CMD            bounded recovery steer command
#   FM_BOARD_LOOP_STALL_SECS          stall window for an unmoved disposition, default 1800
#   FM_BOARD_LOOP_PAUSE               set to 1 to force recovery closed
#   FM_BOARD_LOOP_STOP_STATUS         status file whose stop-key line gates recovery
#   FM_BOARD_LOOP_STOP_KEYS           space-separated stop keys, default operating-studio-stop
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
LINEAR_CONFIG_FILE=${FM_LINEAR_CONFIG_FILE:-$FM_HOME/.env.linear.local}
HISTORY="$STATE/.board-loop-deploy-history"
STALL_LEDGER="$STATE/.board-loop-stall.tsv"
RECOVERY_LEDGER="$STATE/.board-loop-recovery.jsonl"
PAUSE_MARKER="$STATE/.board-loop-pause"
INVENTORY_SCHEMA='fm-board-inventory.v1'
REPORT_SCHEMA='fm-board-loop.v1'
DEPLOY_WINDOW_SECS=3600
HISTORY_RETAIN_SECS=86400
STALL_SECS_DEFAULT=1800
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
       fm-board-loop.sh resume
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    scan) MODE=scan ;;
    inventory) MODE=inventory ;;
    recover) MODE=recover ;;
    pause) MODE=pause ;;
    resume) MODE=resume ;;
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

# board_loop_stop_status_signal reports a configured stop-status file whose
# newest line for a stop key is a paused or blocked declaration. A later
# resolved/working/done/failed line for the same key clears it.
board_loop_stop_status_signal() {
  local f=${FM_BOARD_LOOP_STOP_STATUS:-} key line verb
  [ -n "$f" ] && [ -f "$f" ] && [ ! -L "$f" ] || return 1
  # shellcheck disable=SC2086
  for key in ${FM_BOARD_LOOP_STOP_KEYS:-operating-studio-stop}; do
    line=$(grep -F -- "[key=$key]" "$f" 2>/dev/null | tail -n 1)
    [ -n "$line" ] || continue
    status_line_verb "$line" verb
    case "$verb" in
      paused|blocked) return 0 ;;
    esac
  done
  return 1
}

# board_loop_paused is the single guard read by the recovery path. It is true
# when the durable pause marker exists, the process override is set, or a
# configured stop-status file's newest stop-key line is paused/blocked. It never
# consults endpoint liveness: a live endpoint is not evidence recovery is safe.
board_loop_paused() {
  if [ -f "$PAUSE_MARKER" ] && [ ! -L "$PAUSE_MARKER" ]; then return 0; fi
  if [ "${FM_BOARD_LOOP_PAUSE:-}" = 1 ]; then return 0; fi
  board_loop_stop_status_signal
}

action_pause() {
  local tmp
  mkdir -p "$STATE" 2>/dev/null || true
  tmp=$(umask 077; mktemp "$STATE/.board-loop-pause.XXXXXX") || return 1
  if printf 'since=%s\nreason=%s\n' "$NOW" "${PAUSE_REASON:-manual pause}" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f "$tmp" "$PAUSE_MARKER"; then
    printf 'paused: board recovery suspended (%s)\n' "${PAUSE_REASON:-manual pause}"
    return 0
  fi
  rm -f "$tmp"
  printf 'fm-board-loop: could not write the pause marker\n' >&2
  return 1
}

action_resume() {
  rm -f "$PAUSE_MARKER"
  printf 'resumed: board recovery re-enabled\n'
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
#   {"state":"OPEN|MERGED|CLOSED","isDraft":bool,"headRefOid":"<sha>"}
# An unavailable probe yields nothing, which the caller records as unknown.
pr_probe() { # <pr-url>
  local url=$1 cmd=${FM_BOARD_LOOP_PR_PROBE_CMD:-}
  [ -n "$cmd" ] && [ -n "$url" ] || return 1
  # shellcheck disable=SC2086
  $cmd "$url" 2>/dev/null
}

# linear_cards returns a JSON array of the four active board columns, read from
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
      {query:"query Board($team: ID!, $project: ID!, $after: String) { issues(first: 250, after: $after, filter: { team: { id: { eq: $team } }, project: { id: { eq: $project } }, state: { name: { in: [\"In Progress\", \"In Review\", \"Ready to Merge\", \"Ready to Deploy\"] } } }) { nodes { id identifier title url state { name } } pageInfo { hasNextPage endCursor } } }",
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

endpoint_status_of() { # <session> <pane>
  local session=$1 pane=$2 status cmd=${FM_BOARD_LOOP_ENDPOINT_STATUS_CMD:-}
  [ -n "$session" ] && [ -n "$pane" ] || { printf 'unavailable\n'; return 0; }
  if [ -n "$cmd" ]; then
    status=$("$cmd" "$session:$pane" 2>/dev/null) || status=unreadable
  else
    status=$(fm_backend_agent_state herdr "$session:$pane" 2>/dev/null) || status=unreadable
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
      printf '%s\t%s\n' "$id" "$v" >> "$out"
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

# --- decision ledger ----------------------------------------------------------

# decision_state_of prints one TSV row per still-open decision key:
#   <key>\t<verb>\t<delivered>\t<acknowledged>\t<ring-attempts>
# `delivered` is an inbox record; an acknowledged record is one in handled/.
# Delivery is never completion: a decision is consumed only once the worker
# also reaches a productive or terminal disposition.
decision_state_of() { # <task-id>
  local id=$1
  local status="$STATE/$id.status" inbox="$STATE/$id.inbox"
  local key verb note delivered handed attempts f line msg count
  while IFS=$'\t' read -r key verb note || [ -n "${key:-}" ]; do
    [ -n "$key" ] || continue
    delivered=0
    handed=0
    if [ -d "$inbox" ] && [ ! -L "$inbox" ]; then
      for f in "$inbox"/*.msg; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        delivered=1
      done
      for f in "$inbox/handled"/*.msg; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        delivered=1
        handed=1
      done
    fi
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
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$verb" "$delivered" "$handed" "$attempts"
  done < <(status_open_decisions "$status" 2>/dev/null || true)
}

# --- lane and decision collection ---------------------------------------------

lane_json() { # <task-id> <kind> <backend> <endpoint> <card> <agent> <endpoint-status> \
             # <disposition> <validation> <terminal-bool> <pr> <pr-head> \
             # <pr-state> <pr-draft-bool> <pr-head-live> <status-verb> <status-size>
  jq -cn \
    --arg task_id "$1" --arg kind "$2" --arg backend "$3" --arg endpoint "$4" \
    --arg linear_card_id "$5" --arg agent_status "$6" --arg endpoint_status "$7" \
    --arg disposition "$8" --arg validation "$9" --argjson terminal "${10}" \
    --arg pr "${11}" --arg pr_head "${12}" --arg pr_state "${13}" \
    --argjson pr_draft "${14}" --arg pr_head_live "${15}" --arg status_verb "${16}" \
    --argjson status_size "${17}" \
    '{task_id:$task_id, kind:$kind, backend:$backend, endpoint:$endpoint,
      linear_card_id:$linear_card_id, agent_status:$agent_status,
      endpoint_status:$endpoint_status, disposition:$disposition,
      validation:$validation, terminal:$terminal, pr:$pr, pr_head:$pr_head,
      pr_state:$pr_state, pr_draft:$pr_draft, pr_head_live:$pr_head_live,
      status_verb:$status_verb, status_size:$status_size}'
}

collect_lanes() { # -> JSON array
  local meta id kind backend endpoint card session pane agent endstat
  local status verb disposition validation terminal pr pr_head
  local pr_state pr_draft pr_head_live out lines=() status_size
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
    if [ "$backend" = herdr ] && [ -n "$session" ] && [ -n "$pane" ] && [ "$endpoint" = "$session:$pane" ]; then
      agent=$(agent_status_of "$session" "$pane")
      endstat=$(endpoint_status_of "$session" "$pane")
    else
      agent=unavailable
      endstat=not-applicable
    fi
    verb=$(status_current_line "$STATE/$id.status" "$kind" 2>/dev/null) || verb=
    verb=${verb%% *}
    [ -n "$verb" ] || verb=unknown
    if [ "$terminal" = 1 ]; then
      disposition=terminal
    else
      disposition=$(disposition_of "$verb" "$agent")
    fi
    validation=$(validation_lookup "$id")
    pr_state=unknown
    pr_draft=false
    pr_head_live=
    if [ -n "$pr" ]; then
      out=$(pr_probe "$pr") || out=
      if [ -n "$out" ]; then
        pr_state=$(printf '%s' "$out" | jq -r '.state // "unknown"' 2>/dev/null) || pr_state=unknown
        pr_draft=$(printf '%s' "$out" | jq -r '.isDraft // false' 2>/dev/null) || pr_draft=false
        pr_head_live=$(printf '%s' "$out" | jq -r '.headRefOid // ""' 2>/dev/null) || pr_head_live=
      fi
    fi
    case "$pr_draft" in true|false) ;; *) pr_draft=false ;; esac
    if [ -f "$STATE/$id.status" ]; then
      status_size=$(wc -c < "$STATE/$id.status" 2>/dev/null | tr -d '[:space:]')
    else
      status_size=0
    fi
    case "$status_size" in ''|*[!0-9]*) status_size=0 ;; esac
    if [ "$terminal" = 1 ]; then
      lines+=("$(lane_json "$id" "$kind" "$backend" "$endpoint" "$card" "$agent" "$endstat" \
        "$disposition" "$validation" true "$pr" "$pr_head" "$pr_state" "$pr_draft" "$pr_head_live" "$verb" "$status_size")")
    else
      lines+=("$(lane_json "$id" "$kind" "$backend" "$endpoint" "$card" "$agent" "$endstat" \
        "$disposition" "$validation" false "$pr" "$pr_head" "$pr_state" "$pr_draft" "$pr_head_live" "$verb" "$status_size")")
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
    while IFS=$'\t' read -r key verb delivered handed attempts; do
      [ -n "$key" ] || continue
      lines+=("$(jq -cn --arg task_id "$id" --arg key "$key" --arg verb "$verb" \
        --argjson delivered "$delivered" --argjson acknowledged "$handed" \
        --argjson ring_attempts "$attempts" \
        '{task_id:$task_id, key:$key, verb:$verb, delivered:$delivered,
          acknowledged:$acknowledged, ring_attempts:$ring_attempts}')")
    done < <(decision_state_of "$id")
  done
  [ "${#lines[@]}" -gt 0 ] || { printf '[]\n'; return 0; }
  printf '%s\n' "${lines[@]}" | jq -cs '.'
}

collect_remote() { # -> JSON array of remote inventories
  local file=${REMOTE_FILE:-${FM_BOARD_LOOP_REMOTE_INVENTORY:-}}
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || { printf '[]\n'; return 0; }
    jq -c 'if type == "array" then . else [.] end' "$file" 2>/dev/null || printf '[]\n'
    return 0
  fi
  printf '[]\n'
}

# --- deployment ledger --------------------------------------------------------

history_prune() {
  local tmp
  if [ ! -f "$HISTORY" ] || [ -L "$HISTORY" ]; then
    : > "$HISTORY" 2>/dev/null || true
    return 0
  fi
  tmp=$(mktemp "$STATE/.board-loop-history.XXXXXX" 2>/dev/null) || return 0
  if awk -F'\t' -v now="$NOW" -v keep="$HISTORY_RETAIN_SECS" '
      NF >= 2 { ts=$1; if (ts ~ /^[0-9]+$/ && now - ts <= keep) print }
    ' "$HISTORY" > "$tmp" 2>/dev/null && mv -f "$tmp" "$HISTORY" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
}

# history_record appends one verified deployment without duplicating an
# existing (card, head) pair, or an existing (card, pr) pair when the head is
# unknown. Idempotent across reruns.
history_record() { # <card-id> <pr-url> <head>
  local card=$1 pr=$2 head=$3
  [ -n "$card" ] || return 0
  [ -f "$HISTORY" ] && [ ! -L "$HISTORY" ] || : > "$HISTORY" 2>/dev/null || true
  if [ -n "$head" ]; then
    if awk -F'\t' -v c="$card" -v h="$head" 'NF >= 4 && $2 == c && $4 == h { found=1 } END { exit found ? 0 : 1 }' "$HISTORY" 2>/dev/null; then
      return 0
    fi
  else
    if awk -F'\t' -v c="$card" -v p="$pr" 'NF >= 3 && $2 == c && $3 == p { found=1 } END { exit found ? 0 : 1 }' "$HISTORY" 2>/dev/null; then
      return 0
    fi
  fi
  printf '%s\t%s\t%s\t%s\n' "$NOW" "$card" "$pr" "$head" >> "$HISTORY" 2>/dev/null || true
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
  local lanes
  prepare_validations
  lanes=$(collect_lanes)
  jq -cn --arg home "$FM_HOME" --argjson lanes "$lanes" \
    '{schema:"'"$INVENTORY_SCHEMA"'", home:$home, lanes:$lanes}'
}

# --- classification -----------------------------------------------------------

classify() { # <cards-json> <lanes-json> <decisions-json> <remote-json> <history-json> <prev-lanes-json> <paused> <pause-reason>
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
    --arg schema "$REPORT_SCHEMA" '
    def active: . == "In Progress" or . == "In Review" or . == "Ready to Merge";
    def productive:
      .agent_status == "working"
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
            | if ($l.pr_head != "" and $l.pr_head_live != "" and $l.pr_head != $l.pr_head_live
                  and $l.pr_state == "OPEN") then
                {kind:"head-drift", task_id:$l.task_id, card_id:$c.id, identifier:$c.identifier,
                 card_state:$c.state,
                 detail:("recorded PR head " + $l.pr_head + " differs from the live head " + $l.pr_head_live),
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"re-verify the exact PR head before any landing decision"}}
              elif $c.state == "In Review" and $l.pr == "" then
                {kind:"in-review-without-pr", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"card is In Review but the worker records no PR",
                 recovery:{kind:"steer", target:$l.task_id,
                   reason:"attach the canonical PR URL or move the card back to In Progress"}}
              elif $c.state == "Ready to Merge" and $l.pr_state != "MERGED" then
                {kind:"ready-to-merge-unlanded", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"reviewed candidate is Ready to Merge but not landed",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"land the reviewed candidate serially and verify the readback"}}
              elif $c.state == "Ready to Deploy" and $l.pr_state != "MERGED" then
                {kind:"ready-to-deploy-unverified", task_id:$l.task_id, card_id:$c.id,
                 identifier:$c.identifier, card_state:$c.state,
                 detail:"card is Ready to Deploy without a merged canonical PR",
                 recovery:{kind:"escalate", target:$l.task_id,
                   reason:"verify the landing before counting this card as deployed"}}
              elif $l.pr != "" and $c.state == "In Progress" and $l.pr_state == "OPEN"
                   and $l.pr_draft == false
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
              elif (($l.agent_status == "unavailable" or $l.endpoint_status == "missing"
                    or $l.endpoint_status == "dead")
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
        | if $d.verb == "blocked" then
            if $d.delivered != 1 then
              {kind:"blocked-undelivered", task_id:$d.task_id, card_id:null, identifier:null,
               detail:"blocker recorded but the clearing instruction never reached the worker inbox",
               recovery:{kind:"steer", target:$d.task_id,
                 reason:("clear blocker key " + $d.key + " and verify acknowledgement")}}
            else
              {kind:"blocked-lane", task_id:$d.task_id, card_id:null, identifier:null,
               detail:("lane reports a blocker: " + ($d.key // "default")),
               recovery:{kind:"escalate", target:$d.task_id,
                 reason:("clear or reassign the blocker for key " + $d.key)}}
            end
          elif $d.delivered != 1 then
            {kind:"decision-recorded-undelivered", task_id:$d.task_id, card_id:null,
             identifier:null, detail:"decision recorded but not delivered to the worker inbox",
             recovery:{kind:"steer", target:$d.task_id,
               reason:("answer decision key " + $d.key + " and verify acknowledgement")}}
          elif $d.acknowledged != 1 and $d.ring_attempts >= 3 then
            {kind:"decision-delivered-unacknowledged", task_id:$d.task_id, card_id:null,
             identifier:null, detail:"decision delivered but unacknowledged after the bounded ring ladder",
             recovery:{kind:"escalate", target:$d.task_id,
               reason:"deliver the decision through a reachable channel and verify acknowledgement"}}
          elif $d.acknowledged != 1 then
            {kind:"decision-delivered-unacknowledged", task_id:$d.task_id, card_id:null,
             identifier:null, detail:"decision delivered but the worker has not acknowledged it",
             recovery:{kind:"steer", target:$d.task_id,
               reason:("acknowledge and consume decision key " + $d.key)}}
          elif $l != null and ($l.disposition != "working" and $l.disposition != "terminal")
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
    | [ $remote[] as $inv
        | {kind:"remote-inventory", home:($inv.home // ""),
           lanes:(($inv.lanes // []) | length), detail:"remote inventory included"} ] as $remote_rows
    | ([ $history[] | select((.ts | type) == "number" and ($now - .ts) <= $window) ] | length) as $landed
    | ([ $joined[] | select(productive) ] | length) as $productive
    | ([ $joined[] | select(.card_state != null and (.card_state | active)
          and .disposition != "terminal") ] | length) as $eligible_active
    | ([ $cards[] | select(.state == "Ready to Deploy") ] | length) as $rtd
    | (($card_causes + $decision_causes + $unbound_causes)) as $causes
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
          fault:(($landed == 0 and $eligible_active > 0) and ($paused | not))},
        paused:$paused,
        pause_reason:$pause_reason,
        decisions:($decisions),
        remote:($remote_rows),
        summary:{cards:($cards | length), causes:($causes | length),
          end_to_end_fault:((($landed == 0 and $eligible_active > 0) and ($paused | not))
            or any($causes[]; .kind == "endpoint-unavailable"))}
      }'
}

# --- recover ------------------------------------------------------------------

# recover_target steers one task through the durable inbox, at most once per
# (task, reason) signature so a periodic pass never spams a lane. The marker
# ledger is the idempotence guard; a failed send is retried on the next pass.
recover_target() { # <task-id> <reason>
  local id=$1 reason=$2 sig send_cmd=${FM_BOARD_LOOP_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}
  task_id_valid "$id" || return 1
  sig=$(printf '%s' "$reason" | shasum 2>/dev/null | cut -d' ' -f1)
  [ -n "$sig" ] || sig=$(printf '%s' "$reason" | cksum 2>/dev/null | awk '{print $1}')
  [ -n "$sig" ] || return 1
  if [ -f "$RECOVERY_LEDGER" ] && [ ! -L "$RECOVERY_LEDGER" ] \
    && awk -F'\t' -v id="$id" -v sig="$sig" '$1 == id && $2 == sig { found=1 } END { exit found ? 0 : 1 }' \
      "$RECOVERY_LEDGER" 2>/dev/null; then
    return 0
  fi
  if FM_HOME="$FM_HOME" $send_cmd "$id" "$reason" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\n' "$id" "$sig" "$NOW" >> "$RECOVERY_LEDGER" 2>/dev/null || true
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
    history_prune
    CARDS=$(linear_cards) || CARDS='[]'
    prepare_validations
    LANES=$(collect_lanes)
    DECISIONS=$(collect_decisions)
    REMOTE=$(collect_remote)

    # Record newly verified Ready to Deploy cards before the throughput read so
    # this pass's own verified landings count inside the rolling hour.
    while IFS=$'\t' read -r card pr head; do
      [ -n "$card" ] || continue
      history_record "$card" "$pr" "$head"
    done < <(jq -r --argjson lanes "$LANES" '
      .[] as $c
      | select($c.state == "Ready to Deploy")
      | ($lanes | map(select(.linear_card_id == $c.id and .pr != ""
          and .pr_state == "MERGED")) | .[0]) as $l
      | select($l != null)
      | [$c.id, $l.pr, ($l.pr_head_live // $l.pr_head)] | @tsv
    ' < <(printf '%s' "$CARDS") 2>/dev/null || true)
    history_prune

    PREV_LANES=$(lane_history_json)
    if board_loop_paused; then PAUSED=true; else PAUSED=false; fi
    PAUSE_REASON=$(board_loop_pause_reason)
    REPORT=$(classify "$CARDS" "$LANES" "$DECISIONS" "$REMOTE" "$(history_json)" "$PREV_LANES" "$PAUSED" "$PAUSE_REASON")
    printf '%s' "$REPORT" | lane_history_write

    if [ "$MODE" = recover ]; then
      if board_loop_paused; then
        printf 'fm-board-loop: recovery is paused; no recovery steer was sent\n' >&2
      else
        while IFS=$'\t' read -r target reason; do
          [ -n "$target" ] || continue
          recover_target "$target" "$reason" || true
        done < <(printf '%s' "$REPORT" | jq -r '
          .causes[] | select(.recovery.kind == "steer")
          | [.recovery.target, (.recovery.reason // .detail)] | @tsv')
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