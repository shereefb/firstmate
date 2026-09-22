#!/usr/bin/env bash
# fm-herdr-linear-reconcile.sh - read-only first-pass Operating Studio reconciliation.
#
# Usage:
#   fm-herdr-linear-reconcile.sh --inventory
#   fm-herdr-linear-reconcile.sh --linear-api
#
# `--inventory` is run by each owning home. It reads only that home's direct
# child metadata and asks Herdr for each recorded endpoint. A parent receives a
# fresh secondmate inventory through its registered route; it never enumerates
# the secondmate's panes itself.
# The comparison joins a Linear issue's immutable `id` to `linear_card_id=` in
# task metadata, and endpoint identity to the task's recorded Herdr ids. It
# deliberately does not inspect pane text, fm-crew-state, validation, or PRs.
# Any case those deeper checks must settle is reported as needs-deep-check.
#
# `--linear-api` fetches cards using LINEAR_API_KEY and
# FM_LINEAR_OPERATING_STUDIO_TEAM_ID and
# FM_LINEAR_OPERATING_STUDIO_PROJECT_ID. It never prints the API key.
#
# Output is one stable machine-readable JSON object. Comparison output uses
# schema fm-herdr-linear-reconcile.v1. This script is observational: it never
# changes Linear, task records, panes, or worker lifecycle.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

MODE=compare
LINEAR_API=0
ZEUS_ID=zeus

usage() {
  cat <<'EOF'
usage: fm-herdr-linear-reconcile.sh --inventory
       fm-herdr-linear-reconcile.sh --linear-api

Read-only Herdr and Linear reconciliation for Operating Studio cards.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --inventory) MODE=inventory ;;
    --linear-api) LINEAR_API=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[ "$MODE" = inventory ] || {
  [ "$LINEAR_API" = 1 ] || {
    echo 'fm-herdr-linear-reconcile: comparison requires --linear-api' >&2
    exit 2
  }
}
[ "$MODE" = compare ] || {
  [ "$LINEAR_API" = 0 ] || {
    echo 'fm-herdr-linear-reconcile: --inventory cannot be combined with --linear-api' >&2
    exit 2
  }
}

command -v jq >/dev/null 2>&1 || {
  echo 'fm-herdr-linear-reconcile: jq is required' >&2
  exit 1
}
command -v herdr >/dev/null 2>&1 || {
  echo 'fm-herdr-linear-reconcile: Herdr is unavailable; this Herdr-specific check cannot run' >&2
  exit 1
}
fm_backend_source herdr || {
  echo 'fm-herdr-linear-reconcile: Herdr backend support is unavailable; this Herdr-specific check cannot run' >&2
  exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-linear-reconcile.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

meta_value() { # <meta> <key>
  fm_meta_get "$1" "$2"
}

safe_field() { # metadata values become TSV fields
  case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;; esac
}

# local_inventory writes a compact, home-owned inventory. The only live lookup
# is the shared process-backed classifier for each recorded Herdr endpoint, not
# a global pane list or a title/order heuristic.
local_inventory() {
  local rows="$TMP/local.rows" meta id kind backend endpoint card session pane status
  : > "$rows"
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    kind=$(meta_value "$meta" kind)
    [ "$kind" = secondmate ] && continue
    backend=$(fm_backend_of_meta "$meta")
    endpoint=$(fm_backend_target_of_meta "$meta")
    card=$(meta_value "$meta" linear_card_id)
    session=$(meta_value "$meta" herdr_session)
    pane=$(meta_value "$meta" herdr_pane_id)
    status=not-applicable
    if [ "$backend" = herdr ]; then
      if [ -z "$session" ] || [ -z "$pane" ] || [ "$endpoint" != "$session:$pane" ]; then
        status=unreadable
      else
        status=$(fm_backend_agent_state "$backend" "$endpoint")
        case "$status" in alive|dead|missing|ambiguous|unreadable|unverified) : ;; *) status=unreadable ;; esac
      fi
    fi
    for value in "$id" "$card" "$backend" "$endpoint" "$session" "$pane" "$status"; do
      safe_field "$value" || {
        echo "fm-herdr-linear-reconcile: unsafe metadata field for task $id" >&2
        exit 1
      }
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$card" "$backend" "$endpoint" "$session" "$pane" "$status" >> "$rows"
  done
  jq -Rn --arg home "$FM_HOME" '
    [inputs
     | split("\t")
     | select(length == 7)
     | {task_id:.[0], linear_card_id:.[1], backend:.[2], endpoint:.[3],
        herdr_session:.[4], herdr_pane_id:.[5], endpoint_status:.[6]}]
    | sort_by(.task_id)
    | {schema:"fm-herdr-linear-inventory.v1", home:$home, children:.}
  ' < "$rows"
}

LOCAL=$(local_inventory) || exit $?
printf '%s\n' "$LOCAL" > "$TMP/local.json"

if [ "$MODE" = inventory ]; then
  printf '%s\n' "$LOCAL"
  exit 0
fi

if ! secondmate_registry_validate_bindings \
  "$DATA/secondmates.md" secondmate_registry_path_key "$ZEUS_ID"; then
  echo "fm-herdr-linear-reconcile: Zeus route is unavailable: $SECONDMATE_REGISTRY_ERROR" >&2
  exit 1
fi
zeus_registered_home=$SECONDMATE_REGISTRY_MATCH_HOME
if [ "$SECONDMATE_REGISTRY_MATCH_REMOTE" -eq 1 ]; then
  if ! "$SCRIPT_DIR/fm-on.sh" "$ZEUS_ID" \
    fm-herdr-linear-reconcile.sh --inventory > "$TMP/zeus.json"; then
    echo 'fm-herdr-linear-reconcile: could not obtain live Zeus inventory through its registered route' >&2
    exit 1
  fi
else
  if ! FM_HOME="$zeus_registered_home" \
    FM_STATE_OVERRIDE="$zeus_registered_home/state" \
    FM_DATA_OVERRIDE="$zeus_registered_home/data" \
    "$SCRIPT_DIR/fm-herdr-linear-reconcile.sh" --inventory > "$TMP/zeus.json"; then
    echo 'fm-herdr-linear-reconcile: could not obtain live Zeus inventory from its registered home' >&2
    exit 1
  fi
fi
jq -e '
  .schema == "fm-herdr-linear-inventory.v1"
  and ((.home | type) == "string" and (.home | length) > 0)
  and (.children | type) == "array"
  and all(.children[]?;
    ((.task_id | type) == "string" and (.task_id | length) > 0)
    and (.linear_card_id | type) == "string"
    and (.backend | type) == "string"
    and (.endpoint | type) == "string"
    and (.herdr_session | type) == "string"
    and (.herdr_pane_id | type) == "string"
    and (.endpoint_status as $status
      | ["alive", "dead", "missing", "ambiguous", "unreadable", "unverified", "not-applicable"]
      | index($status) != null))
' "$TMP/zeus.json" >/dev/null 2>&1 || {
  echo 'fm-herdr-linear-reconcile: Zeus inventory is invalid' >&2
  exit 1
}
zeus_home=$(jq -r '.home' "$TMP/zeus.json")
if [ "$zeus_home" != "$zeus_registered_home" ]; then
  echo "fm-herdr-linear-reconcile: live Zeus inventory returned home $zeus_home instead of $zeus_registered_home" >&2
  exit 1
fi

command -v curl >/dev/null 2>&1 || {
    echo 'fm-herdr-linear-reconcile: curl is required for --linear-api' >&2
    exit 1
  }
  [ -n "${LINEAR_API_KEY:-}" ] || {
    echo 'fm-herdr-linear-reconcile: LINEAR_API_KEY is required for --linear-api' >&2
    exit 1
  }
  [ -n "${FM_LINEAR_OPERATING_STUDIO_TEAM_ID:-}" ] || {
    echo 'fm-herdr-linear-reconcile: FM_LINEAR_OPERATING_STUDIO_TEAM_ID is required for --linear-api' >&2
    exit 1
  }
  [ -n "${FM_LINEAR_OPERATING_STUDIO_PROJECT_ID:-}" ] || {
    echo 'fm-herdr-linear-reconcile: FM_LINEAR_OPERATING_STUDIO_PROJECT_ID is required for --linear-api' >&2
    exit 1
  }
  printf '%s\n' '[]' > "$TMP/linear-cards.json"
  cursor=
  while :; do
    payload=$(jq -cn \
      --arg team "$FM_LINEAR_OPERATING_STUDIO_TEAM_ID" \
      --arg project "$FM_LINEAR_OPERATING_STUDIO_PROJECT_ID" \
      --arg after "$cursor" \
      '{query:"query OperatingStudioCards($team: ID!, $project: ID!, $after: String) { issues(first: 250, after: $after, filter: { team: { id: { eq: $team } }, project: { id: { eq: $project } }, state: { name: { in: [\"In Progress\", \"In Review\"] } } }) { nodes { id identifier state { name } } pageInfo { hasNextPage endCursor } } }",variables:{team:$team,project:$project,after:(if $after == "" then null else $after end)}}')
    if ! curl --fail --silent --show-error --max-time 15 \
      -H 'Content-Type: application/json' -H "Authorization: $LINEAR_API_KEY" \
      --data "$payload" https://api.linear.app/graphql > "$TMP/linear-api.json"; then
      echo 'fm-herdr-linear-reconcile: Linear API request failed' >&2
      exit 1
    fi
    if ! jq -e '
      ((.errors // []) | type == "array" and length == 0)
      and (.data.issues.nodes | type) == "array"
      and (.data.issues.pageInfo.hasNextPage | type) == "boolean"
      and ((.data.issues.pageInfo.endCursor | type) == "string" or .data.issues.pageInfo.endCursor == null)
      and (.data.issues.pageInfo.hasNextPage == false or (.data.issues.pageInfo.endCursor | type) == "string" and (.data.issues.pageInfo.endCursor | length) > 0)
    ' "$TMP/linear-api.json" >/dev/null 2>&1; then
      echo 'fm-herdr-linear-reconcile: Linear API returned an invalid response' >&2
      exit 1
    fi
    jq -s '.[0] + .[1].data.issues.nodes' "$TMP/linear-cards.json" "$TMP/linear-api.json" > "$TMP/linear-cards.next.json"
    mv "$TMP/linear-cards.next.json" "$TMP/linear-cards.json"
    [ "$(jq -r '.data.issues.pageInfo.hasNextPage' "$TMP/linear-api.json")" = true ] || break
    cursor=$(jq -r '.data.issues.pageInfo.endCursor' "$TMP/linear-api.json")
  done
  jq -e '
    map({id:(.id // ""), identifier:(.identifier // ""),
         state:(if (.state | type) == "object" then (.state.name // "") else (.state // "") end)})
    | if all(.[];
        ((.id | type) == "string" and (.id | length) > 0)
        and ((.identifier | type) == "string" and (.identifier | length) > 0)
        and (.state | type) == "string")
      then . else error("a card is missing id, identifier, or state") end
    | map(select(.state == "In Progress" or .state == "In Review"))
    | sort_by(.id, .identifier)
  ' "$TMP/linear-cards.json" > "$TMP/cards.json" || {
    echo 'fm-herdr-linear-reconcile: Linear API returned invalid cards' >&2
    exit 1
  }

REPORT=$(jq -n --slurpfile local "$TMP/local.json" --slurpfile zeus "$TMP/zeus.json" --slurpfile cards "$TMP/cards.json" '
  ($local[0].children + $zeus[0].children) as $workers
  | $cards[0] as $cards
  | [ $workers[] | select(.endpoint != "")
      | {endpoint, task_id} ]
    | group_by(.endpoint)
    | map(select(length > 1) | {endpoint:.[0].endpoint, task_ids:map(.task_id)}) as $duplicate_endpoints
  | [ $cards[] | .id ] | group_by(.) | map(select(length > 1) | .[0]) as $duplicate_cards
  | [ $cards[] as $card
      | ([ $workers[] | select(.linear_card_id == $card.id) ]) as $bound
      | if ($duplicate_cards | index($card.id)) then
          {kind:"duplicate-card", card_id:$card.id, identifier:$card.identifier,
           detail:"Linear returned the same card identity more than once"}
        elif ($bound | length) == 0 then
          {kind:"card-without-task-binding", card_id:$card.id, identifier:$card.identifier,
           detail:"no recorded Firstmate task binding"}
        elif ($bound | length) > 1 then
          {kind:"duplicate-ownership", card_id:$card.id, identifier:$card.identifier,
           task_ids:($bound | map(.task_id)), detail:"multiple tasks claim this card"}
        else $bound[0] as $worker
          | if ($duplicate_endpoints | map(.task_ids | index($worker.task_id)) | any) then
              {kind:"duplicate-endpoint", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, endpoint:$worker.endpoint,
               detail:"the recorded endpoint belongs to multiple tasks"}
            elif $worker.backend != "herdr" then
              {kind:"needs-deep-check", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, detail:"the recorded task is not Herdr-backed"}
            elif $worker.endpoint_status == "missing" then
              {kind:"missing-endpoint", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, endpoint:$worker.endpoint,
               detail:"Herdr has no agent for the recorded endpoint"}
            elif $worker.endpoint_status != "alive" then
              {kind:"needs-deep-check", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, endpoint:$worker.endpoint,
               detail:("Herdr cannot prove a live worker (endpoint status " + $worker.endpoint_status + ")")}
            else
              {kind:"matched-live-endpoint", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, endpoint:$worker.endpoint,
               detail:"recorded Herdr endpoint has a live agent process"}
            end
        end
    ] as $card_findings
  | [ $workers[] as $worker
      | select(($worker.linear_card_id | length) == 0 or ([ $cards[] | select(.id == $worker.linear_card_id) ] | length) == 0)
      | {kind:"worker-without-applicable-card", task_id:$worker.task_id,
         endpoint:$worker.endpoint, detail:"worker does not have an applicable In Progress or In Review card"}
    ] as $worker_findings
  | {schema:"fm-herdr-linear-reconcile.v1", local_inventory:$local[0], zeus_inventory:$zeus[0],
     cards:$cards,
     findings:(($card_findings + $worker_findings) | sort_by(.kind, (.card_id // ""), (.task_id // ""))),
     summary:{cards:($cards | length), workers:($workers | length),
              matched:([$card_findings[] | select(.kind == "matched-live-endpoint")] | length),
              needs_deep_check:([($card_findings + $worker_findings)[] | select(.kind != "matched-live-endpoint")] | length)}}
')

printf '%s\n' "$REPORT"
