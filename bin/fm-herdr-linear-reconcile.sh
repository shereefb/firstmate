#!/usr/bin/env bash
# fm-herdr-linear-reconcile.sh - read-only first-pass Operating Studio reconciliation.
#
# Usage:
#   fm-herdr-linear-reconcile.sh --inventory
#   fm-herdr-linear-reconcile.sh --linear-api
#
# `--inventory` is run by each owning home. It joins direct child metadata with
# exact workspaces proven by its registered owner, live owner, or projections.
# A parent receives a fresh secondmate inventory through its registered route;
# it never enumerates the secondmate's panes itself.
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
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"

MODE=compare
LINEAR_API=0
ZEUS_ID=${FM_LINEAR_ZEUS_ROUTE_ID:-zeus}

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

task_id_valid() {
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

task_id_valid "$ZEUS_ID" || {
  echo 'fm-herdr-linear-reconcile: FM_LINEAR_ZEUS_ROUTE_ID is invalid' >&2
  exit 1
}

append_worker_identity() { # <rows> <task-id> <session> <pane>
  local rows=$1 task_id=$2 session=$3 pane=$4 endpoint value
  task_id_valid "$task_id" || {
    echo "fm-herdr-linear-reconcile: invalid live Herdr task identity $task_id" >&2
    return 1
  }
  endpoint="$session:$pane"
  for value in "$task_id" "$endpoint" "$session" "$pane"; do
    safe_field "$value" || {
      echo "fm-herdr-linear-reconcile: unsafe live Herdr worker identity for task $task_id" >&2
      return 1
    }
  done
  printf '%s\t\therdr\t%s\t%s\t%s\tpending\n' \
    "$task_id" "$endpoint" "$session" "$pane" >> "$rows"
}

resolve_inventory_owner() {
  local marker="$FM_HOME/.fm-secondmate-home" parent="$FM_HOME/.fm-secondmate-parent"
  local owner meta recorded_home canonical_home canonical_recorded status pane_out owner_location
  local workspaces_out tabs_out
  INVENTORY_OWNER_SESSION=
  INVENTORY_OWNER_REGISTERED_WORKSPACE=
  INVENTORY_OWNER_WORKSPACE=
  INVENTORY_OWNER_TAB=
  INVENTORY_OWNER_PANE=
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    owner=$(cat "$marker" 2>/dev/null) || return 1
    task_id_valid "$owner" || return 1
    fm_secondmate_parent_record_parse "$parent" || return 1
    case "$FM_SECONDMATE_PARENT_ROUTE" in
      local) meta="$FM_SECONDMATE_PARENT_HOME/state/$owner.meta" ;;
      remote) meta="$STATE/parent-route/$owner.meta" ;;
      *) return 1 ;;
    esac
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    [ "$(meta_value "$meta" kind)" = secondmate ] || return 1
    recorded_home=$(meta_value "$meta" home)
    canonical_home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
    canonical_recorded=$(CDPATH='' cd -- "$recorded_home" 2>/dev/null && pwd -P) || return 1
    [ "$canonical_recorded" = "$canonical_home" ] || return 1
    fm_backend_validate_task_endpoint "$meta" "$owner" 2>/dev/null || return 1
    [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || return 1
    INVENTORY_OWNER_SESSION=$(meta_value "$meta" herdr_session)
    INVENTORY_OWNER_REGISTERED_WORKSPACE=$(meta_value "$meta" herdr_workspace_id)
    INVENTORY_OWNER_PANE=$(meta_value "$meta" herdr_pane_id)
    [ "$FM_BACKEND_VALIDATED_TARGET" = "$INVENTORY_OWNER_SESSION:$INVENTORY_OWNER_PANE" ] \
      && [ -n "$INVENTORY_OWNER_REGISTERED_WORKSPACE" ] || return 1
  else
    INVENTORY_OWNER_SESSION=$(fm_backend_herdr_session)
    fm_backend_herdr_launcher_identity "$INVENTORY_OWNER_SESSION" && status=0 || status=$?
    [ "$status" -eq 0 ] || return 1
    INVENTORY_OWNER_REGISTERED_WORKSPACE=${HERDR_WORKSPACE_ID:-}
    INVENTORY_OWNER_PANE=$FM_BACKEND_HERDR_LAUNCHER_PANE_ID
  fi
  [ "$(fm_backend_agent_state herdr "$INVENTORY_OWNER_SESSION:$INVENTORY_OWNER_PANE")" = alive ] \
    || return 1
  pane_out=$(fm_backend_herdr_cli "$INVENTORY_OWNER_SESSION" pane get "$INVENTORY_OWNER_PANE" 2>/dev/null) \
    || return 1
  owner_location=$(printf '%s' "$pane_out" | jq -er --arg pane "$INVENTORY_OWNER_PANE" '
    .result.pane
    | select(.pane_id == $pane)
    | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    | select((.tab_id | type) == "string" and (.tab_id | length) > 0)
    | [.workspace_id, .tab_id]
    | @tsv
  ') || return 1
  IFS=$'\t' read -r INVENTORY_OWNER_WORKSPACE INVENTORY_OWNER_TAB <<< "$owner_location"
  [ -n "$INVENTORY_OWNER_WORKSPACE" ] && [ -n "$INVENTORY_OWNER_TAB" ] || return 1
  if [ -z "$INVENTORY_OWNER_REGISTERED_WORKSPACE" ]; then
    INVENTORY_OWNER_REGISTERED_WORKSPACE=$INVENTORY_OWNER_WORKSPACE
  fi
  safe_field "$INVENTORY_OWNER_SESSION" \
    && safe_field "$INVENTORY_OWNER_REGISTERED_WORKSPACE" \
    && safe_field "$INVENTORY_OWNER_WORKSPACE" \
    && safe_field "$INVENTORY_OWNER_TAB" \
    && safe_field "$INVENTORY_OWNER_PANE" || return 1
  workspaces_out=$(fm_backend_herdr_cli "$INVENTORY_OWNER_SESSION" workspace list 2>/dev/null) \
    || return 1
  printf '%s' "$workspaces_out" | jq -e --arg workspace "$INVENTORY_OWNER_WORKSPACE" '
    (.result.workspaces | type) == "array"
    and ([.result.workspaces[] | select(.workspace_id == $workspace)] | length) == 1
  ' >/dev/null 2>&1 || return 1
  tabs_out=$(fm_backend_herdr_cli "$INVENTORY_OWNER_SESSION" tab list \
    --workspace "$INVENTORY_OWNER_WORKSPACE" 2>/dev/null) || return 1
  printf '%s' "$tabs_out" | jq -e --arg tab "$INVENTORY_OWNER_TAB" '
    (.result.tabs | type) == "array"
    and ([.result.tabs[] | select(.tab_id == $tab)] | length) == 1
  ' >/dev/null 2>&1
}

discover_owned_flat_workers() { # <rows> <workspaces>
  local rows=$1 workspaces=$2 session workspace workspaces_out matches current owner_session
  local tabs panes pane task_id index=0
  while IFS=$'\t' read -r session workspace; do
    [ -n "$session" ] && [ -n "$workspace" ] || continue
    workspaces_out=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
    matches=$(printf '%s' "$workspaces_out" | jq -er --arg workspace "$workspace" '
      .result.workspaces
      | select(type == "array")
      | [.[] | select(.workspace_id == $workspace)]
      | length
    ' 2>/dev/null) || return 1
    current=0
    [ "$session" != "$INVENTORY_OWNER_SESSION" ] \
      || [ "$workspace" != "$INVENTORY_OWNER_WORKSPACE" ] || current=1
    if [ "$matches" -eq 0 ]; then
      [ "$current" -eq 0 ] || return 1
      continue
    fi
    [ "$matches" -eq 1 ] || return 1
    owner_session=0
    [ "$session" != "$INVENTORY_OWNER_SESSION" ] || owner_session=1
    index=$((index + 1))
    tabs="$TMP/herdr-owned-tabs.$index.json"
    panes="$TMP/herdr-owned-panes.$index.json"
    if ! fm_backend_herdr_cli "$session" tab list \
        --workspace "$workspace" > "$tabs" 2>/dev/null \
      || ! jq -e '(.result.tabs | type) == "array" and all(.result.tabs[]?;
        (.tab_id | type) == "string" and (.tab_id | length) > 0
        and (.label | type) == "string")' "$tabs" >/dev/null 2>&1 \
      || ! fm_backend_herdr_cli "$session" pane list \
        --workspace "$workspace" > "$panes" 2>/dev/null \
      || ! jq -e --argjson current "$current" --argjson owner_session "$owner_session" \
        --arg owner_pane "$INVENTORY_OWNER_PANE" \
        --arg owner_tab "$INVENTORY_OWNER_TAB" '
        (.result.panes | type) == "array" and all(.result.panes[]?;
        (.pane_id | type) == "string" and (.pane_id | length) > 0
        and (.tab_id | type) == "string" and (.tab_id | length) > 0)
        and if $current == 1 then
          ([.result.panes[] | select(.pane_id == $owner_pane)] | length) == 1
          and any(.result.panes[];
            .pane_id == $owner_pane and .tab_id == $owner_tab)
        elif $owner_session == 1 then
          ([.result.panes[] | select(.pane_id == $owner_pane)] | length) == 0
        else true
        end
      ' "$panes" >/dev/null 2>&1; then
      echo "fm-herdr-linear-reconcile: could not enumerate inventory Herdr workspace $workspace" >&2
      return 1
    fi
    while IFS=$'\t' read -r pane task_id; do
      [ -n "$pane" ] || continue
      append_worker_identity "$rows" "$task_id" "$session" "$pane" || return 1
    done < <(jq -r --slurpfile panes "$panes" --argjson owner_session "$owner_session" \
      --arg owner_pane "$INVENTORY_OWNER_PANE" '
      .result.tabs[]
      | select(.label | startswith("fm-") and length > 3)
      | . as $tab
      | $panes[0].result.panes[]
      | select(.tab_id == $tab.tab_id)
      | select($owner_session == 0 or .pane_id != $owner_pane)
      | [.pane_id, $tab.label[3:]]
      | @tsv
    ' "$tabs")
  done < "$workspaces"
}

discover_projected_workers() { # <rows> <workspaces>
  local rows=$1 workspaces=$2 canonical_home journal task_id
  canonical_home=$(fm_backend_herdr_projection_home_identity "$FM_HOME") || {
    echo 'fm-herdr-linear-reconcile: could not resolve the inventory home identity' >&2
    return 1
  }
  for journal in "$STATE"/*.herdr-presentation; do
    [ -e "$journal" ] || [ -L "$journal" ] || continue
    task_id=${journal##*/}; task_id=${task_id%.herdr-presentation}
    task_id_valid "$task_id" \
      && fm_backend_herdr_projection_journal_snapshot "$journal" "$task_id" \
      && [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] || {
        echo "fm-herdr-linear-reconcile: projection ownership is incomplete for task $task_id" >&2
        return 1
      }
    [ "$FM_BACKEND_HERDR_JOURNAL_HOME" = "$canonical_home" ] || {
      echo "fm-herdr-linear-reconcile: projection home identity does not match task $task_id" >&2
      return 1
    }
    fm_backend_herdr_projection_live_binding_matches \
      "$FM_BACKEND_HERDR_JOURNAL_SESSION" "$FM_BACKEND_HERDR_JOURNAL_PROJECTION_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" \
      "$FM_BACKEND_HERDR_JOURNAL_PARENT_LABEL" "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_LABEL" \
      "$FM_BACKEND_HERDR_JOURNAL_TASK_LABEL" || {
        echo "fm-herdr-linear-reconcile: projection binding is unavailable for task $task_id" >&2
        return 1
      }
    printf '%s\t%s\n' \
      "$FM_BACKEND_HERDR_JOURNAL_SESSION" \
      "$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID" >> "$workspaces"
    append_worker_identity "$rows" "$task_id" "$FM_BACKEND_HERDR_JOURNAL_SESSION" \
      "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" || return 1
  done
}

discover_live_workers() { # <rows>
  local workspaces="$TMP/herdr-owned-workspaces"
  : > "$1"
  : > "$workspaces"
  resolve_inventory_owner || {
    echo 'fm-herdr-linear-reconcile: could not verify the inventory home Herdr owner' >&2
    return 1
  }
  printf '%s\t%s\n%s\t%s\n' \
    "$INVENTORY_OWNER_SESSION" "$INVENTORY_OWNER_REGISTERED_WORKSPACE" \
    "$INVENTORY_OWNER_SESSION" "$INVENTORY_OWNER_WORKSPACE" >> "$workspaces"
  discover_projected_workers "$1" "$workspaces" || return 1
  sort -u -o "$workspaces" "$workspaces" || return 1
  discover_owned_flat_workers "$1" "$workspaces"
}

local_inventory() {
  local rows="$TMP/local.rows" live_rows="$TMP/local-live.rows"
  local meta id kind backend endpoint card session pane status value
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -r "$STATE" ] && [ -x "$STATE" ] || {
    echo "fm-herdr-linear-reconcile: inventory state directory is unavailable: $STATE" >&2
    return 1
  }
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
        status=pending
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
  discover_live_workers "$live_rows" || return 1
  jq -Rn '
    [inputs
     | split("\t")
     | select(length == 7)
     | {task_id:.[0], linear_card_id:.[1], backend:.[2], endpoint:.[3],
        herdr_session:.[4], herdr_pane_id:.[5], endpoint_status:.[6]}]
  ' < "$rows" > "$TMP/local-records.json"
  jq -Rn '
    [inputs
     | split("\t")
     | select(length == 7)
     | {task_id:.[0], linear_card_id:.[1], backend:.[2], endpoint:.[3],
        herdr_session:.[4], herdr_pane_id:.[5], endpoint_status:.[6]}]
  ' < "$live_rows" > "$TMP/local-live.json"
  jq -n --slurpfile records "$TMP/local-records.json" --slurpfile live "$TMP/local-live.json" '
    (($records[0] | map(. + {recorded:true})) + [ $live[0][] as $worker
        | select(any($records[0][];
            .task_id == $worker.task_id and .backend == "herdr" and .endpoint == $worker.endpoint) | not)
        | $worker + {recorded:false} ])
    | unique_by([.task_id, .backend, .endpoint])
  ' > "$TMP/local-union.json"
  jq -r '.[] | select(.backend == "herdr" and .endpoint_status == "pending") | .endpoint' \
    "$TMP/local-union.json" | sort -u > "$TMP/local-endpoints"
  : > "$TMP/local-status.rows"
  while IFS= read -r endpoint; do
    [ -n "$endpoint" ] || continue
    status=$(fm_backend_agent_state herdr "$endpoint") || status=unreadable
    case "$status" in alive|dead|missing|ambiguous|unreadable|unverified) : ;; *) status=unreadable ;; esac
    safe_field "$endpoint" && safe_field "$status" || return 1
    printf '%s\t%s\n' "$endpoint" "$status" >> "$TMP/local-status.rows"
  done < "$TMP/local-endpoints"
  jq -Rn '[inputs | split("\t") | select(length == 2) | {endpoint:.[0], status:.[1]}]' \
    < "$TMP/local-status.rows" > "$TMP/local-status.json"
  jq --slurpfile statuses "$TMP/local-status.json" '
    map(if .endpoint_status == "pending" then
      .endpoint as $endpoint
      | .endpoint_status = ([ $statuses[0][] | select(.endpoint == $endpoint) | .status ][0] // "unreadable")
    else . end)
  ' "$TMP/local-union.json" > "$TMP/local-resolved.json"
  if jq -e 'any(.[]; .recorded == false
      and (.endpoint_status != "alive" and .endpoint_status != "dead" and .endpoint_status != "missing"))' \
      "$TMP/local-resolved.json" >/dev/null; then
    echo 'fm-herdr-linear-reconcile: could not verify a discovered Herdr worker' >&2
    return 1
  fi
  jq --arg home "$FM_HOME" '
    [ .[] | select(.recorded or .endpoint_status == "alive") | del(.recorded) ]
    | sort_by(.task_id, .backend, .endpoint)
    | {schema:"fm-herdr-linear-inventory.v1", home:$home,
       ownership_status:"verified", children:.}
  ' "$TMP/local-resolved.json"
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
  and .ownership_status == "verified"
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
      | index($status) != null)
    and (if .backend == "herdr" then
      (.endpoint | length) > 0
      and (.herdr_session | length) > 0
      and (.herdr_pane_id | length) > 0
      and .endpoint == (.herdr_session + ":" + .herdr_pane_id)
      and .endpoint_status != "not-applicable"
    else
      .endpoint_status == "not-applicable"
    end))
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
  : > "$TMP/linear-cursors"
  cursor=
  while :; do
    payload=$(jq -cn \
      --arg team "$FM_LINEAR_OPERATING_STUDIO_TEAM_ID" \
      --arg project "$FM_LINEAR_OPERATING_STUDIO_PROJECT_ID" \
      --arg after "$cursor" \
      '{query:"query OperatingStudioCards($team: ID!, $project: ID!, $after: String) { issues(first: 250, after: $after, filter: { team: { id: { eq: $team } }, project: { id: { eq: $project } }, state: { name: { in: [\"In Progress\", \"In Review\"] } } }) { nodes { id identifier state { name } } pageInfo { hasNextPage endCursor } } }",variables:{team:$team,project:$project,after:(if $after == "" then null else $after end)}}')
    if ! curl --fail --silent --show-error --max-time 15 \
      -H 'Content-Type: application/json' -H @/dev/fd/3 \
      3< <(printf 'Authorization: %s\n' "$LINEAR_API_KEY") \
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
    if grep -Fqx -- "$cursor" "$TMP/linear-cursors"; then
      echo 'fm-herdr-linear-reconcile: Linear API pagination cursor did not advance' >&2
      exit 1
    fi
    printf '%s\n' "$cursor" >> "$TMP/linear-cursors"
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
  ([ $local[0].children[] | . + {home:$local[0].home} ]
   + [ $zeus[0].children[] | . + {home:$zeus[0].home} ]) as $records
  | ([ $records[] | select(.backend == "herdr" and .endpoint_status == "alive") ]
      | sort_by(.home, .backend, .endpoint, .task_id)
      | group_by([.home, .backend, .endpoint])
      | map(.[0])) as $workers
  | $cards[0] as $cards
  | [ $records[] | select(.endpoint != "")
      | {key:[.home, .backend, .endpoint]} ]
    | group_by(.key)
    | map(select(length > 1) | .[0].key) as $duplicate_endpoint_keys
  | [ $cards[] | .id ] | group_by(.) | map(select(length > 1) | .[0]) as $duplicate_cards
  | [ $cards[] as $card
      | ([ $records[] | select(.linear_card_id == $card.id) ]) as $bound
      | if ($duplicate_cards | index($card.id)) then
          {kind:"duplicate-card", card_id:$card.id, identifier:$card.identifier,
           detail:"Linear returned the same card identity more than once"}
        elif ($bound | length) == 0 then
          {kind:"card-without-task-binding", card_id:$card.id, identifier:$card.identifier,
           detail:"no recorded Firstmate task binding"}
        elif ($bound | length) > 1 then
          {kind:"duplicate-ownership", card_id:$card.id, identifier:$card.identifier,
           task_ids:($bound | map(.task_id)),
           workers:($bound | map({task_id, home, backend, endpoint})),
           detail:"multiple tasks claim this card"}
        else $bound[0] as $worker
          | if any($duplicate_endpoint_keys[]; . == [$worker.home, $worker.backend, $worker.endpoint]) then
              {kind:"duplicate-endpoint", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, home:$worker.home, backend:$worker.backend,
               endpoint:$worker.endpoint,
               detail:"the recorded endpoint belongs to multiple tasks"}
            elif $worker.backend != "herdr" then
              {kind:"needs-deep-check", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, home:$worker.home, backend:$worker.backend,
               endpoint:$worker.endpoint, detail:"the recorded task is not Herdr-backed"}
            elif $worker.endpoint_status == "missing" then
              {kind:"missing-endpoint", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, home:$worker.home, backend:$worker.backend,
               endpoint:$worker.endpoint,
               detail:"Herdr has no agent for the recorded endpoint"}
            elif $worker.endpoint_status != "alive" then
              {kind:"needs-deep-check", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, home:$worker.home, backend:$worker.backend,
               endpoint:$worker.endpoint,
               detail:("Herdr cannot prove a live worker (endpoint status " + $worker.endpoint_status + ")")}
            else
              {kind:"matched-live-endpoint", card_id:$card.id, identifier:$card.identifier,
               task_id:$worker.task_id, home:$worker.home, backend:$worker.backend,
               endpoint:$worker.endpoint,
               detail:"recorded Herdr endpoint has a live agent process"}
            end
        end
    ] as $card_findings
  | [ $workers[] as $worker
      | select(([ $records[] as $record
          | select($record.home == $worker.home and $record.backend == $worker.backend
              and $record.endpoint == $worker.endpoint
              and any($cards[]; .id == $record.linear_card_id)) ] | length) == 0)
      | {kind:"worker-without-applicable-card", task_id:$worker.task_id,
         home:$worker.home, backend:$worker.backend, endpoint:$worker.endpoint,
         detail:"worker does not have an applicable In Progress or In Review card"}
    ] as $worker_findings
  | [ $records[] as $worker
      | select($worker.backend == "herdr")
      | select($worker.endpoint_status != "alive" and $worker.endpoint_status != "dead"
          and $worker.endpoint_status != "missing")
      | select(($worker.linear_card_id | length) == 0
          or (any($cards[]; .id == $worker.linear_card_id) | not))
      | {kind:"needs-deep-check", task_id:$worker.task_id,
         home:$worker.home, backend:$worker.backend, endpoint:$worker.endpoint,
         detail:("Herdr cannot establish liveness for an unbound worker record (endpoint status "
           + $worker.endpoint_status + ")")}
    ] as $unresolved_findings
  | {schema:"fm-herdr-linear-reconcile.v1", local_inventory:$local[0], zeus_inventory:$zeus[0],
     cards:$cards,
     findings:(($card_findings + $worker_findings + $unresolved_findings)
       | sort_by(.kind, (.home // ""), (.card_id // ""), (.task_id // ""))),
     summary:{cards:($cards | length), workers:($workers | length),
              matched:([$card_findings[] | select(.kind == "matched-live-endpoint")] | length),
              needs_deep_check:([($card_findings + $worker_findings + $unresolved_findings)[]
                | select(.kind != "matched-live-endpoint")] | length)}}
')

printf '%s\n' "$REPORT"
