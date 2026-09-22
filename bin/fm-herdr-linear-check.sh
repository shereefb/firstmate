#!/usr/bin/env bash
# fm-herdr-linear-check.sh - recurring Operating Studio reconciliation check.
#
# Usage:
#   fm-herdr-linear-check.sh [check]
#   fm-herdr-linear-check.sh arm
#   fm-herdr-linear-check.sh inspect
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="$FM_HOME/state"
CHECK_ID=herdr-linear-reconcile
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
RECORD="$STATE/.herdr-linear-reconcile-check"
ENV_FILE="${FM_LINEAR_CONFIG_FILE:-$FM_HOME/.env}"
INTERVAL=900
OUTPUT_FILE=
ERROR_FILE=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

cleanup() {
  [ -z "$OUTPUT_FILE" ] || rm -f -- "$OUTPUT_FILE"
  [ -z "$ERROR_FILE" ] || rm -f -- "$ERROR_FILE"
  OUTPUT_FILE=
  ERROR_FILE=
}

trap cleanup EXIT
trap 'exit 124' HUP INT TERM

usage() {
  cat <<'EOF'
Usage:
  fm-herdr-linear-check.sh [check]   reconcile when the 15-minute interval is due
  fm-herdr-linear-check.sh arm       arm the trusted buildboard custom check
  fm-herdr-linear-check.sh inspect   print one fresh reconciliation result
EOF
}

owner_valid() {
  local owner
  fm_root_is_secondmate_home "$FM_HOME" || return 1
  owner=$(cat "$FM_HOME/.fm-secondmate-home" 2>/dev/null) || return 1
  [ "$owner" = buildboard ]
}

primary_data_dir() {
  fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 1
  printf '%s/data\n' "$FM_SECONDMATE_PARENT_HOME"
}

now_epoch() {
  case "${FM_HERDR_LINEAR_CHECK_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_HERDR_LINEAR_CHECK_NOW" ;;
  esac
}

record_epoch() {
  local epoch
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || { printf '0\n'; return 0; }
  IFS= read -r epoch < "$RECORD" || epoch=0
  case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
  printf '%s\n' "$epoch"
}

record_write() {
  local epoch=$1 device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-herdr-linear-check.XXXXXX") || return 1
  if ! printf '%s\n' "$epoch" > "$tmp" || ! chmod 0600 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 600 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$RECORD" "$device" \
    || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

one_line() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1000
}

finish_check() {
  local epoch=$1 line=$2
  if ! record_write "$epoch" 2>/dev/null; then
    if [ -n "$line" ]; then
      line="$line; cadence state could not be saved, inspect buildboard state permissions and rerun the check"
    else
      line='Operating Studio reconciliation check failed: cadence state could not be saved; inspect buildboard state permissions and rerun the check'
    fi
  fi
  [ -z "$line" ] || printf '%s\n' "$(one_line "$line")"
}

load_linear_config() {
  LINEAR_READONLY_API_KEY=$(fmx_env_get FM_LINEAR_READONLY_API_KEY "$ENV_FILE")
  LINEAR_TEAM_ID=$(fmx_env_get FM_LINEAR_OPERATING_STUDIO_TEAM_ID "$ENV_FILE")
  LINEAR_PROJECT_ID=$(fmx_env_get FM_LINEAR_OPERATING_STUDIO_PROJECT_ID "$ENV_FILE")
  if [ -n "${FM_LINEAR_CONFIG_FILE:-}" ]; then
    [ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] && [ -r "$ENV_FILE" ] || return 1
    [ -n "$LINEAR_READONLY_API_KEY" ] \
      || LINEAR_READONLY_API_KEY=$(fmx_env_get LINEAR_API_KEY "$ENV_FILE")
    [ -n "$LINEAR_TEAM_ID" ] \
      || LINEAR_TEAM_ID=${FM_LINEAR_OPERATING_STUDIO_TEAM_ID:-}
    [ -n "$LINEAR_PROJECT_ID" ] \
      || LINEAR_PROJECT_ID=${FM_LINEAR_OPERATING_STUDIO_PROJECT_ID:-}
  fi
  [ -n "$LINEAR_READONLY_API_KEY" ] && [ -n "$LINEAR_TEAM_ID" ] && [ -n "$LINEAR_PROJECT_ID" ]
}

internal_budget() {
  local timeout=${FM_CHECK_TIMEOUT:-30}
  case "$timeout" in ''|*[!0-9]*|0) timeout=30 ;; esac
  [ "$timeout" -ge 4 ] || return 1
  printf '%s\n' "$((timeout - 3))"
}

action_check() {
  local now previous primary_data detail count rc budget line=
  now=$(now_epoch)
  previous=$(record_epoch)
  if [ "$previous" -gt 0 ] && [ "$now" -ge "$previous" ] \
    && [ $((now - previous)) -lt "$INTERVAL" ]; then
    return 0
  fi

  if ! owner_valid; then
    finish_check "$now" 'Operating Studio reconciliation check failed: this trusted check must run from the persistent buildboard home; remove the stale custom check from this home and arm it from buildboard'
    return 0
  fi

  if ! primary_data=$(primary_data_dir); then
    finish_check "$now" 'Operating Studio reconciliation check failed: buildboard needs a valid local parent binding to the primary Zeus registry; repair the binding and rerun the check'
    return 0
  fi
  if ! load_linear_config; then
    finish_check "$now" 'Operating Studio reconciliation check failed: buildboard .env needs FM_LINEAR_READONLY_API_KEY, FM_LINEAR_OPERATING_STUDIO_TEAM_ID, and FM_LINEAR_OPERATING_STUDIO_PROJECT_ID; add them and rerun the check'
    return 0
  fi
  if ! budget=$(internal_budget); then
    finish_check "$now" 'Operating Studio reconciliation check failed: FM_CHECK_TIMEOUT must be at least 4 seconds; raise it and rerun the check'
    return 0
  fi

  OUTPUT_FILE=$(mktemp "$STATE/.fm-herdr-linear-output.XXXXXX") || {
    finish_check "$now" 'Operating Studio reconciliation check failed: could not create private result storage; inspect buildboard state permissions and rerun the check'
    return 0
  }
  ERROR_FILE=$(mktemp "$STATE/.fm-herdr-linear-error.XXXXXX") || {
    cleanup
    finish_check "$now" 'Operating Studio reconciliation check failed: could not create private error storage; inspect buildboard state permissions and rerun the check'
    return 0
  }
  export LINEAR_API_KEY="$LINEAR_READONLY_API_KEY"
  export FM_LINEAR_OPERATING_STUDIO_TEAM_ID="$LINEAR_TEAM_ID"
  export FM_LINEAR_OPERATING_STUDIO_PROJECT_ID="$LINEAR_PROJECT_ID"
  export FM_STATE_OVERRIDE="$STATE"
  export FM_DATA_OVERRIDE="$primary_data"
  fm_run_timed "$budget" "$SCRIPT_DIR/fm-herdr-linear-reconcile.sh" --linear-api \
    > "$OUTPUT_FILE" 2> "$ERROR_FILE"
  rc=$?
  unset LINEAR_API_KEY FM_LINEAR_OPERATING_STUDIO_TEAM_ID FM_LINEAR_OPERATING_STUDIO_PROJECT_ID FM_STATE_OVERRIDE FM_DATA_OVERRIDE
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ]; then
      detail="reconciliation exceeded its ${budget}-second internal budget"
    else
      detail=$(sed -n '/./{p;q;}' "$ERROR_FILE")
      [ -n "$detail" ] || detail="reconciliation exited $rc without a diagnostic"
    fi
    line="Operating Studio reconciliation check failed: $(one_line "$detail"); run bin/fm-herdr-linear-check.sh inspect from buildboard"
  elif ! count=$(jq -er '
      select(.schema == "fm-herdr-linear-reconcile.v1")
      | .summary.needs_deep_check
      | select(type == "number" and . >= 0 and floor == .)
    ' "$OUTPUT_FILE" 2>/dev/null); then
    line='Operating Studio reconciliation check failed: reconciliation returned an invalid result; run bin/fm-herdr-linear-check.sh inspect from buildboard'
  elif [ "$count" -gt 0 ]; then
    line="Operating Studio reconciliation needs deep inspection: $count discrepancy(s); run bin/fm-herdr-linear-check.sh inspect from buildboard"
  fi
  cleanup
  finish_check "$now" "$line"
  return 0
}

action_inspect() {
  local primary_data
  owner_valid || {
    printf '%s\n' 'fm-herdr-linear-check: only the persistent buildboard home may inspect this reconciliation' >&2
    return 1
  }
  primary_data=$(primary_data_dir) || {
    printf '%s\n' 'fm-herdr-linear-check: buildboard needs a valid local parent binding to the primary Zeus registry' >&2
    return 1
  }
  load_linear_config || {
    printf 'fm-herdr-linear-check: buildboard Linear configuration is incomplete in %s\n' "$ENV_FILE" >&2
    return 1
  }
  LINEAR_API_KEY="$LINEAR_READONLY_API_KEY" \
    FM_LINEAR_OPERATING_STUDIO_TEAM_ID="$LINEAR_TEAM_ID" \
    FM_LINEAR_OPERATING_STUDIO_PROJECT_ID="$LINEAR_PROJECT_ID" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$primary_data" \
    exec "$SCRIPT_DIR/fm-herdr-linear-reconcile.sh" --linear-api
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$home/state")" \
    "exec $(printf '%q' "$home/bin/fm-herdr-linear-check.sh") check"
}

action_arm() {
  local home want device tmp primary_data
  owner_valid || {
    printf '%s\n' 'fm-herdr-linear-check: only the persistent buildboard home may arm this check' >&2
    return 1
  }
  primary_data=$(primary_data_dir) || {
    printf '%s\n' 'fm-herdr-linear-check: buildboard needs a valid local parent binding to the primary Zeus registry' >&2
    return 1
  }
  if ! secondmate_registry_validate_bindings \
    "$primary_data/secondmates.md" secondmate_registry_path_key zeus; then
    printf 'fm-herdr-linear-check: primary Zeus route is unavailable: %s\n' "$SECONDMATE_REGISTRY_ERROR" >&2
    return 1
  fi
  load_linear_config || {
    printf 'fm-herdr-linear-check: buildboard Linear configuration is incomplete in %s\n' "$ENV_FILE" >&2
    return 1
  }
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  want=$(shim_content "$home")
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ] \
    && fm_custom_check_registered "$STATE" "$CHECK_ID"; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
    return 0
  fi
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-herdr-linear-check.XXXXXX") || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device" \
    || ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM" \
    || ! FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$tmp"
    FM_HOME="$home" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1 || true
    printf 'fm-herdr-linear-check: could not arm state/%s.check.sh\n' "$CHECK_ID" >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  inspect) action_inspect ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
